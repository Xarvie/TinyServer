-- lualib/Shutdown.lua
-- 优雅关闭编排: gate -> agent/cross -> db
-- 全cast，各服务完成后cast回 shutdownAck 驱动下一阶段
-- 兜底: 每阶段最长等待 PHASE_TIMEOUT_SEC 秒
--
-- Fix #3: 用地址集合(pendingAcks)精确跟踪每阶段的ack来源
--         迟到的ack(来自上一阶段)被忽略，不会污染当前阶段计数器
-- BugFix #B9: 用 pendingCount 计数器替代遍历 pendingAcks，O(1)

local skynet = require "skynet"
local Cast   = require "Cast"

---@class Shutdown
local Shutdown = {}

local PHASE_TIMEOUT_SEC    = 5   -- 每阶段最大等待秒数
local ABSOLUTE_TIMEOUT_SEC = 30  -- Fix #19: 绝对超时兜底(所有phase总时长上限)

local phase       = 0
local started     = false  -- BugFix BUG-5: 防重入标志
local gates       = {}    ---@type integer[]
local agents      = {}    ---@type integer[]
local dbAddr      = 0     ---@type integer
local crossAddr   = nil   ---@type integer|nil

-- Fix #3: 用地址集合替代简单计数器
local pendingAcks  = {}   ---@type table<integer, boolean>  当前阶段待ack的服务地址
local pendingCount = 0    -- BugFix #B9: O(1) 计数器

--- 进入下一阶段
local function nextPhase()
    phase = phase + 1
    pendingAcks  = {}  -- Fix #3: 清空，旧阶段的迟到ack自然被忽略
    pendingCount = 0   -- BugFix #B9

    if phase == 1 then
        -- Phase 1: 关闭gate
        skynet.error(string.format("[Shutdown] phase1: closing %d gates", #gates))
        if #gates == 0 then
            nextPhase()
            return
        end
        for _, addr in ipairs(gates) do
            pendingAcks[addr] = true
            pendingCount = pendingCount + 1  -- BugFix #B9
        end
        Cast.broadcast(gates, "shutdown")
        -- 兜底超时
        skynet.timeout(PHASE_TIMEOUT_SEC * 100, function()
            if phase == 1 then
                skynet.error("[Shutdown] phase1 timeout, forcing next phase")
                nextPhase()
            end
        end)

    elseif phase == 2 then
        -- Phase 2: 关闭agent和cross
        skynet.error(string.format("[Shutdown] phase2: closing %d agents + cross", #agents))
        for _, addr in ipairs(agents) do
            pendingAcks[addr] = true
            pendingCount = pendingCount + 1  -- BugFix #B9
        end
        if crossAddr then
            pendingAcks[crossAddr] = true
            pendingCount = pendingCount + 1  -- BugFix #B9
        end
        if pendingCount == 0 then
            nextPhase()
            return
        end
        Cast.broadcast(agents, "shutdown")
        if crossAddr then
            Cast.send(crossAddr, "shutdown")
        end
        skynet.timeout(PHASE_TIMEOUT_SEC * 100, function()
            if phase == 2 then
                skynet.error("[Shutdown] phase2 timeout, forcing next phase")
                nextPhase()
            end
        end)

    elseif phase == 3 then
        -- Phase 3: 关闭db
        skynet.error("[Shutdown] phase3: closing db")
        pendingAcks[dbAddr] = true
        pendingCount = 1  -- BugFix #B9
        Cast.send(dbAddr, "shutdown")
        skynet.timeout(PHASE_TIMEOUT_SEC * 100, function()
            if phase == 3 then
                skynet.error("[Shutdown] phase3 timeout, forcing exit")
                nextPhase()
            end
        end)

    else
        -- 所有阶段完成
        skynet.error("[Shutdown] === graceful shutdown complete ===")
        skynet.timeout(10, function()
            skynet.abort()
        end)
    end
end

--- 接收服务的关闭完成确认
--- Fix #3: 只接受当前阶段pendingAcks中的来源，忽略迟到/重复ack
--- BugFix #B9: O(1) 计数
---@param source integer
function Shutdown.onAck(source)
    if not pendingAcks[source] then
        skynet.error(string.format("[Shutdown] ignoring stale/unexpected ack from %08x (phase%d)",
            source, phase))
        return
    end
    pendingAcks[source] = nil
    pendingCount = pendingCount - 1  -- BugFix #B9: O(1)
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
function Shutdown.execute(gateList, agentList, db, cross)
    -- BugFix BUG-5: 防止重复调用，避免双重关闭
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
    phase     = 0

    -- Fix #19: 绝对超时兜底，防止所有phase完成前系统"半死不活"
    skynet.timeout(ABSOLUTE_TIMEOUT_SEC * 100, function()
        skynet.error("[Shutdown] ABSOLUTE TIMEOUT reached, forcing abort")
        skynet.abort()
    end)

    nextPhase()
end

return Shutdown