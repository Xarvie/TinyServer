-- Agent/AgentService.lua
-- Agent服务(容器层): 纯生命周期管理 + 消息调度
-- 全cast，零call
-- 所有业务逻辑已剥离至 logic/ 下的模块，由 ModuleManager 自动发现和编排
--
-- 职责边界:
--   容器层(本文件): online/offline/loadResult/clientMsg/shutdown + pending队列
--   业务层(模块):   通过 ModuleManager.dispatch/trigger 驱动
--
-- 保留原有Fix/BugFix:
--   Fix #2:  loading期间离线不存盘
--   Fix #4:  离线时通知Cross移除房间成员
--   Fix #7:  agentIndex转为integer
--   Fix #9:  loadSeq防止顶号后双loadResult竞态
--   Fix #10: uid 从 string 改为 int32
--   Fix #11: Player:destroy() 断开entry引用，isOnline()语义正确
--   Fix #12: 顶号时记录loading状态旧entry的pending丢弃日志
--   Fix #13: 周期定时存盘，防止进程崩溃丢失数据
--   BugFix #B16: kick请求携带uid
--   BugFix #B17: pending回放中检测player已被移除则中断
--   BugFix #B21: handler.init中同步agentIndex

local skynet         = require "skynet"
local Cast           = require "Cast"
local Dispatch       = require "Dispatch"
local MsgId          = require "Proto.MsgId"
local ModuleManager  = require "Agent.ModuleManager"
local Player         = require "Logic.Player.Player"

local agentIndex  = tonumber((...)) or 0  -- Fix #7
local gates       = {}   ---@type integer[]
local dbAddr      = 0    ---@type integer
local coordinator = 0    ---@type integer

----------------------------------------------------------------
-- 全局loadSeq生成器(Fix #9)
----------------------------------------------------------------
local globalLoadSeq = 0

----------------------------------------------------------------
-- 在线玩家表
----------------------------------------------------------------
---@class PlayerEntry
---@field uid      integer
---@field fd       integer
---@field gate     integer
---@field data     table        玩家持久化数据快照
---@field loading  boolean      是否正在加载数据
---@field pending  table[]|nil  加载期间暂存的消息队列
---@field loadSeq  integer      当前加载序号(Fix #9)
---@field player   Player|nil   业务根对象(loading完成后挂载)
---@field dirty    boolean      是否有数据变更待存盘(Fix #13)

local entries     = {}  ---@type table<integer, PlayerEntry>
local playerCount = 0
local stopping    = false  -- Fix #13: 定时存盘在shutdown后停止

----------------------------------------------------------------
-- 通知Cross清理玩家(Fix #4)
----------------------------------------------------------------
---@param uid integer
local function notifyCrossLeave(uid)
    local crossAddr = skynet.localname(".cross")
    if crossAddr then
        Cast.send(crossAddr, "leaveRoom", { uid = uid })
    end
end

----------------------------------------------------------------
-- 容器级客户端消息处理(心跳等不走业务模块)
----------------------------------------------------------------
---@type table<integer, true>
local containerMsgIds = {
    [MsgId.C2S_Ping] = true,
}

---@param entry PlayerEntry
---@param msgId integer
---@param body  table
---@return boolean handled
local function handleContainerMsg(entry, msgId, body)
    if msgId == MsgId.C2S_Ping then
        Cast.send(entry.gate, "push", {
            fd    = entry.fd,
            msgId = MsgId.S2C_Pong,
            body  = { timestamp = body.timestamp },
        })
        return true
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
    -- 1. 容器级消息(心跳等)
    if handleContainerMsg(entry, msgId, body) then
        return
    end
    -- 2. 业务模块路由(O(1))
    if entry.player then
        local handled = ModuleManager.dispatch(entry.player, msgId, body)
        if handled then
            entry.dirty = true  -- Fix #13: 标记有数据变更
        elseif not handled then
            skynet.error(string.format("[Agent%d] unhandled msgId=%d uid=%d",
                agentIndex, msgId, entry.uid))
        end
    end
end

----------------------------------------------------------------
-- 服务间命令处理
----------------------------------------------------------------
local handler = {}

--- 初始化
--- BugFix #B21: 同步agentIndex
--- 新增: ModuleManager扫描+初始化(全局一次)
---@param source integer
---@param cfg table
function handler.init(source, cfg)
    gates       = cfg.gates
    dbAddr      = cfg.dbAddr
    coordinator = cfg.coordinator or source
    agentIndex  = cfg.agentIndex or agentIndex  -- BugFix #B21

    -- 模块系统初始化(仅首次)
    ModuleManager.scan("Logic")
    ModuleManager.init()

    -- Fix #13: 周期定时存盘(每5分钟)
    local SAVE_INTERVAL_SEC = 300
    local function periodicSave()
        if stopping then return end
        skynet.timeout(SAVE_INTERVAL_SEC * 100, function()
            if stopping then return end
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
            periodicSave()
        end)
    end
    periodicSave()

    skynet.error(string.format("[Agent%d] initialized, %d modules loaded",
        agentIndex, ModuleManager.getModuleCount()))
end

--- 玩家上线(gate cast过来)
--- 容器职责: 创建entry、处理顶号、发起异步加载
---@param source integer
---@param req table  { uid, fd, gate }
function handler.online(source, req)
    -- 顶号检测
    local old = entries[req.uid]
    if old then
        -- BugFix #B16: kick携带uid
        Cast.send(old.gate, "kick", { fd = old.fd, uid = old.uid, reason = 1 })
        -- 触发旧Player的登出清理(逆序)
        if old.player then
            ModuleManager.triggerReverse("onLogout", old.player)
            ModuleManager.unmount(old.player)
            old.player:destroy()  -- Fix #11: 断开entry引用
            old.player = nil
        end
        -- Fix #12: loading状态被顶号，记录pending丢弃信息
        if old.loading and old.pending and #old.pending > 0 then
            skynet.error(string.format(
                "[Agent%d] player %d replaced during loading, %d pending msgs discarded",
                agentIndex, req.uid, #old.pending))
        end
        notifyCrossLeave(req.uid)  -- Fix #4
        -- 不减playerCount，同uid复用slot
    else
        playerCount = playerCount + 1
    end

    -- Fix #9: 递增loadSeq
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
        player  = nil,  -- loading完成后创建
        dirty   = false,  -- Fix #13: 定时存盘标记
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
--- 容器职责: 校验loadSeq、填充data、创建Player并mount模块、触发生命周期、回放pending
--- Fix #9: 忽略过期loadResult
--- BugFix #B17: 回放pending时检测player是否已被移除
---@param source integer
---@param result table  { uid, data, loadSeq }
function handler.loadResult(source, result)
    local entry = entries[result.uid]
    if not entry then return end

    -- Fix #9
    if result.loadSeq and entry.loadSeq ~= result.loadSeq then
        skynet.error(string.format("[Agent%d] stale loadResult uid=%d seq=%d expect=%d, ignored",
            agentIndex, result.uid, result.loadSeq, entry.loadSeq))
        return
    end

    entry.data    = result.data or {}
    entry.loading = false
    entry.dirty   = true  -- Fix #13: 新加载数据标记dirty

    -- 创建业务根对象 + 挂载模块
    local player = Player.new(entry)
    entry.player = player

    -- 模块实例化(按拓扑序)
    ModuleManager.mount(player)

    -- 触发数据初始化钩子(模块读取/修正持久化数据)
    ModuleManager.trigger("onDbInit", player)

    -- 触发登录钩子(推送初始数据等)
    ModuleManager.trigger("onPlayerLogin", player)

    -- 回放加载期间暂存的消息
    local pending = entry.pending
    entry.pending = nil
    if pending then
        for _, msg in ipairs(pending) do
            -- BugFix #B17
            if not entries[result.uid] then
                skynet.error(string.format(
                    "[Agent%d] pending replay interrupted: uid=%d removed",
                    agentIndex, result.uid))
                break
            end
            dispatchClientMsg(entry, msg.msgId, msg.body)
        end
    end
end

--- 玩家离线(gate cast过来)
--- Fix #2: loading期间不存盘
--- Fix #4: 通知Cross
---@param source integer
---@param req table  { uid, fd, gate }
function handler.offline(source, req)
    local entry = entries[req.uid]
    if not entry then return end
    if entry.fd ~= req.fd then return end  -- 已被顶号，忽略旧fd

    -- 触发登出钩子(逆序，模块可做清理/追加存盘数据)
    if entry.player then
        ModuleManager.triggerReverse("onLogout", entry.player)
        ModuleManager.unmount(entry.player)
        entry.player:destroy()  -- Fix #11: 断开entry引用
        entry.player = nil
    end

    notifyCrossLeave(req.uid)  -- Fix #4

    -- Fix #2: loading期间不存盘
    if not entry.loading then
        Cast.send(dbAddr, "save", { uid = req.uid, data = entry.data })
    else
        skynet.error(string.format("[Agent%d] player %d offline during loading, skip save",
            agentIndex, req.uid))
    end

    entries[req.uid] = nil
    playerCount = playerCount - 1
    skynet.error(string.format("[Agent%d] player offline: %d", agentIndex, req.uid))
end

--- 处理客户端消息(gate转发过来)
--- 容器职责: loading期间暂存(心跳除外)，否则分发
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

--- 优雅关闭: 触发所有在线玩家的关闭钩子 + 存盘
--- Fix #2: 只存盘非loading的玩家
---@param source integer
function handler.shutdown(source)
    stopping = true  -- Fix #13: 停止定时存盘
    skynet.error(string.format("[Agent%d] shutting down, saving %d players...",
        agentIndex, playerCount))

    for uid, entry in pairs(entries) do
        -- 触发关闭钩子(逆序)
        if entry.player then
            ModuleManager.triggerReverse("onShutdown", entry.player)
            ModuleManager.unmount(entry.player)
            entry.player:destroy()  -- Fix #11
            entry.player = nil
        end
        if not entry.loading then
            Cast.send(dbAddr, "save", { uid = uid, data = entry.data })
        end
    end

    entries = {}
    playerCount = 0
    skynet.error(string.format("[Agent%d] shutdown complete", agentIndex))
    Cast.send(coordinator, "shutdownAck")
end

----------------------------------------------------------------
Dispatch.new(handler)