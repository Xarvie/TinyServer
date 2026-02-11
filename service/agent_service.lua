--------------------------------------------------------------
-- agent_service.lua
-- Agent 玩家容器 (M2: CMD 回调 + 热更新)
--------------------------------------------------------------
local skynet     = require "skynet"
local player_mod = require "player"
local loader     = require "module_loader"
local codec      = require "codec"
local protocol   = require "protocol"
local send_sdk   = require "send"
local asset_sdk  = require "asset"
local log        = require "log"
local game_conf  = require "game_config"

local CMD = {}
local player, uid, gate_addr
local initialized, exiting = false, false

local function tcount(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

local modules_loaded = false
local function ensure_modules()
    if modules_loaded then return end
    local c, e = loader.scan_and_load(game_conf.module.scan_paths, "agent")
    for _, err in ipairs(e) do log.error("[Agent] load err:", err) end
    log.info("[Agent] loaded", c, "modules, C2S:", tcount(loader.c2s_routes))
    modules_loaded = true
end

local function inject_globals()
    rawset(_G, "SendToClient", function(p, pid, data) send_sdk.SendToClient(p, pid, data) end)
    rawset(_G, "SendToGate",   function(p, rt, ...)   send_sdk.SendToGate(p, rt, ...) end)
    rawset(_G, "AddItem",      function(p, id, cnt)   return asset_sdk.AddItem(p, id, cnt) end)
    rawset(_G, "RemoveItem",   function(p, id, cnt)   return asset_sdk.RemoveItem(p, id, cnt) end)
    rawset(_G, "GetItemCount", function(p, id)         return asset_sdk.GetItemCount(p, id) end)
    rawset(_G, "HasItem",      function(p, id, cnt)   return asset_sdk.HasItem(p, id, cnt) end)
end

local function keys(t)
    local ks = {}; for k in pairs(t) do ks[#ks+1] = k end; return ks
end

-- 定时保存
local function start_auto_save()
    local interval = game_conf.db.save_interval * 100
    local function tick()
        if exiting or not player then return end
        local dm = player_mod.collect_dirty(player)
        if next(dm) then
            log.info("[Agent] save uid:", uid, "fields:", table.concat(keys(dm), ","))
            skynet.send(gate_addr, "lua", "request_save", uid, dm)
            player_mod.clear_dirty(player)
        end
        skynet.timeout(interval, tick)
    end
    skynet.timeout(interval, tick)
end

--------------------------------------------------------------
-- CMD
--------------------------------------------------------------

function CMD.init(_, p_uid, p_gate, db_res)
    uid = p_uid
    gate_addr = p_gate
    inject_globals()
    ensure_modules()

    player = player_mod.new(uid, gate_addr)
    player_mod.bind_data(player, db_res.modules)

    for _, h in ipairs(loader.get_init_hooks()) do
        local ok, err = pcall(h.func, player)
        if not ok then log.error("[Agent] OnInit err mid:", h.module_id, err) end
    end

    start_auto_save()
    initialized = true
    log.info("[Agent] init uid:", uid)
    return true
end

function CMD.set_client_fd(_, fd)
    if player then player.fd = fd end
end

function CMD.handle_c2s(_, p_uid, pid, msg)
    if not initialized or not player or p_uid ~= uid then return end

    local mod, fname, mid = loader.resolve_c2s(pid)
    if not mod then
        local s2c = protocol.c2s_to_s2c(pid)
        if s2c then send_sdk.SendToClient(player, s2c, { code = -1, msg = "module not found" }) end
        return
    end

    local ok, result = pcall(mod[fname], player, msg)
    if not ok then
        log.error("[Agent] C2S err:", fname, result)
        local s2c = protocol.c2s_to_s2c(pid)
        if s2c then send_sdk.SendToClient(player, s2c, { code = -2, msg = "server error" }) end
        return
    end

    if type(result) == "table" then
        local s2c = protocol.c2s_to_s2c(pid)
        if s2c then send_sdk.SendToClient(player, s2c, result) end
    end
end

--- Inter/Cross 回调 (通过 Gate 转发)
function CMD.handle_cmd(_, p_uid, func_name, data)
    if not initialized or not player then return end

    -- 在所有模块中查找函数
    local mod, fn = loader.resolve_agent_cmd(func_name)
    if fn then
        local ok, err = pcall(fn, player, data)
        if not ok then log.error("[Agent] CMD err:", func_name, err) end
        return
    end

    -- 兜底: 遍历模块查找
    for mid, mt in pairs(loader.modules) do
        if mt.agent and type(mt.agent[func_name]) == "function" then
            local ok2, err2 = pcall(mt.agent[func_name], player, data)
            if not ok2 then log.error("[Agent] CMD err:", func_name, err2) end
            return
        end
    end

    log.warn("[Agent] CMD not found:", func_name, "uid:", uid)
end

--- 热更新
function CMD.hotreload(_, module_name, module_type)
    local ok, msg = loader.hotreload(module_name, module_type, game_conf.module.scan_paths)
    if ok then
        log.info("[Agent] hotreload ok:", msg, "uid:", uid)
    else
        log.error("[Agent] hotreload fail:", msg, "uid:", uid)
    end
end

function CMD.on_disconnect(_, p_uid)
    if exiting then return end
    exiting = true
    log.info("[Agent] disconnect uid:", uid)

    for _, h in ipairs(loader.get_destroy_hooks()) do pcall(h.func, player) end

    if player then
        local all = player_mod.collect_all_data(player)
        if next(all) then
            skynet.send(gate_addr, "lua", "request_full_save", uid, all)
        end
        player.online = false
    end

    log.flow("LOGOUT", { uid = uid, time = os.time() })
    skynet.send(gate_addr, "lua", "agent_exited", uid)
    skynet.timeout(50, function() skynet.exit() end)
end

function CMD.force_exit(_) skynet.exit() end

--------------------------------------------------------------
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session ~= 0 then skynet.ret(skynet.pack(f(source, ...)))
            else f(source, ...) end
        else
            log.error("[Agent] unknown cmd:", cmd)
        end
    end)
end)
