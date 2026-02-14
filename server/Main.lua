-- main.lua
-- 启动入口：拉起所有服务，纯cast，零call
-- 同时作为shutdown协调者，接收各服务的shutdownAck
--
-- BugFix #B14: 调整init顺序，确保agent/db/cross先初始化，再初始化gate(gate init会开始监听)

local skynet   = require "skynet"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local Shutdown = require "Shutdown"
require "skynet.manager"

skynet.start(function()
    skynet.error("[Main] booting...")

    local Cfg = require "Config.Config"
    local self = skynet.self()

    -- 1. 启动db服务(唯一)
    local dbAddr = skynet.newservice("Db/DbService")
    skynet.name(".db", dbAddr)
    skynet.error("[Main] db started")

    -- 2. 启动agent池
    local agents = {}
    for i = 1, Cfg.agentCount do
        local addr = skynet.newservice("Agent/AgentService", i)
        skynet.name(".agent" .. i, addr)
        agents[i] = addr
    end
    skynet.error(string.format("[Main] %d agents started", #agents))

    -- 3. 启动cross(跨服多人)
    local crossAddr = skynet.newservice("Cross/CrossService")
    skynet.name(".cross", crossAddr)
    skynet.error("[Main] cross started")

    -- 4. 启动gate(每个gate知道所有agent和db)
    local gates = {}
    for i = 1, Cfg.gateCount do
        local addr = skynet.newservice("Gate/GateService", i)
        skynet.name(".gate" .. i, addr)
        gates[i] = addr
    end
    skynet.error(string.format("[Main] %d gates started", #gates))

    -- BugFix #B14: 先初始化 db、agent、cross (不监听网络)
    -- 再初始化 gate (gate init 中会开始 socket.listen，必须在其他服务就绪后)

    Cast.send(dbAddr, "init", {
        agents      = agents,
        gates       = gates,
        coordinator = self,
    })

    for i, agentAddr in ipairs(agents) do
        Cast.send(agentAddr, "init", {
            agentIndex  = i,
            gates       = gates,
            dbAddr      = dbAddr,
            coordinator = self,
        })
    end

    Cast.send(crossAddr, "init", {
        coordinator = self,
    })

    -- gate 最后初始化: skynet cast 按发送顺序投递到同一目标，
    -- 但不同目标之间无序。为确保 agent/db 先处理完 init，
    -- BugFix BUG-11: sleep(0) 仅让出一个调度周期，不足以等待 agent 中
    --   ModuleManager.scan(lfs遍历+require) 完成。改为 sleep(100)(1秒)。
    --   更健壮的方案: agent/db/cross init完成后 cast "initDone" 回 main，
    --   main 收集齐全后再初始化 gate。
    skynet.sleep(100)

    for i, gateAddr in ipairs(gates) do
        Cast.send(gateAddr, "init", {
            gateIndex      = i,
            agents         = agents,
            dbAddr         = dbAddr,
            wsPort         = Cfg.wsPort + i - 1,
            maxClient      = Cfg.maxClient,
            coordinator    = self,
            heartbeatSec   = Cfg.heartbeatSec,
            heartbeatCheck = Cfg.heartbeatCheck,
        })
    end

    skynet.error("[Main] all services initialized, system ready")

    -- 5. 注册main自身的命令处理(接收shutdownAck)
    local handler = {}

    function handler.shutdownAck(source)
        Shutdown.onAck(source)
    end

    --- 触发优雅关闭(可由外部信号、GM命令等cast过来)
    function handler.shutdown(source)
        Shutdown.execute(gates, agents, dbAddr, crossAddr)
    end

    -- 直接使用 skynet.dispatch 而不是 Dispatch.new
    -- 避免在 skynet.start 内部再次嵌套复杂的初始化逻辑
    skynet.dispatch("lua", function(_, source, cmd, ...)
        local f = handler[cmd]
        if f then
            f(source, ...)
        end
    end)
end)