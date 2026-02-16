-- Gate/GateService.lua
-- Gate服务: websocket接入 + protobuf编解码 + 路由到agent
-- 全cast，零call
--
-- 认证流程:
--   client -> C2S_Login(account, authkey) -> gate验证authkey -> cast db login
--   db -> authResult(fd, sessionId, uid, code) -> gate绑定session -> cast agent online
--
-- 设计要点:
--   - sessionId 单调递增，解决fd复用后 authResult 错误绑定
--   - auth() 返回被顶替的旧entry，gate直接踢旧fd
--   - 未认证session不刷新活跃时间，使暴力破解连接可被心跳超时清理

local skynet    = require "skynet"
local socket    = require "skynet.socket"
local websocket = require "http.websocket"
local crypt     = require "skynet.crypt"
local md5_core  = require "md5.core"
local Cast      = require "Cast"
local Dispatch  = require "Dispatch"
local Session   = require "Session"
local Proto     = require "Proto"
local MsgId     = require "Proto.MsgId"
local ErrCode   = require "Proto.ErrorCode"

----------------------------------------------------------------
-- AuthKey验证: MD5(分钟时间戳+账号+服务器ID)
----------------------------------------------------------------

local function verifyAuthKey(authkey, account, serverId)
    local now = os.time()
    local currentMinute = math.floor(now / 60)
    for offset = -1, 1 do
        local minute = currentMinute + offset
        local plain = string.format("%d%s%d", minute, account, serverId)
        local expected = crypt.base64encode(md5_core.sum(plain))
        if authkey == expected then
            return true
        end
    end
    return false
end

local gateIndex    = tonumber((...)) or 0
local sessions     = Session.new()
local agents       = {}   ---@type integer[]
local dbAddr       = 0    ---@type integer
local coordinator  = 0    ---@type integer
local wsPort       = 0
local maxClient    = 1024
local heartbeatSec = 60
local heartbeatCheck = 10
local listenFd     = nil
local stopping     = false

----------------------------------------------------------------
-- uid -> agent 一致性哈希(FNV-1a)
----------------------------------------------------------------
local FNV_OFFSET = 0x811C9DC5
local FNV_PRIME  = 0x01000193

---@param uid integer
---@return integer|nil agentAddr
local function pickAgent(uid)
    if #agents == 0 then return nil end
    local h = FNV_OFFSET
    for shift = 0, 24, 8 do
        local byte = math.floor(uid / (2 ^ shift)) % 256
        h = ((h ~ byte) * FNV_PRIME) % 0x100000000
    end
    return agents[(h % #agents) + 1]
end

----------------------------------------------------------------
-- 安全关闭fd(幂等)
----------------------------------------------------------------
---@param fd integer
local function safeClose(fd)
    pcall(socket.close, fd)
end

----------------------------------------------------------------
-- 向客户端推送
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
----------------------------------------------------------------
---@param fd integer
---@param data string
local function onClientMsg(fd, data)
    local msgId, body = Proto.decode(data)
    if not msgId then return end
    if not body then return end  -- protobuf解码失败，丢弃

    local entry = sessions:getByFd(fd)
    if not entry then return end

    -- 未认证: 仅允许登录
    if not entry.uid then
        -- 已有待处理的认证请求时忽略，防多个authResult触发重复online
        if entry.pendingAuth then return end

        if msgId == MsgId.C2S_Login then
            local Cfg = require "Config.Config"
            local account = body.account or ""
            local authkey = body.authkey or ""

            if not verifyAuthKey(authkey, account, Cfg.serverId) then
                skynet.error(string.format("[Gate%d] authkey failed: fd=%d account=%s",
                    gateIndex, fd, account))
                entry.authFailCount = entry.authFailCount + 1
                if entry.authFailCount >= ErrCode.AUTH_FAIL_LIMIT then
                    safeClose(fd)
                end
                return
            end

            entry.pendingAuth = true
            Cast.send(dbAddr, "login", {
                account   = account,
                fd        = fd,
                sessionId = entry.sessionId,
                gate      = skynet.self(),
            })
        end
        return
    end

    -- 已认证: 转发给agent(仅已认证session刷新活跃时间)
    if entry.agent then
        sessions:touch(fd)
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
-- 连接断开(幂等: sessions:remove已移除则返回nil)
----------------------------------------------------------------
---@param fd integer
local function onWsClose(fd)
    local entry = sessions:remove(fd)
    if not entry then return end
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
----------------------------------------------------------------
---@param fd integer
---@param addr string
local function onWsConnect(fd, addr)
    local handle = {
        message = function(id, msg, msg_type)
            if msg_type == "binary" or msg_type == "text" then
                onClientMsg(id, msg)
            end
        end,
        close = function(id, code, reason)
            onWsClose(id)
        end,
        error = function(id)
            skynet.error(string.format("[Gate%d] ws error fd=%d", gateIndex, id))
            onWsClose(id)
        end,
    }

    local ok, err = websocket.accept(fd, handle, "ws", addr)
    if not ok then
        skynet.error(string.format("[Gate%d] ws accept fail fd=%d: %s", gateIndex, fd, err or ""))
    end
    -- accept返回后统一尝试close，onWsClose内部幂等
    onWsClose(fd)
end

----------------------------------------------------------------
-- 心跳超时扫描
----------------------------------------------------------------
local function startHeartbeatTimer()
    Cast.setInterval(heartbeatCheck,
        function() return stopping end,
        function()
            local timeoutFds = sessions:collectTimeout(heartbeatSec)
            for _, fd in ipairs(timeoutFds) do
                skynet.error(string.format("[Gate%d] heartbeat timeout fd=%d", gateIndex, fd))
                pushClient(fd, MsgId.S2C_Kick, { reason = ErrCode.KICK_HEARTBEAT })
                local entry = sessions:remove(fd)
                safeClose(fd)
                if entry and entry.uid and entry.agent then
                    Cast.send(entry.agent, "offline", {
                        uid  = entry.uid,
                        fd   = fd,
                        gate = skynet.self(),
                    })
                end
            end
        end
    )
end

----------------------------------------------------------------
-- 命令处理
----------------------------------------------------------------
local handler = {}

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
    gateIndex      = cfg.gateIndex or gateIndex

    local protoFile = (cfg.protoPath or "Proto/") .. "Game.pb"
    Proto.load(protoFile)

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
            local ok, err = pcall(onWsConnect, fd, addr)
            if not ok then
                skynet.error(string.format("[Gate%d] conn error fd=%d: %s", gateIndex, fd, tostring(err)))
                onWsClose(fd)
            end
        end)
    end)

    startHeartbeatTimer()
end

--- db认证结果回调
--- sessionId 校验fd未被复用，auth成功时二次校验session存在性防幽灵条目
---@param source integer
---@param result table  { fd, sessionId, uid, code, msgId }
function handler.authResult(source, result)
    local entry = sessions:getByFdAndSession(result.fd, result.sessionId)
    if not entry then return end

    -- 认证响应到达，允许再次发起认证
    entry.pendingAuth = false

    if result.code == ErrCode.AUTH_OK and result.uid then
        local agentAddr = pickAgent(result.uid)
        if not agentAddr then
            skynet.error(string.format("[Gate%d] no agents available, reject auth fd=%d", gateIndex, result.fd))
            pushClient(result.fd, result.msgId, { code = ErrCode.AUTH_NO_AGENT, uid = 0 })
            sessions:remove(result.fd)
            safeClose(result.fd)
            return
        end

        local displaced = sessions:auth(result.fd, result.uid, agentAddr)

        -- auth返回被同uid顶替的旧session，直接踢旧fd
        if displaced then
            skynet.error(string.format("[Gate%d] same-uid collision: kicking old fd=%d for uid=%d",
                gateIndex, displaced.fd, result.uid))
            pushClient(displaced.fd, MsgId.S2C_Kick, { reason = ErrCode.KICK_REPLACED })
            sessions:remove(displaced.fd)
            safeClose(displaced.fd)
            -- 通知agent旧连接离线
            -- NOTE: 此 offline 与下方 online 发往同一 agent，
            --   依赖 skynet 的同源有序保证(cast到同一目标按发送顺序投递)
            if displaced.agent then
                Cast.send(displaced.agent, "offline", {
                    uid  = result.uid,
                    fd   = displaced.fd,
                    gate = skynet.self(),
                })
            end
        end

        -- 二次校验: fd在异步期间可能已断开
        local verify = sessions:getByFd(result.fd)
        if not verify or verify.uid ~= result.uid then
            skynet.error(string.format("[Gate%d] fd=%d gone before auth completed, skip online",
                gateIndex, result.fd))
            return
        end

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
        -- 认证失败: 累计失败次数，超限断连
        entry.authFailCount = (entry.authFailCount or 0) + 1
        pushClient(result.fd, result.msgId, {
            code = result.code,
            uid  = 0,
        })
        if entry.authFailCount >= ErrCode.AUTH_FAIL_LIMIT then
            skynet.error(string.format("[Gate%d] auth fail limit reached fd=%d (%d attempts)",
                gateIndex, result.fd, entry.authFailCount))
            sessions:remove(result.fd)
            safeClose(result.fd)
        end
    end
end

---@param source integer
---@param req table  { fd, msgId, body }
function handler.push(source, req)
    pushClient(req.fd, req.msgId, req.body)
end

--- 踢人: 必须携带 uid，gate 校验 session 归属后再踢
---@param source integer
---@param req table  { fd, uid, reason }
function handler.kick(source, req)
    local entry = sessions:getByFd(req.fd)
    if not entry or entry.uid ~= req.uid then
        skynet.error(string.format("[Gate%d] kick ignored: fd=%d uid mismatch (req=%s, actual=%s)",
            gateIndex, req.fd, req.uid, entry and entry.uid or "nil"))
        return
    end
    pushClient(req.fd, MsgId.S2C_Kick, { reason = req.reason or 0 })
    sessions:remove(req.fd)
    safeClose(req.fd)
    -- 通知 agent 该玩家离线(agent 的 offline handler 有 fd 校验，不会误删新连接)
    if entry.uid and entry.agent then
        Cast.send(entry.agent, "offline", {
            uid  = entry.uid,
            fd   = req.fd,
            gate = skynet.self(),
        })
    end
end

--- 优雅关闭
---@param source integer
function handler.shutdown(source)
    skynet.error(string.format("[Gate%d] shutting down...", gateIndex))

    if listenFd then
        pcall(socket.close, listenFd)
        listenFd = nil
    end

    stopping = true

    -- 收集快照后逐个踢线(遍历中 remove 不影响快照)
    local fdsToClose = {}
    for fd, entry in pairs(sessions.byFd) do
        fdsToClose[#fdsToClose + 1] = {
            fd = fd, uid = entry.uid, agent = entry.agent
        }
    end

    for _, s in ipairs(fdsToClose) do
        if sessions:getByFd(s.fd) then
            pushClient(s.fd, MsgId.S2C_Kick, { reason = ErrCode.KICK_SERVER_SHUTDOWN })
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

    sessions = Session.new()
    skynet.error(string.format("[Gate%d] shutdown complete", gateIndex))
    -- 短暂延迟给 agent 时间处理 offline 消息(尽力而为, Shutdown phase2 超时兜底)
    skynet.timeout(10, function()
        Cast.send(coordinator, "shutdownAck")
    end)
end

----------------------------------------------------------------
Dispatch.start(handler)