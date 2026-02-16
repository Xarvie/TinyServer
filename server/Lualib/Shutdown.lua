-- lualib/Shutdown.lua
-- 优雅关闭编排: gate -> agent/cross/id -> db
-- 全cast，各服务完成后cast回 shutdownAck 驱动下一阶段
-- 兜底: 每阶段最长等待 PHASE_TIMEOUT_SEC 秒
--
-- 关闭顺序:
--   phase1: gate          停止接入新连接
--   phase2: agent+cross+id  id 在 db 之前关闭，确保 saveIdCounter 被 db 处理
--   phase3: db            最后关闭，flush 所有写入

local skynet = require "skynet"
local Cast   = require "Cast"

---@class Shutdown
local Shutdown = {}

----------------------------------------------------------------
-- 常量
----------------------------------------------------------------
local PHASE1_TIMEOUT_SEC   = 5
local PHASE2_TIMEOUT_SEC   = 10   -- agent 需要更长超时(存盘)
local PHASE3_TIMEOUT_SEC   = 5
local ABSOLUTE_TIMEOUT_SEC = 30

----------------------------------------------------------------
-- 状态(收敛到单表，避免散落的 upvalue)
----------------------------------------------------------------
local S = {
    phase        = 0,
    started      = false,
    gates        = {},    ---@type integer[]
    agents       = {},    ---@type integer[]
    dbAddr       = 0,     ---@type integer
    crossAddr    = nil,   ---@type integer|nil
    idAddr       = nil,   ---@type integer|nil
    pendingAcks  = {},    ---@type table<integer, boolean>
    pendingCount = 0,
}

----------------------------------------------------------------
-- 阶段推进
----------------------------------------------------------------

local function nextPhase()  -- forward declaration
end

--- 发起一个阶段: 设置 pending 集合 + 发送 shutdown + 注册超时
---@param targets table[]  { addr1, addr2, ... } 或混合数组
---@param timeoutSec number
local function startPhase(targets, timeoutSec)
    S.pendingAcks  = {}
    S.pendingCount = 0
    for _, addr in ipairs(targets) do
        S.pendingAcks[addr] = true
        S.pendingCount = S.pendingCount + 1
    end

    if S.pendingCount == 0 then
        nextPhase()
        return
    end

    for _, addr in ipairs(targets) do
        Cast.send(addr, "shutdown")
    end

    local phaseSnapshot = S.phase
    skynet.timeout(timeoutSec * 100, function()
        if S.phase == phaseSnapshot then
            skynet.error(string.format("[Shutdown] phase%d timeout, forcing next phase", S.phase))
            nextPhase()
        end
    end)
end

nextPhase = function()
    S.phase = S.phase + 1

    if S.phase == 1 then
        skynet.error(string.format("[Shutdown] phase1: closing %d gates", #S.gates))
        startPhase(S.gates, PHASE1_TIMEOUT_SEC)

    elseif S.phase == 2 then
        -- agent + cross + id 同时关闭
        local targets = {}
        for _, addr in ipairs(S.agents) do
            targets[#targets + 1] = addr
        end
        if S.crossAddr then targets[#targets + 1] = S.crossAddr end
        if S.idAddr    then targets[#targets + 1] = S.idAddr    end
        skynet.error(string.format("[Shutdown] phase2: closing %d agents + cross + id", #S.agents))
        startPhase(targets, PHASE2_TIMEOUT_SEC)

    elseif S.phase == 3 then
        skynet.error("[Shutdown] phase3: closing db")
        startPhase({ S.dbAddr }, PHASE3_TIMEOUT_SEC)

    else
        skynet.error("[Shutdown] === graceful shutdown complete ===")
        skynet.timeout(10, function()
            skynet.abort()
        end)
    end
end

----------------------------------------------------------------
-- 公共接口
----------------------------------------------------------------

--- 接收服务的关闭完成确认
---@param source integer
function Shutdown.onAck(source)
    if not S.pendingAcks[source] then
        skynet.error(string.format("[Shutdown] ignoring stale ack from %08x (phase%d)",
            source, S.phase))
        return
    end
    S.pendingAcks[source] = nil
    S.pendingCount = S.pendingCount - 1
    skynet.error(string.format("[Shutdown] phase%d ack from %08x, remaining=%d",
        S.phase, source, S.pendingCount))
    if S.pendingCount <= 0 then
        nextPhase()
    end
end

--- 执行优雅关闭序列
---@param gateList  integer[]
---@param agentList integer[]
---@param db        integer
---@param cross     integer|nil
---@param id        integer|nil
function Shutdown.execute(gateList, agentList, db, cross, id)
    if S.started then
        skynet.error("[Shutdown] already in progress, ignoring duplicate execute")
        return
    end
    S.started   = true
    S.gates     = gateList
    S.agents    = agentList
    S.dbAddr    = db
    S.crossAddr = cross
    S.idAddr    = id
    S.phase     = 0

    skynet.error("[Shutdown] === graceful shutdown begin ===")

    skynet.timeout(ABSOLUTE_TIMEOUT_SEC * 100, function()
        skynet.error("[Shutdown] ABSOLUTE TIMEOUT reached, forcing abort")
        skynet.abort()
    end)

    nextPhase()
end

return Shutdown