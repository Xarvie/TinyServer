--------------------------------------------------------------
-- cross_manager.lua — 跨服管理服务 (M3)
--
-- 职责:
--   1. Cross 服务生命周期管理 (启动/停止/健康检查)
--   2. 通过 Gate 路由消息到对应 Cross 实例
--   3. Cross 模块自动发现加载
--------------------------------------------------------------
local skynet    = require "skynet"
local loader    = require "module_loader"
local game_conf = require "game_config"
local log       = require "log"

local CMD = {}
local gate_addr = nil

-- cross_type -> { addr, module_id, status, start_time }
local cross_instances = {}
local cross_modules_loaded = false

local function tcount(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

--------------------------------------------------------------
-- Cross 模块加载
--------------------------------------------------------------
local function load_cross_modules()
    if cross_modules_loaded then return end
    local c, e = loader.scan_and_load(game_conf.module.scan_paths, "cross")
    for _, err in ipairs(e) do log.error("[CrossMgr] load err:", err) end
    log.info("[CrossMgr] loaded", c, "cross modules")
    cross_modules_loaded = true
end

--------------------------------------------------------------
-- 全局工具注入 (Cross 模块可用)
--------------------------------------------------------------
local function inject_globals()
    rawset(_G, "RouteToAgent", function(uid, func_name, data)
        if gate_addr then
            skynet.send(gate_addr, "lua", "route_to_agent", uid, func_name, data)
        end
    end)

    rawset(_G, "BroadcastToAgents", function(uid_list, func_name, data)
        if gate_addr then
            skynet.send(gate_addr, "lua", "broadcast", uid_list, func_name, data)
        end
    end)

    rawset(_G, "GetOnlineUids", function()
        if gate_addr then
            return skynet.call(gate_addr, "lua", "get_online_uids")
        end
        return {}
    end)

    rawset(_G, "LogInfo",  function(...) log.info(...) end)
    rawset(_G, "LogError", function(...) log.error(...) end)
    rawset(_G, "LogFlow",  function(t, d) log.flow(t, d) end)
end

--------------------------------------------------------------
-- CMD
--------------------------------------------------------------

function CMD.init(_, p_gate_addr)
    gate_addr = p_gate_addr
    inject_globals()
    load_cross_modules()
    log.info("[CrossMgr] init, gate:", skynet.address(gate_addr))
    return true
end

--- Gate 转发跨服请求到对应 Cross
function CMD.route_to_cross(_, uid, cross_type, func_name, data)
    -- 在本进程内查找 cross 模块函数
    local mod, fn = loader.resolve_inter(func_name)
    if fn then
        local ok, err = pcall(fn, uid, data)
        if not ok then
            log.error("[CrossMgr] handler err:", func_name, err)
        end
        return
    end

    -- 兜底遍历
    for mid, mt in pairs(loader.modules) do
        if mt.inter and type(mt.inter[func_name]) == "function" then
            local ok2, err2 = pcall(mt.inter[func_name], uid, data)
            if not ok2 then log.error("[CrossMgr] err:", func_name, err2) end
            return
        end
    end

    log.warn("[CrossMgr] func not found:", func_name, "cross_type:", cross_type)
end

--- 获取 Cross 实例状态
function CMD.get_status(_)
    local status = {}
    for ct, info in pairs(cross_instances) do
        status[ct] = {
            status     = info.status,
            start_time = info.start_time,
        }
    end
    -- 也包含已加载的模块信息
    status._loaded_modules = tcount(loader.modules)
    status._loaded_funcs   = tcount(loader.inter_funcs)
    return status
end

--- 热更新 Cross 模块
function CMD.hotreload(_, module_name)
    local ok, msg = loader.hotreload(module_name, "cross", game_conf.module.scan_paths)
    if ok then
        log.info("[CrossMgr] hotreload ok:", msg)
        return true, msg
    else
        log.error("[CrossMgr] hotreload fail:", msg)
        return false, msg
    end
end

--- 健康检查
function CMD.health_check(_)
    return { alive = true, modules = tcount(loader.modules) }
end

--------------------------------------------------------------
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session ~= 0 then skynet.ret(skynet.pack(f(source, ...)))
            else f(source, ...) end
        end
    end)
    log.info("[CrossMgr] service loaded")
end)