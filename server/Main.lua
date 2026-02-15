-- main.lua
-- 启动入口：拉起所有服务，纯cast，零call
-- 同时作为shutdown协调者，接收各服务的shutdownAck
--
-- 启动顺序: db -> id -> agent -> cross -> (sleep) -> gate
-- 关闭顺序: gate -> agent+cross+id -> db
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

    -- 1. 启动db服务(最先: IdService 依赖它)
    local dbAddr = skynet.newservice("Db/DbService")
    skynet.name(".db", dbAddr)
    skynet.error("[Main] db started")

    -- 2. 启动id服务(全服唯一可被call的服务)
    local idAddr = skynet.newservice("Login/IdService")
    skynet.name(".id", idAddr)
    skynet.error("[Main] id service started")

    -- 3. 启动agent池
    local agents = {}
    for i = 1, Cfg.agentCount do
        local addr = skynet.newservice("Agent/AgentService", i)
        skynet.name(".agent" .. i, addr)
        agents[i] = addr
    end
    skynet.error(string.format("[Main] %d agents started", #agents))

    -- 4. 启动cross(跨服多人)
    local crossAddr = skynet.newservice("Cross/CrossService")
    skynet.name(".cross", crossAddr)
    skynet.error("[Main] cross started")

    -- 5. 启动gate
    local gates = {}
    for i = 1, Cfg.gateCount do
        local addr = skynet.newservice("Gate/GateService", i)
        skynet.name(".gate" .. i, addr)
        gates[i] = addr
    end
    skynet.error(string.format("[Main] %d gates started", #gates))

    -- === 初始化顺序 ===
    -- db 最先(连接mongo), id 紧随(cast db 拿数据), 然后 agent/cross, 最后 gate

    Cast.send(dbAddr, "init", {
        agents      = agents,
        gates       = gates,
        coordinator = self,
        idAddr      = idAddr,
    })

    Cast.send(idAddr, "init", {
        dbAddr      = dbAddr,
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

    -- gate 最后初始化: 等待其他服务就绪
    -- BugFix BUG-11: sleep(100)(1秒)等待 agent ModuleManager.scan 等完成
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
            protoPath      = Cfg.protoPath,
        })
    end

    skynet.error("[Main] all services initialized, system ready")

    -- 6. 注册main自身的命令处理(接收shutdownAck)
    local handler = {}

    function handler.shutdownAck(source)
        Shutdown.onAck(source)
    end

    function handler.shutdown(source)
        Shutdown.execute(gates, agents, dbAddr, crossAddr, idAddr)
    end

    skynet.dispatch("lua", function(_, source, cmd, ...)
        local f = handler[cmd]
        if f then
            f(source, ...)
        end
    end)
end)