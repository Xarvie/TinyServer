-- Gate/GateService.lua
-- Gate服务: websocket接入 + protobuf编解码 + 路由到agent
-- 全cast，零call
--
-- Fix #5: authResult 携带 sessionId，校验fd未被复用
-- Fix #6: closedFds 改为与 session 生命周期绑定，不再用定时器清理
-- Fix #7: gateIndex 转为 integer
-- Fix #10: uid 从 string 改为 int32
-- Fix #14: 移除 closedFds 表，改用 session 存在性做幂等判断，消除内存泄漏
-- Fix #15: pickAgent 改用 FNV-1a 哈希，改善分布均匀性
-- Fix #16: 简化 onWsConnect 双层 close 判断，onWsClose 内部天然幂等
-- BugFix #B1:  onWsClose 防止双重触发(websocket close回调 + accept返回后)
-- BugFix #B5:  handler.init 中同步 gateIndex 到局部变量
-- BugFix #B12: authResult 认证成功时校验 session 仍然存在，防止幽灵条目
-- BugFix #B13: pickAgent 防御 agents 为空
-- BugFix #B15: shutdown 中先广播 kick 再设 stopping=true
-- BugFix #B16: kick 请求携带 uid，gate 校验 session 归属后再踢
-- BugFix #B18: onClientMsg 检查 body 为 nil，丢弃畸形包
-- BugFix #B19: auth同gate同uid碰撞时，gate直接踢旧fd，不依赖agent的kick
-- BugFix #B22: shutdown 遍历时校验 session 仍存在，避免向已关闭fd写入

local skynet    = require "skynet"
local socket    = require "skynet.socket"
local websocket = require "http.websocket"
local Cast      = require "Cast"
local Dispatch  = require "Dispatch"
local Session   = require "Session"
local Proto     = require "Proto"
local MsgId     = require "Proto.MsgId"

local gateIndex    = tonumber((...)) or 0  -- Fix #7: 确保integer
local sessions     = Session.new()
local agents       = {}   ---@type integer[]
local dbAddr       = 0    ---@type integer
local coordinator  = 0    ---@type integer  关闭协调者
local wsPort       = 0
local maxClient    = 1024
local heartbeatSec = 60
local heartbeatCheck = 10
local listenFd     = nil
local stopping     = false

----------------------------------------------------------------
-- uid -> agent 一致性哈希(FNV-1a)
-- Fix #15: 改用 FNV-1a 哈希，对 int32 uid 分布更均匀
-- BugFix #B13: agents为空时返回nil，调用方需检查
----------------------------------------------------------------
local FNV_OFFSET = 0x811C9DC5
local FNV_PRIME  = 0x01000193

---@param uid integer
---@return integer|nil agentAddr
local function pickAgent(uid)
    if #agents == 0 then return nil end  -- BugFix #B13
    -- FNV-1a over uid's 4 bytes (int32)
    local h = FNV_OFFSET
    for shift = 0, 24, 8 do
        local byte = math.floor(uid / (2 ^ shift)) % 256
        h = ((h ~ byte) * FNV_PRIME) % 0x100000000
    end
    return agents[(h % #agents) + 1]
end

----------------------------------------------------------------
-- 安全关闭fd(幂等: 通过session存在性防重复)
-- Fix #14: 移除 closedFds 表，消除内存泄漏
--          session:remove() 保证同一fd只处理一次close流程
--          safeClose 仅做 pcall 保护的 socket.close
----------------------------------------------------------------
---@param fd integer
local function safeClose(fd)
    pcall(socket.close, fd)
end

----------------------------------------------------------------
-- 向客户端推送(cast链末端)
-- Fix #14: 统一推送函数，stopping时仍尝试发送(pcall保护)
--          原pushClientForce逻辑合并，不再区分两个函数
----------------------------------------------------------------
---@param fd integer
---@param msgId integer
---@param body table
local function pushClient(fd, msgId, body)
    local data = Proto.encode(msgId, body)
    if data then
        local ok, err = pcall(websocket.write, fd, data, "binary")
        if not ok then
            skynet.error(string.format("[Gate%d] push fail fd=%d: %s", gateIndex, fd, tostring(err)))
        end
    end
end

----------------------------------------------------------------
-- 处理客户端上行消息
-- Fix #5: login/register 请求携带 sessionId，供authResult校验
-- BugFix #B18: 检查 body 是否为 nil
----------------------------------------------------------------
---@param fd integer
---@param data string
local function onClientMsg(fd, data)
    local msgId, body = Proto.decode(data)
    if not msgId then return end
    if not body then return end  -- BugFix #B18: protobuf解码失败，丢弃畸形包

    local entry = sessions:getByFd(fd)
    if not entry then return end

    -- 更新活跃时间
    sessions:touch(fd)

    -- 未认证: 仅允许登录/注册
    if not entry.uid then
        if msgId == MsgId.C2S_Login then
            Cast.send(dbAddr, "login", {
                account   = body.account,
                password  = body.password,
                fd        = fd,
                sessionId = entry.sessionId,  -- Fix #5
                gate      = skynet.self(),
            })
        elseif msgId == MsgId.C2S_Register then
            Cast.send(dbAddr, "register", {
                account   = body.account,
                password  = body.password,
                fd        = fd,
                sessionId = entry.sessionId,  -- Fix #5
                gate      = skynet.self(),
            })
        end
        return
    end

    -- 已认证: 转发给agent
    if entry.agent then
        Cast.send(entry.agent, "clientMsg", {
            uid   = entry.uid,
            msgId = msgId,
            body  = body,
            fd    = fd,
            gate  = skynet.self(),
        })
    end
end

----------------------------------------------------------------
-- 连接断开(正常或异常统一入口)
-- BugFix #B1: sessions:remove() 幂等(已移除返回nil)，天然防双重触发
----------------------------------------------------------------
---@param fd integer
local function onWsClose(fd)
    local entry = sessions:remove(fd)
    if not entry then return end  -- 已被移除过(双重触发或已kick)
    safeClose(fd)
    if entry.uid and entry.agent then
        Cast.send(entry.agent, "offline", {
            uid  = entry.uid,
            fd   = fd,
            gate = skynet.self(),
        })
    end
end

----------------------------------------------------------------
-- WebSocket连接协程
-- Fix #16: 简化close逻辑，onWsClose内部幂等，无需closedInCallback追踪
----------------------------------------------------------------
---@param fd integer
---@param addr string
local function onWsConnect(fd, addr)
    -- 构造符合官方API的handle表
    local handle = {
        connect = function(id)
            -- 连接建立时回调
        end,
        handshake = function(id, header, url)
            -- WebSocket握手完成时回调
        end,
        message = function(id, msg, msg_type)
            -- 收到消息时回调
            if msg_type == "binary" then
                onClientMsg(id, msg)
            elseif msg_type == "text" then
                -- 如果需要处理文本消息
                onClientMsg(id, msg)
            end
        end,
        close = function(id, code, reason)
            -- 连接关闭时回调
            onWsClose(id)
        end,
        ping = function(id)
            -- 收到ping帧时回调
        end,
        pong = function(id)
            -- 收到pong帧时回调
        end,
        error = function(id)
            -- 发生错误时回调
            skynet.error(string.format("[Gate%d] ws error fd=%d", gateIndex, id))
            onWsClose(id)
        end
    }
    
    -- 正确的API调用: websocket.accept(id, handle, protocol, addr)
    local ok, err = websocket.accept(fd, handle, "ws", addr)
    if not ok then
        skynet.error(string.format("[Gate%d] ws accept fail fd=%d: %s", gateIndex, fd, err or ""))
    end
    -- accept返回后(无论正常/异常)，统一尝试close
    -- onWsClose内部幂等: 如果回调中已处理过，remove返回nil直接跳过
    onWsClose(fd)
end

----------------------------------------------------------------
-- 心跳超时扫描定时器
----------------------------------------------------------------
local function startHeartbeatTimer()
    if stopping then return end
    skynet.timeout(heartbeatCheck * 100, function()
        if stopping then return end
        local timeoutFds = sessions:collectTimeout(heartbeatSec)
        for _, fd in ipairs(timeoutFds) do
            skynet.error(string.format("[Gate%d] heartbeat timeout fd=%d", gateIndex, fd))
            -- BugFix BUG-6: 调整顺序为 push → remove → close
            -- 先推送踢线消息(此时session仍在，fd有效)
            pushClient(fd, MsgId.S2C_Kick, { reason = -2 })
            -- 再移除session(获取entry用于通知agent)
            local entry = sessions:remove(fd)
            -- 最后关闭连接
            safeClose(fd)
            if entry and entry.uid and entry.agent then
                Cast.send(entry.agent, "offline", {
                    uid  = entry.uid,
                    fd   = fd,
                    gate = skynet.self(),
                })
            end
        end
        startHeartbeatTimer()  -- 循环
    end)
end

----------------------------------------------------------------
-- 命令处理(纯cast接收)
----------------------------------------------------------------
local handler = {}

--- 初始化(由main cast)
---@param source integer
---@param cfg table
function handler.init(source, cfg)
    agents       = cfg.agents
    dbAddr       = cfg.dbAddr
    wsPort       = cfg.wsPort
    maxClient    = cfg.maxClient
    coordinator  = cfg.coordinator or source
    heartbeatSec   = cfg.heartbeatSec or 60
    heartbeatCheck = cfg.heartbeatCheck or 10
    gateIndex      = cfg.gateIndex or gateIndex  -- BugFix #B5: 同步cfg中的gateIndex

    Proto.load("Proto/Game.pb")

    -- 启动websocket监听
    listenFd = socket.listen("0.0.0.0", wsPort)
    skynet.error(string.format("[Gate%d] listening ws://0.0.0.0:%d", gateIndex, wsPort))

    socket.start(listenFd, function(fd, addr)
        if stopping then
            safeClose(fd)
            return
        end
        if sessions:count() >= maxClient then
            safeClose(fd)
            return
        end
        sessions:bind(fd, skynet.self())
        skynet.fork(function()
            -- Fix #16: onWsConnect 内部 accept 返回后自动调用 onWsClose(幂等)
            local ok, err = pcall(onWsConnect, fd, addr)
            if not ok then
                skynet.error(string.format("[Gate%d] conn error fd=%d: %s", gateIndex, fd, tostring(err)))
                onWsClose(fd)
            end
        end)
    end)

    -- 启动心跳超时扫描
    startHeartbeatTimer()
end

--- db认证结果回调(db cast回来)
--- Fix #5: 使用 sessionId 校验fd未被复用
--- BugFix #B12: 认证成功时二次校验session存在性，防止幽灵条目
--- BugFix #B13: pickAgent返回nil时拒绝认证
---@param source integer
---@param result table  { fd, sessionId, uid, code, msgId }
function handler.authResult(source, result)
    -- Fix #5: 用 sessionId 精确匹配，防止fd被复用后错误绑定
    local entry
    if result.sessionId then
        entry = sessions:getByFdAndSession(result.fd, result.sessionId)
    else
        entry = sessions:getByFd(result.fd)  -- 兼容旧协议
    end
    if not entry then return end

    if result.code == 0 and result.uid then
        -- BugFix #B13: agents为空时拒绝认证
        local agentAddr = pickAgent(result.uid)
        if not agentAddr then
            skynet.error(string.format("[Gate%d] no agents available, reject auth fd=%d", gateIndex, result.fd))
            pushClient(result.fd, result.msgId, { code = 99, uid = 0 })
            sessions:remove(result.fd)
            safeClose(result.fd)
            return
        end

        -- 认证成功
        local displaced = sessions:auth(result.fd, result.uid, agentAddr)

        -- BugFix #B19: auth返回被同uid顶替的旧session，gate直接踢旧fd
        -- 不能依赖agent后续cast kick，因为auth已清除旧entry.uid，B16校验会失败
        if displaced then
            skynet.error(string.format("[Gate%d] same-uid collision: kicking old fd=%d for uid=%d",
                gateIndex, displaced.fd, result.uid))
            pushClient(displaced.fd, MsgId.S2C_Kick, { reason = 1 })
            sessions:remove(displaced.fd)
            safeClose(displaced.fd)
            -- 通知agent旧连接离线(agent会在收到新online时再次处理顶号，这里确保旧fd被清理)
            -- NOTE(BUG-3): 此 offline 与下方 online 都发往同一 agent，
            --   依赖 skynet 的同源有序保证(同一服务cast到同一目标按发送顺序投递)。
            --   如果未来引入中间层打破此顺序，需改为在 online 中携带 oldFd 字段。
            if displaced.agent then
                Cast.send(displaced.agent, "offline", {
                    uid  = result.uid,
                    fd   = displaced.fd,
                    gate = skynet.self(),
                })
            end
        end

        -- BugFix #B12: auth内部如果byFd[fd]已为nil(fd在异步期间断开)，
        -- auth不会生效，此时不应通知agent上线，否则产生幽灵条目
        local verify = sessions:getByFd(result.fd)
        if not verify or verify.uid ~= result.uid then
            skynet.error(string.format("[Gate%d] fd=%d gone before auth completed, skip online",
                gateIndex, result.fd))
            return
        end

        -- 通知agent上线
        Cast.send(agentAddr, "online", {
            uid  = result.uid,
            fd   = result.fd,
            gate = skynet.self(),
        })
        pushClient(result.fd, result.msgId, {
            code = result.code,
            uid  = result.uid or 0,
        })
    else
        -- BugFix BUG-7: 认证失败仅推送错误码，不断开连接，允许客户端重试
        -- 只在异常情况(协议违规等)才断开，密码错误/账号不存在属正常业务错误
        pushClient(result.fd, result.msgId, {
            code = result.code,
            uid  = 0,
        })
    end
end

--- agent请求推送消息给客户端(agent cast过来)
---@param source integer
---@param req table  { fd, msgId, body }
function handler.push(source, req)
    pushClient(req.fd, req.msgId, req.body)
end

--- 踢人(agent/db cast过来)
--- BugFix #B16: 携带 uid，gate 校验 session 归属后再踢
---              兼容不带 uid 的旧协议(降级为仅 fd 匹配)
---@param source integer
---@param req table  { fd, reason, uid? }
function handler.kick(source, req)
    -- BugFix #B16: 如果请求携带 uid，验证该 fd 的 session 确实属于该 uid
    if req.uid then
        local entry = sessions:getByFd(req.fd)
        if not entry or entry.uid ~= req.uid then
            -- fd 已被复用给其他玩家，或 session 已不存在，忽略此踢人请求
            skynet.error(string.format("[Gate%d] kick ignored: fd=%d uid mismatch (req=%s, actual=%s)",
                gateIndex, req.fd, req.uid, entry and entry.uid or "nil"))
            return
        end
    end
    pushClient(req.fd, MsgId.S2C_Kick, { reason = req.reason or 0 })
    local entry = sessions:remove(req.fd)
    safeClose(req.fd)
    -- BugFix BUG-13: 通知 agent 该玩家离线
    -- 当前仅 agent 顶号时会 cast kick，agent 已自行处理。
    -- 但未来若有 GM/防作弊等来源，agent 不会收到 offline，entry 会残留。
    -- agent 的 offline handler 有 fd 校验，不会误删新连接的 entry。
    if entry and entry.uid and entry.agent then
        Cast.send(entry.agent, "offline", {
            uid  = entry.uid,
            fd   = req.fd,
            gate = skynet.self(),
        })
    end
end

--- 优雅关闭
--- BugFix #B15: 先收集快照并广播 kick，再设 stopping=true
--- BugFix #B22: 遍历时校验session仍存在，避免向已关闭/复用的fd写入
---@param source integer
function handler.shutdown(source)
    skynet.error(string.format("[Gate%d] shutting down...", gateIndex))

    -- 先关闭监听，不再接受新连接
    if listenFd then
        pcall(socket.close, listenFd)
        listenFd = nil
    end

    -- 设置 stopping 标志：阻止心跳定时器、新连接等后续活动
    stopping = true

    -- BugFix #B22: 直接遍历当前活跃session(而非snapshot)，
    -- remove后不会被其他逻辑再次访问
    local fdsToClose = {}
    for fd, entry in pairs(sessions.byFd) do
        fdsToClose[#fdsToClose + 1] = {
            fd = fd, uid = entry.uid, agent = entry.agent
        }
    end

    for _, s in ipairs(fdsToClose) do
        -- 校验session仍然存在(可能被并发的onWsClose已处理)
        if sessions:getByFd(s.fd) then
            pushClient(s.fd, MsgId.S2C_Kick, { reason = -1 })
            sessions:remove(s.fd)
            safeClose(s.fd)
            if s.uid and s.agent then
                Cast.send(s.agent, "offline", {
                    uid  = s.uid,
                    fd   = s.fd,
                    gate = skynet.self(),
                })
            end
        end
    end

    sessions = Session.new()  -- 清空
    skynet.error(string.format("[Gate%d] shutdown complete", gateIndex))
    -- BugFix BUG-12: 延迟发送 ack，给 agent 时间处理刚发出的 offline 消息
    -- 避免 main 提前进入 phase2 向 agent 发 shutdown 时，offline 尚未处理完
    skynet.timeout(10, function()
        Cast.send(coordinator, "shutdownAck")
    end)
end

----------------------------------------------------------------
Dispatch.new(handler)