--------------------------------------------------------------
-- inter_service.lua
-- Inter 单服协调服务 (M2 新增)
--
-- 职责:
--   1. 全服排行榜、公会等多人协调逻辑
--   2. 模块自动发现加载 (xx_inter.lua)
--   3. 通过 Gate 回调 Agent / 广播
--------------------------------------------------------------
local skynet    = require "skynet"
local loader    = require "module_loader"
local game_conf = require "game_config"
local log       = require "log"

local CMD = {}
local gate_addr = nil
local inter_modules_loaded = false

local function tcount(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

local function load_inter_modules()
    if inter_modules_loaded then return end
    local c, e = loader.scan_and_load(game_conf.module.scan_paths, "inter")
    for _, err in ipairs(e) do log.error("[Inter] load err:", err) end
    log.info("[Inter] loaded", c, "inter modules, funcs:", tcount(loader.inter_funcs))
    inter_modules_loaded = true
end

--------------------------------------------------------------
-- 全局工具注入 (Inter 模块可用)
--------------------------------------------------------------
local function inject_globals()
    --- Inter → Gate → Agent 回调
    rawset(_G, "RouteToAgent", function(uid, func_name, data)
        if gate_addr then
            skynet.send(gate_addr, "lua", "route_to_agent", uid, func_name, data)
        end
    end)

    --- Inter → Gate 广播回调
    rawset(_G, "BroadcastToAgents", function(uid_list, func_name, data)
        if gate_addr then
            skynet.send(gate_addr, "lua", "broadcast", uid_list, func_name, data)
        end
    end)

    --- 获取所有在线玩家 UID
    rawset(_G, "GetOnlineUids", function()
        if gate_addr then
            return skynet.call(gate_addr, "lua", "get_online_uids")
        end
        return {}
    end)

    --- 日志
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
    load_inter_modules()
    log.info("[Inter] init, gate:", skynet.address(gate_addr))
    return true
end

--- 处理 Agent 经 Gate 转发的请求
function CMD.handle_request(_, uid, func_name, data)
    local mod, fn = loader.resolve_inter(func_name)
    if fn then
        local ok, err = pcall(fn, uid, data)
        if not ok then
            log.error("[Inter] handler err:", func_name, err)
        end
        return
    end

    -- 兜底遍历
    for mid, mt in pairs(loader.modules) do
        if mt.inter and type(mt.inter[func_name]) == "function" then
            local ok2, err2 = pcall(mt.inter[func_name], uid, data)
            if not ok2 then log.error("[Inter] err:", func_name, err2) end
            return
        end
    end

    log.warn("[Inter] func not found:", func_name)
end

--- 热更新 Inter 模块
function CMD.hotreload(_, module_name)
    local ok, msg = loader.hotreload(module_name, "inter", game_conf.module.scan_paths)
    if ok then
        log.info("[Inter] hotreload ok:", msg)
        return true, msg
    else
        log.error("[Inter] hotreload fail:", msg)
        return false, msg
    end
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
    log.info("[Inter] service loaded")
end)
