-- lualib/Shutdown.lua
-- 优雅关闭编排: gate -> agent/cross/id -> db
-- 全cast，各服务完成后cast回 shutdownAck 驱动下一阶段
-- 兜底: 每阶段最长等待 PHASE_TIMEOUT_SEC 秒
--
-- 关闭顺序设计:
--   phase1: gate       (停止接入新连接)
--   phase2: agent+cross+id  (id 在 db 之前关闭，确保最终 saveIdCounter 被 db 处理)
--   phase3: db         (最后关闭，flush 所有写入)
--
-- Fix #3: 用地址集合(pendingAcks)精确跟踪每阶段的ack来源
-- BugFix #B9: 用 pendingCount 计数器替代遍历 pendingAcks，O(1)

local skynet = require "skynet"
local Cast   = require "Cast"

---@class Shutdown
local Shutdown = {}

local PHASE_TIMEOUT_SEC    = 5
local PHASE2_TIMEOUT_SEC   = 10  -- Fix #3: phase2需要更长超时(agent要存盘)
local ABSOLUTE_TIMEOUT_SEC = 30

local phase       = 0
local started     = false
local gates       = {}    ---@type integer[]
local agents      = {}    ---@type integer[]
local dbAddr      = 0     ---@type integer
local crossAddr   = nil   ---@type integer|nil
local idAddr      = nil   ---@type integer|nil

local pendingAcks  = {}   ---@type table<integer, boolean>
local pendingCount = 0

--- 进入下一阶段
local function nextPhase()
    phase = phase + 1
    pendingAcks  = {}
    pendingCount = 0

    if phase == 1 then
        -- Phase 1: 关闭gate(停止接入)
        skynet.error(string.format("[Shutdown] phase1: closing %d gates", #gates))
        if #gates == 0 then
            nextPhase()
            return
        end
        for _, addr in ipairs(gates) do
            pendingAcks[addr] = true
            pendingCount = pendingCount + 1
        end
        Cast.broadcast(gates, "shutdown")
        skynet.timeout(PHASE_TIMEOUT_SEC * 100, function()
            if phase == 1 then
                skynet.error("[Shutdown] phase1 timeout, forcing next phase")
                nextPhase()
            end
        end)

    elseif phase == 2 then
        -- Phase 2: 关闭 agent + cross + id
        -- id 必须在 db 之前关闭: shutdown 时 id cast saveIdCounter 到 db,
        -- db 在 phase3 才关闭, 保证这条 cast 被处理
        skynet.error(string.format("[Shutdown] phase2: closing %d agents + cross + id", #agents))
        for _, addr in ipairs(agents) do
            pendingAcks[addr] = true
            pendingCount = pendingCount + 1
        end
        if crossAddr then
            pendingAcks[crossAddr] = true
            pendingCount = pendingCount + 1
        end
        if idAddr then
            pendingAcks[idAddr] = true
            pendingCount = pendingCount + 1
        end
        if pendingCount == 0 then
            nextPhase()
            return
        end
        Cast.broadcast(agents, "shutdown")
        if crossAddr then
            Cast.send(crossAddr, "shutdown")
        end
        if idAddr then
            Cast.send(idAddr, "shutdown")
        end
        skynet.timeout(PHASE2_TIMEOUT_SEC * 100, function()  -- Fix #3: 使用更长超时
            if phase == 2 then
                skynet.error("[Shutdown] phase2 timeout, forcing next phase")
                nextPhase()
            end
        end)

    elseif phase == 3 then
        -- Phase 3: 关闭db(最后, flush所有pending writes)
        skynet.error("[Shutdown] phase3: closing db")
        pendingAcks[dbAddr] = true
        pendingCount = 1
        Cast.send(dbAddr, "shutdown")
        skynet.timeout(PHASE_TIMEOUT_SEC * 100, function()
            if phase == 3 then
                skynet.error("[Shutdown] phase3 timeout, forcing exit")
                nextPhase()
            end
        end)

    else
        skynet.error("[Shutdown] === graceful shutdown complete ===")
        skynet.timeout(10, function()
            skynet.abort()
        end)
    end
end

--- 接收服务的关闭完成确认
---@param source integer
function Shutdown.onAck(source)
    if not pendingAcks[source] then
        skynet.error(string.format("[Shutdown] ignoring stale/unexpected ack from %08x (phase%d)",
            source, phase))
        return
    end
    pendingAcks[source] = nil
    pendingCount = pendingCount - 1
    skynet.error(string.format("[Shutdown] phase%d ack from %08x, remaining=%d",
        phase, source, pendingCount))
    if pendingCount <= 0 then
        nextPhase()
    end
end

--- 执行优雅关闭序列
---@param gateList integer[]
---@param agentList integer[]
---@param db integer
---@param cross integer|nil
---@param id integer|nil
function Shutdown.execute(gateList, agentList, db, cross, id)
    if started then
        skynet.error("[Shutdown] already in progress, ignoring duplicate execute")
        return
    end
    started = true

    skynet.error("[Shutdown] === graceful shutdown begin ===")
    gates     = gateList
    agents    = agentList
    dbAddr    = db
    crossAddr = cross
    idAddr    = id
    phase     = 0

    skynet.timeout(ABSOLUTE_TIMEOUT_SEC * 100, function()
        skynet.error("[Shutdown] ABSOLUTE TIMEOUT reached, forcing abort")
        skynet.abort()
    end)

    nextPhase()
end

return Shutdown