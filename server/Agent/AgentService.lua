-- Agent/AgentService.lua
-- Agent服务(容器层): 纯生命周期管理 + 消息调度
-- 全cast，零call
-- 所有业务逻辑在 Logic/ 下的模块中，由 ModuleManager 自动发现和编排
--
-- 职责边界:
--   容器层(本文件): online/offline/loadResult/clientMsg/shutdown + pending队列
--   业务层(模块):   通过 ModuleManager.dispatch/trigger 驱动

local skynet         = require "skynet"
local Cast           = require "Cast"
local Dispatch       = require "Dispatch"
local MsgId          = require "Proto.MsgId"
local ErrCode        = require "Proto.ErrorCode"
local ModuleManager  = require "Agent.ModuleManager"
local Player         = require "Logic.Player.Player"

local agentIndex  = tonumber((...)) or 0
local gates       = {}   ---@type integer[]
local dbAddr      = 0    ---@type integer
local crossAddr   = nil  ---@type integer|nil  init时缓存，不再每次localname查找
local coordinator = 0    ---@type integer

----------------------------------------------------------------
-- 全局loadSeq生成器: 防止顶号后双loadResult竞态
----------------------------------------------------------------
local globalLoadSeq = 0

----------------------------------------------------------------
-- 在线玩家表
----------------------------------------------------------------
---@class PlayerEntry
---@field uid      integer
---@field fd       integer
---@field gate     integer
---@field data     table
---@field loading  boolean
---@field pending  table[]|nil
---@field loadSeq  integer
---@field player   Player|nil
---@field dirty    boolean

local entries     = {}  ---@type table<integer, PlayerEntry>
local playerCount = 0
local stopping    = false
local MAX_PENDING = 100

----------------------------------------------------------------
-- 统一的 entry 清理函数(消除 online/offline/logout/shutdown 中的重复)
--
-- 参数:
--   entry      要清理的 PlayerEntry
--   hookName   生命周期钩子名("onLogout" / "onShutdown")
--   opts.save  是否存盘(loading期间不存盘)
--   opts.removeEntry  是否从 entries 表中删除并减 playerCount
----------------------------------------------------------------
---@param entry PlayerEntry
---@param hookName string
---@param opts { save: boolean, removeEntry: boolean }
local function cleanupEntry(entry, hookName, opts)
    -- 1. 触发模块钩子(逆拓扑序) + 卸载 + 销毁Player
    if entry.player then
        ModuleManager.triggerReverse(hookName, entry.player)
        ModuleManager.unmount(entry.player)
        entry.player:destroy()
        entry.player = nil
    end

    -- 2. 通知Cross移除房间成员
    if crossAddr then
        Cast.send(crossAddr, "leaveRoom", { uid = entry.uid })
    end

    -- 3. 存盘(loading期间data不完整，跳过)
    if opts.save and not entry.loading then
        Cast.send(dbAddr, "save", { uid = entry.uid, data = entry.data })
    end

    -- 4. 从entries表移除
    if opts.removeEntry then
        entries[entry.uid] = nil
        playerCount = playerCount - 1
    end
end

----------------------------------------------------------------
-- 容器级客户端消息处理(心跳、登出等不走业务模块)
----------------------------------------------------------------

---@type table<integer, fun(entry: PlayerEntry, body: table): boolean>
local containerMsgHandlers = {
    [MsgId.C2S_Ping] = function(entry, body)
        Cast.send(entry.gate, "push", {
            fd    = entry.fd,
            msgId = MsgId.S2C_Pong,
            body  = { timestamp = body.timestamp },
        })
        return true
    end,

    [MsgId.C2S_Logout] = function(entry, body)
        cleanupEntry(entry, "onLogout", { save = true, removeEntry = true })
        Cast.send(entry.gate, "kick", { fd = entry.fd, uid = entry.uid, reason = ErrCode.KICK_NORMAL_LOGOUT })
        skynet.error(string.format("[Agent%d] player logout: %d", agentIndex, entry.uid))
        return true
    end,
}

---@param entry PlayerEntry
---@param msgId integer
---@param body  table
---@return boolean handled
local function handleContainerMsg(entry, msgId, body)
    local fn = containerMsgHandlers[msgId]
    if fn then
        return fn(entry, body)
    end
    return false
end

----------------------------------------------------------------
-- 统一消息分发(容器优先 -> 模块路由)
----------------------------------------------------------------
---@param entry PlayerEntry
---@param msgId integer
---@param body  table
local function dispatchClientMsg(entry, msgId, body)
    if handleContainerMsg(entry, msgId, body) then
        return
    end
    if entry.player then
        local handled, modified = ModuleManager.dispatch(entry.player, msgId, body)
        if modified then
            entry.dirty = true
        end
        if not handled then
            skynet.error(string.format("[Agent%d] unhandled msgId=%d uid=%d",
                agentIndex, msgId, entry.uid))
        end
    end
end

----------------------------------------------------------------
-- 服务间命令处理
----------------------------------------------------------------
local handler = {}

---@param source integer
---@param cfg table
function handler.init(source, cfg)
    gates       = cfg.gates
    dbAddr      = cfg.dbAddr
    crossAddr   = cfg.crossAddr   -- init时缓存，不再每次localname
    coordinator = cfg.coordinator or source
    agentIndex  = cfg.agentIndex or agentIndex

    ModuleManager.scan("Logic")
    ModuleManager.init()

    -- 周期定时存盘(每5分钟)
    local SAVE_INTERVAL_SEC = 300
    Cast.setInterval(SAVE_INTERVAL_SEC,
        function() return stopping end,
        function()
            local saved = 0
            for uid, entry in pairs(entries) do
                if not entry.loading and entry.dirty then
                    Cast.send(dbAddr, "save", { uid = uid, data = entry.data })
                    entry.dirty = false
                    saved = saved + 1
                end
            end
            if saved > 0 then
                skynet.error(string.format("[Agent%d] periodic save: %d players", agentIndex, saved))
            end
        end
    )

    skynet.error(string.format("[Agent%d] initialized, %d modules loaded",
        agentIndex, ModuleManager.getModuleCount()))
end

--- 玩家上线(gate cast过来)
---@param source integer
---@param req table  { uid, fd, gate }
function handler.online(source, req)
    local old = entries[req.uid]
    if old then
        -- 顶号: 踢旧连接
        Cast.send(old.gate, "kick", { fd = old.fd, uid = old.uid, reason = ErrCode.KICK_REPLACED })

        if old.loading and old.pending and #old.pending > 0 then
            skynet.error(string.format(
                "[Agent%d] player %d replaced during loading, %d pending msgs discarded",
                agentIndex, req.uid, #old.pending))
        end

        -- 清理旧entry(存盘+钩子)但不减playerCount(同uid复用slot)
        cleanupEntry(old, "onLogout", { save = true, removeEntry = false })
    else
        playerCount = playerCount + 1
    end

    globalLoadSeq = globalLoadSeq + 1
    local seq = globalLoadSeq

    entries[req.uid] = {
        uid     = req.uid,
        fd      = req.fd,
        gate    = req.gate,
        data    = {},
        loading = true,
        pending = {},
        loadSeq = seq,
        player  = nil,
        dirty   = false,
    }

    Cast.send(dbAddr, "load", {
        uid     = req.uid,
        agent   = skynet.self(),
        loadSeq = seq,
    })

    skynet.error(string.format("[Agent%d] player online: %d (loadSeq=%d)",
        agentIndex, req.uid, seq))
end

--- db加载完成回调
---@param source integer
---@param result table  { uid, data, loadSeq }
function handler.loadResult(source, result)
    local entry = entries[result.uid]
    if not entry then return end

    -- 忽略过期loadResult(顶号后旧的加载结果)
    if result.loadSeq and entry.loadSeq ~= result.loadSeq then
        skynet.error(string.format("[Agent%d] stale loadResult uid=%d seq=%d expect=%d, ignored",
            agentIndex, result.uid, result.loadSeq, entry.loadSeq))
        return
    end

    entry.data    = result.data or {}
    entry.loading = false
    entry.dirty   = false  -- 刚从DB加载，与DB一致

    -- 创建业务根对象 + 挂载模块
    local player = Player.new(entry)
    entry.player = player

    ModuleManager.mount(player)
    ModuleManager.trigger("onDbInit", player)
    ModuleManager.trigger("onPlayerLogin", player)

    -- 回放加载期间暂存的消息
    local pending = entry.pending
    entry.pending = nil
    if pending then
        for _, msg in ipairs(pending) do
            -- 回放中若触发顶号(如C2S_Logout), entries[uid]可能指向新entry
            if entries[result.uid] ~= entry then
                skynet.error(string.format(
                    "[Agent%d] pending replay interrupted: uid=%d entry replaced",
                    agentIndex, result.uid))
                break
            end
            dispatchClientMsg(entry, msg.msgId, msg.body)
        end
    end
end

--- 玩家离线(gate cast过来)
---@param source integer
---@param req table  { uid, fd, gate }
function handler.offline(source, req)
    local entry = entries[req.uid]
    if not entry then return end
    if entry.fd ~= req.fd then return end  -- 已被顶号，忽略旧fd

    cleanupEntry(entry, "onLogout", { save = true, removeEntry = true })

    if entry.loading then
        skynet.error(string.format("[Agent%d] player %d offline during loading, skip save",
            agentIndex, req.uid))
    end

    skynet.error(string.format("[Agent%d] player offline: %d", agentIndex, req.uid))
end

--- 客户端消息(gate转发过来)
---@param source integer
---@param req table  { uid, msgId, body, fd, gate }
function handler.clientMsg(source, req)
    local entry = entries[req.uid]
    if not entry then return end

    if entry.loading then
        -- 心跳不暂存，直接响应(保活)
        if req.msgId == MsgId.C2S_Ping then
            Cast.send(entry.gate, "push", {
                fd    = entry.fd,
                msgId = MsgId.S2C_Pong,
                body  = { timestamp = req.body.timestamp },
            })
            return
        end
        if entry.pending then
            if #entry.pending >= MAX_PENDING then
                skynet.error(string.format(
                    "[Agent%d] pending queue full uid=%d, dropping msgId=%d",
                    agentIndex, req.uid, req.msgId))
                return
            end
            entry.pending[#entry.pending + 1] = {
                msgId = req.msgId,
                body  = req.body,
            }
        end
        return
    end

    dispatchClientMsg(entry, req.msgId, req.body)
end

--- 跨服结果回调
---@param source integer
---@param result table  { uid, msgId, body }
function handler.crossResult(source, result)
    local entry = entries[result.uid]
    if not entry or not entry.player then return end
    entry.player:pushClient(result.msgId, result.body)
end

--- 优雅关闭
---@param source integer
function handler.shutdown(source)
    stopping = true
    skynet.error(string.format("[Agent%d] shutting down, saving %d players...",
        agentIndex, playerCount))

    local saveCount = 0
    for uid, entry in pairs(entries) do
        cleanupEntry(entry, "onShutdown", { save = true, removeEntry = false })
        if not entry.loading then
            saveCount = saveCount + 1
        end
    end

    entries = {}
    playerCount = 0

    -- 延迟ack: 给 DbService 处理 save 的缓冲(尽力而为, Shutdown phase3 超时兜底)
    local SAVE_DELAY_PER_PLAYER_CS = 2
    local SAVE_DELAY_BASE_CS       = 50
    local SAVE_DELAY_MAX_CS        = 300
    local delayCentisecond = math.min(
        SAVE_DELAY_BASE_CS + saveCount * SAVE_DELAY_PER_PLAYER_CS,
        SAVE_DELAY_MAX_CS)
    skynet.error(string.format("[Agent%d] sent %d saves, delaying ack by %dms",
        agentIndex, saveCount, delayCentisecond * 10))

    skynet.timeout(delayCentisecond, function()
        skynet.error(string.format("[Agent%d] shutdown complete", agentIndex))
        Cast.send(coordinator, "shutdownAck")
    end)
end

----------------------------------------------------------------
Dispatch.start(handler)