--------------------------------------------------------------
-- main.lua — 引导服务 (M3: 全架构启动)
-- 按顺序拉起: Logger → DB → Inter → CrossManager → Gate
--------------------------------------------------------------
local skynet = require "skynet"

skynet.start(function()
    skynet.error("====== Skynet Game Framework Starting (M3) ======")

    -- 1. Logger (最先启动，其他服务可记录日志)
    local logger_addr = skynet.newservice("logger_service")
    skynet.call(logger_addr, "lua", "init")
    skynet.error("[MAIN] Logger started:", skynet.address(logger_addr))

    -- 2. DB
    local db_addr = skynet.newservice("db_service")
    skynet.error("[MAIN] DB     started:", skynet.address(db_addr))

    -- 3. Inter
    local inter_addr = skynet.newservice("inter_service")
    skynet.error("[MAIN] Inter  started:", skynet.address(inter_addr))

    -- 4. CrossManager
    local cross_mgr_addr = skynet.newservice("cross_manager")
    skynet.error("[MAIN] CrossMgr started:", skynet.address(cross_mgr_addr))

    -- 5. Gate (中心路由，最后启动)
    local gate_addr = skynet.newservice("gate_service")
    skynet.call(gate_addr, "lua", "init", db_addr, inter_addr, cross_mgr_addr, logger_addr)
    skynet.error("[MAIN] Gate   started:", skynet.address(gate_addr))

    -- 6. 连接 Inter ↔ Gate
    skynet.call(inter_addr, "lua", "init", gate_addr)
    skynet.error("[MAIN] Inter linked to Gate")

    -- 7. 连接 CrossManager ↔ Gate
    skynet.call(cross_mgr_addr, "lua", "init", gate_addr)
    skynet.error("[MAIN] CrossMgr linked to Gate")

    skynet.error("====== All Services Ready — Port 8888 ======")
    skynet.error(string.format("  Gate:     %s", skynet.address(gate_addr)))
    skynet.error(string.format("  DB:       %s", skynet.address(db_addr)))
    skynet.error(string.format("  Inter:    %s", skynet.address(inter_addr)))
    skynet.error(string.format("  CrossMgr: %s", skynet.address(cross_mgr_addr)))
    skynet.error(string.format("  Logger:   %s", skynet.address(logger_addr)))
    skynet.error("================================================")
    skynet.exit()
end)