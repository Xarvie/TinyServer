--------------------------------------------------------------
-- db_service.lua — 数据持久化 (M2: 多模块支持)
--------------------------------------------------------------
local skynet    = require "skynet"
local mongo     = require "skynet.db.mongo"
local game_conf = require "game_config"
local log       = require "log"

local CMD = {}
local db_client, db_handle, col
local db_modules = {}

local function tcount(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

local function load_db_modules()
    local lfs = require "lfs"
    for _, dir in ipairs(game_conf.module.scan_paths) do
        local iter, obj = lfs.dir(dir)
        if iter then
            for entry in iter, obj do
                if entry:match("_db%.lua$") then
                    local base = entry:sub(1, -5)
                    local mname = base:match("^(.+)_db$")
                    if mname then
                        local rp = dir:gsub("^module/", "") .. "/" .. base
                        local ok, mod = pcall(require, rp)
                        if ok and type(mod) == "table" and type(mod.GetDefaultData) == "function" then
                            db_modules[mname] = mod
                            log.info("[DB] loaded:", mname)
                        end
                    end
                end
            end
        end
    end
    log.info("[DB] total db modules:", tcount(db_modules))
end

local function connect_mongo()
    local c = game_conf.db
    local opts = { host = c.host, port = c.port }
    if c.username then
        opts.username = c.username
        opts.password = c.password
        opts.authdb   = c.auth_db or c.name
    end
    db_client = mongo.client(opts)
    db_handle = db_client[c.name]
    col = db_handle[c.player_col]
    col:createIndex({{ uid = 1 }}, { unique = true })
    log.info("[DB] mongo connected:", c.host .. ":" .. c.port)
end

local function mongo_update(uid, fields)
    col:update({ uid = uid }, { ["$set"] = fields }, true)
end

function CMD.load_player(_, uid)
    log.info("[DB] load uid:", uid)
    local doc = col:findOne({ uid = uid })
    local is_new = (doc == nil)
    local result = { modules = {}, is_new = is_new }

    for mname, dbmod in pairs(db_modules) do
        local cap = mname:sub(1,1):upper() .. mname:sub(2)
        local dk, vk = cap .. "Data", cap .. "Version"
        local data = doc and doc[dk]
        local ver  = doc and doc[vk] or 0

        if not data then
            data = dbmod.GetDefaultData()
            ver  = dbmod._DATA_VERSION or 1
            is_new = true
        else
            local tv = dbmod._DATA_VERSION or 1
            if ver < tv and type(dbmod.MigrateData) == "function" then
                log.info("[DB] migrate uid:", uid, mname, "v" .. ver, "->", "v" .. tv)
                data = dbmod.MigrateData(data, ver)
                ver = tv
                mongo_update(uid, { [dk] = data, [vk] = ver })
            end
        end
        result.modules[mname] = { data = data, version = ver }
    end

    if is_new then
        local doc2 = { uid = uid, _create_time = os.time() }
        for mname, info in pairs(result.modules) do
            local cap = mname:sub(1,1):upper() .. mname:sub(2)
            doc2[cap .. "Data"]    = info.data
            doc2[cap .. "Version"] = info.version
        end
        mongo_update(uid, doc2)
        log.info("[DB] new player uid:", uid)
    end

    return result
end

function CMD.save_player(_, uid, dirty_map)
    if not dirty_map or not next(dirty_map) then return end
    dirty_map._save_time = os.time()
    local ok, err = pcall(mongo_update, uid, dirty_map)
    if not ok then log.error("[DB] save fail uid:", uid, err) end
end

function CMD.save_player_full(_, uid, all_data)
    if not all_data or not next(all_data) then return end
    all_data._save_time = os.time()
    local ok, err = pcall(mongo_update, uid, all_data)
    if not ok then log.error("[DB] full save fail uid:", uid, err)
    else log.flow("SAVE", { uid = uid, type = "full" }) end
end

skynet.start(function()
    load_db_modules()
    connect_mongo()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session ~= 0 then skynet.ret(skynet.pack(f(source, ...)))
            else f(source, ...) end
        end
    end)
    log.info("[DB] ready")
end)
