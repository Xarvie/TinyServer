--------------------------------------------------------------
-- framework.lua
-- 框架公共模块：protocol + codec + player + loader
--------------------------------------------------------------

local F = {}

--------------------------------------------------------------
-- protocol: 协议 ID 解析/构建
--------------------------------------------------------------
local protocol = {}

protocol.TYPE_C2S  = 1
protocol.TYPE_CMD  = 2
protocol.TYPE_S2C  = 5
protocol.TYPE_PUSH = 8

local VALID_TYPES = {
    [protocol.TYPE_C2S] = true, [protocol.TYPE_CMD] = true,
    [protocol.TYPE_S2C] = true, [protocol.TYPE_PUSH] = true,
}

function protocol.parse(pid)
    if type(pid) ~= "number" then
        return nil, nil, nil, "protocol_id must be a number"
    end
    pid = math.floor(pid)
    if pid < 1000000 or pid > 9999999 then
        return nil, nil, nil, "protocol_id out of range: " .. pid
    end
    local t   = math.floor(pid / 1000000)
    local mid = math.floor((pid % 1000000) / 1000)
    local seq = pid % 1000
    if not VALID_TYPES[t] then
        return nil, nil, nil, "invalid type: " .. t
    end
    if mid < 1 or mid > 999 then
        return nil, nil, nil, "invalid module_id: " .. mid
    end
    if seq < 1 or seq > 999 then
        return nil, nil, nil, "invalid seq: " .. seq
    end
    return t, mid, seq, nil
end

function protocol.build(t, mid, seq)
    assert(VALID_TYPES[t], "invalid type")
    assert(mid >= 1 and mid <= 999)
    assert(seq >= 1 and seq <= 999)
    return t * 1000000 + mid * 1000 + seq
end

function protocol.c2s_to_s2c(c2s_id)
    local t, mid, seq, err = protocol.parse(c2s_id)
    if err then return nil, err end
    if t ~= protocol.TYPE_C2S then return nil, "not C2S" end
    return protocol.build(protocol.TYPE_S2C, mid, seq)
end

function protocol.is_c2s(pid)
    return math.floor(pid / 1000000) == protocol.TYPE_C2S
end

function protocol.is_server_send(pid)
    local t = math.floor(pid / 1000000)
    return t == protocol.TYPE_S2C or t == protocol.TYPE_PUSH
end

function protocol.get_module_id(pid)
    return math.floor((pid % 1000000) / 1000)
end

F.protocol = protocol

--------------------------------------------------------------
-- codec: JSON 编解码 + 帧封装
--------------------------------------------------------------
local json = require "cjson.safe"
local codec = {}

codec.MAX_FRAME_LEN = 65535

function codec.encode(protocol_id, data)
    local payload = json.encode({ id = protocol_id, data = data or {} })
    if not payload then return nil, "json encode failed" end
    local len = #payload
    if len > codec.MAX_FRAME_LEN then return nil, "payload too large" end
    return string.char(math.floor(len / 256), len % 256) .. payload
end

function codec.decode(raw)
    if not raw or #raw == 0 then return nil, nil, "empty payload" end
    local msg = json.decode(raw)
    if not msg then return nil, nil, "json decode failed" end
    local id = tonumber(msg.id)
    if not id then return nil, nil, "missing protocol id" end
    return id, msg.data or {}, nil
end

F.codec = codec

--------------------------------------------------------------
-- player: Player 对象模型
--------------------------------------------------------------
local player = {}

function player.new(uid, gate_addr)
    return {
        uid        = uid,
        gate_addr  = gate_addr,
        fd         = nil,
        login_time = os.time(),
        online     = true,
    }
end

function player.bind_data(p, db_modules)
    for name, info in pairs(db_modules) do
        local cap = name:sub(1,1):upper() .. name:sub(2)
        p[cap .. "Data"]  = info.data
        p[cap .. "Dirty"] = false
    end
end

function player.collect_dirty(p)
    local m = {}
    for k, v in pairs(p) do
        if type(k) == "string" and k:match("Dirty$") and v == true then
            local dk = k:sub(1, -6) .. "Data"
            if p[dk] then m[dk] = p[dk] end
        end
    end
    return m
end

function player.clear_dirty(p)
    for k in pairs(p) do
        if type(k) == "string" and k:match("Dirty$") then
            p[k] = false
        end
    end
end

function player.collect_all_data(p)
    local m = {}
    for k, v in pairs(p) do
        if type(k) == "string" and k:match("Data$") then
            m[k] = v
        end
    end
    return m
end

F.player = player

--------------------------------------------------------------
-- loader: 模块自动发现、加载、热更新
--------------------------------------------------------------
local skynet = require "skynet"
local loader = {}

loader.modules      = {}   -- module_id -> { agent=mod, inter=mod }
loader.c2s_routes   = {}   -- pid -> { module_id, func_name, module_ref }
loader.s2c_registry = {}   -- pid -> { module_id, name }
loader.cmd_routes   = {}   -- func_name -> { module_id, module_ref }
loader.inter_funcs  = {}   -- func_name -> { module_id, module_ref }
loader.loaded_files = {}   -- req_path -> { module_id, module_type }

local function register_agent(mod, mid, path)
    if mod.C2S then
        for pid, fname in pairs(mod.C2S) do
            local t, pmid, _, err = protocol.parse(pid)
            if err then error(string.format("[%s] bad C2S %d: %s", path, pid, err)) end
            if t ~= protocol.TYPE_C2S then
                error(string.format("[%s] C2S has non-C2S: %d", path, pid))
            end
            if pmid ~= mid then
                error(string.format("[%s] C2S %d module mismatch %d vs %d", path, pid, pmid, mid))
            end
            if loader.c2s_routes[pid] then
                error(string.format("[%s] dup C2S %d", path, pid))
            end
            if type(mod[fname]) ~= "function" then
                error(string.format("[%s] handler '%s' not function", path, fname))
            end
            loader.c2s_routes[pid] = { module_id = mid, func_name = fname, module_ref = mod }
        end
    end

    local function reg_s2c(tbl)
        if not tbl then return end
        for pid, name in pairs(tbl) do
            local t, _, _, err = protocol.parse(pid)
            if err then error(string.format("[%s] bad S2C %d: %s", path, pid, err)) end
            if t ~= protocol.TYPE_S2C and t ~= protocol.TYPE_PUSH then
                error(string.format("[%s] S2C has bad type: %d", path, pid))
            end
            loader.s2c_registry[pid] = { module_id = mid, name = name }
        end
    end
    reg_s2c(mod.S2C)
    reg_s2c(mod.PUSH)

    for fname, fn in pairs(mod) do
        if type(fn) == "function" and fname:match("^On%u") then
            loader.cmd_routes[fname] = { module_id = mid, module_ref = mod }
        end
    end

    loader.modules[mid] = loader.modules[mid] or {}
    loader.modules[mid].agent = mod
end

local function register_inter(mod, mid, path)
    for fname, fn in pairs(mod) do
        if type(fn) == "function" and not fname:match("^_") then
            loader.inter_funcs[fname] = { module_id = mid, module_ref = mod, func = fn }
        end
    end
    loader.modules[mid] = loader.modules[mid] or {}
    loader.modules[mid].inter = mod
end

local function parse_filename(filename)
    return filename:match("^(.+)_(%w+)$")
end

function loader.scan_and_load(scan_paths, module_type)
    local lfs = require "lfs"
    local loaded, errors = 0, {}

    for _, dir in ipairs(scan_paths) do
        local iter, obj = lfs.dir(dir)
        if iter then
            for entry in iter, obj do
                if entry:match("_%w+%.lua$") then
                    local base = entry:sub(1, -5)
                    local _, mtype = parse_filename(base)
                    if mtype == module_type then
                        local req_path = dir:gsub("^module/", "") .. "/" .. base
                        local ok, mod = pcall(require, req_path)
                        if not ok then
                            table.insert(errors, "load fail: " .. req_path .. " " .. tostring(mod))
                        elseif type(mod) ~= "table" then
                            table.insert(errors, "not table: " .. req_path)
                        elseif not mod._MODULE_ID then
                            table.insert(errors, "no _MODULE_ID: " .. req_path)
                        else
                            local mid = mod._MODULE_ID
                            local ok2, err2 = true, nil
                            if module_type == "agent" then
                                ok2, err2 = pcall(register_agent, mod, mid, req_path)
                            elseif module_type == "inter" then
                                ok2, err2 = pcall(register_inter, mod, mid, req_path)
                            end
                            if ok2 then
                                loader.loaded_files[req_path] = { module_id = mid, module_type = module_type }
                                loaded = loaded + 1
                            else
                                table.insert(errors, tostring(err2))
                            end
                        end
                    end
                end
            end
        end
    end
    return loaded, errors
end

function loader.resolve_c2s(pid)
    local r = loader.c2s_routes[pid]
    if not r then return nil, nil, "no handler for " .. pid end
    return r.module_ref, r.func_name, r.module_id
end

function loader.resolve_agent_cmd(func_name)
    local r = loader.cmd_routes[func_name]
    if not r then return nil, nil end
    return r.module_ref, r.module_ref[func_name]
end

function loader.resolve_inter(func_name)
    local r = loader.inter_funcs[func_name]
    if not r then return nil, nil end
    return r.module_ref, r.func
end

local function collect_hooks(hook_name)
    local hooks = {}
    for mid, mt in pairs(loader.modules) do
        if mt.agent and type(mt.agent[hook_name]) == "function" then
            hooks[#hooks+1] = { module_id = mid, func = mt.agent[hook_name] }
        end
    end
    table.sort(hooks, function(a, b) return a.module_id < b.module_id end)
    return hooks
end

function loader.get_init_hooks()    return collect_hooks("OnInit") end
function loader.get_destroy_hooks() return collect_hooks("OnDestroy") end

function loader.hotreload(module_name, module_type, scan_paths)
    local target_file = module_name .. "_" .. module_type
    local found_path = nil

    local lfs = require "lfs"
    for _, dir in ipairs(scan_paths) do
        local full = dir .. "/" .. target_file .. ".lua"
        if lfs.attributes(full, "mode") == "file" then
            found_path = dir:gsub("^module/", "") .. "/" .. target_file
            break
        end
    end

    if not found_path then
        return false, "file not found: " .. target_file
    end

    package.loaded[found_path] = nil

    local ok, mod = pcall(require, found_path)
    if not ok then
        return false, "reload failed: " .. tostring(mod)
    end
    if type(mod) ~= "table" or not mod._MODULE_ID then
        return false, "invalid module after reload"
    end

    local mid = mod._MODULE_ID

    if module_type == "agent" then
        local to_remove = {}
        for pid, r in pairs(loader.c2s_routes) do
            if r.module_id == mid then to_remove[#to_remove+1] = pid end
        end
        for _, pid in ipairs(to_remove) do loader.c2s_routes[pid] = nil end

        local cmd_remove = {}
        for fn, r in pairs(loader.cmd_routes) do
            if r.module_id == mid then cmd_remove[#cmd_remove+1] = fn end
        end
        for _, fn in ipairs(cmd_remove) do loader.cmd_routes[fn] = nil end

        register_agent(mod, mid, found_path)

    elseif module_type == "inter" then
        local ifr = {}
        for fn, r in pairs(loader.inter_funcs) do
            if r.module_id == mid then ifr[#ifr+1] = fn end
        end
        for _, fn in ipairs(ifr) do loader.inter_funcs[fn] = nil end

        register_inter(mod, mid, found_path)
    end

    loader.loaded_files[found_path] = { module_id = mid, module_type = module_type }
    return true, "reloaded " .. found_path
end

F.loader = loader

--------------------------------------------------------------
-- 兼容 shim：让旧的 require "protocol" 等继续工作
--------------------------------------------------------------
function F.install_compat()
    package.loaded["protocol"]      = protocol
    package.loaded["codec"]         = codec
    package.loaded["player"]        = player
    package.loaded["module_loader"] = loader
end

return F