-- Db/DbService.lua
-- DB服务: 认证、加载、存盘，单进程串行安全
-- 全cast，零call(唯一例外: 注册流程中 skynet.call IdService.allocUid)
-- 持久化: MongoDB (skynet.db.mongo)
--
-- MongoDB 集合:
--   accounts:   { _id: string(account), uid: integer }
--   players:    { _id: integer(uid), data: table }
--   id_counter: { _id: integer(serverId), cur: integer(playerId天花板) }
--
-- MongoDB 连接在 skynet.start 阶段完成(dispatch注册前)，
-- 确保第一条消息到达时 db 已就绪，避免 yield 导致消息竞态。

local skynet   = require "skynet"
local mongo    = require "skynet.db.mongo"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local MsgId    = require "Proto.MsgId"
local ErrCode  = require "Proto.ErrorCode"

local agents      = {}  ---@type integer[]
local gates       = {}  ---@type integer[]
local coordinator = 0   ---@type integer
local idAddr      = 0   ---@type integer

local client  ---@type table  MongoDB client handle
local db      ---@type table  MongoDB database handle

----------------------------------------------------------------
-- Save 失败重试
----------------------------------------------------------------
local MAX_RETRY_COUNT    = 3
local RETRY_INTERVAL_SEC = 5

---@type table<integer, { uid: integer, data: table, retryCount: integer }>
local saveRetryQueue = {}

----------------------------------------------------------------
-- MongoDB 工具
----------------------------------------------------------------

--- 安全执行 mongo 操作, 失败时记录日志不崩溃
---@param tag string
---@param fn  function
---@return boolean ok
---@return any     result
local function safeMongo(tag, fn)
    local ok, result = pcall(fn)
    if not ok then
        skynet.error(string.format("[DB] %s failed: %s", tag, tostring(result)))
        return false, nil
    end
    return true, result
end

--- 统一发送认证结果(消除 login 中 5 处重复的报文构造)
---@param req  table    原始请求 { fd, sessionId, gate }
---@param code integer  错误码
---@param uid  integer|nil
local function sendAuthResult(req, code, uid)
    Cast.send(req.gate, "authResult", {
        fd        = req.fd,
        sessionId = req.sessionId,
        code      = code,
        uid       = uid,
        msgId     = MsgId.S2C_LoginResult,
    })
end

----------------------------------------------------------------
-- 重试队列处理
----------------------------------------------------------------
local function processRetryQueue()
    if Cast.tableEmpty(saveRetryQueue) then return end

    local toRemove = {}
    for uid, item in pairs(saveRetryQueue) do
        local ok = safeMongo(string.format("retry_save_uid_%d", uid), function()
            db.players:update(
                { _id = uid },
                { ["$set"] = { data = item.data } },
                true
            )
        end)

        if ok then
            skynet.error(string.format("[DB] retry save success: uid=%d after %d retries",
                uid, item.retryCount + 1))
            toRemove[#toRemove + 1] = uid
        else
            item.retryCount = item.retryCount + 1
            if item.retryCount >= MAX_RETRY_COUNT then
                skynet.error(string.format("[DB] CRITICAL: retry save abandoned after %d attempts: uid=%d",
                    MAX_RETRY_COUNT, uid))
                toRemove[#toRemove + 1] = uid
            else
                skynet.error(string.format("[DB] retry save failed: uid=%d, retry=%d/%d",
                    uid, item.retryCount, MAX_RETRY_COUNT))
            end
        end
    end
    for _, uid in ipairs(toRemove) do
        saveRetryQueue[uid] = nil
    end
end

----------------------------------------------------------------
-- 命令处理
----------------------------------------------------------------
local handler = {}
local stopping = false

---@param source integer
---@param cfg table
function handler.init(source, cfg)
    agents      = cfg.agents
    gates       = cfg.gates
    coordinator = cfg.coordinator or source
    idAddr      = cfg.idAddr

    Cast.setInterval(RETRY_INTERVAL_SEC,
        function() return stopping end,
        processRetryQueue
    )

    skynet.error("[DB] init complete (retry task started)")
end

----------------------------------------------------------------
-- IdService 专用: id_counter 读写
----------------------------------------------------------------

---@param source integer
---@param req table  { serverId, idAddr }
function handler.loadIdCounter(source, req)
    local ok, doc = safeMongo("loadIdCounter", function()
        return db.id_counter:findOne({ _id = req.serverId })
    end)
    Cast.send(req.idAddr, "loadIdCounterResult", {
        cur = (ok and doc) and doc.cur or nil,
    })
end

---@param source integer
---@param req table  { serverId, cur }
function handler.saveIdCounter(source, req)
    safeMongo("saveIdCounter", function()
        db.id_counter:update(
            { _id = req.serverId },
            { ["$set"] = { cur = req.cur } },
            true  -- upsert
        )
    end)
end

----------------------------------------------------------------
-- 登录 / 注册
----------------------------------------------------------------

--- 登录或自动注册(gate cast 过来)
--- authkey模式，gate已完成验证
--- 账号存在→返回uid, 不存在→自动注册→返回uid
---@param source integer
---@param req table  { account, fd, sessionId, gate }
function handler.login(source, req)
    local ok, record = safeMongo("login.check", function()
        return db.accounts:findOne({ _id = req.account })
    end)

    if not ok then
        sendAuthResult(req, ErrCode.AUTH_DB_ERROR, nil)
        return
    end

    -- 账号存在，直接登录
    if record then
        sendAuthResult(req, ErrCode.AUTH_OK, record.uid)
        skynet.error(string.format("[DB] login ok: %s -> %d", req.account, record.uid))
        return
    end

    -- 账号不存在，自动注册
    local callOk, uid = pcall(skynet.call, idAddr, "lua", "allocUid")
    if not callOk then
        skynet.error(string.format("[DB] allocUid failed: %s", tostring(uid)))
        sendAuthResult(req, ErrCode.AUTH_DB_ERROR, nil)
        return
    end

    local insertOk = safeMongo("login.autoRegister", function()
        db.accounts:insert({ _id = req.account, uid = uid })
    end)
    if not insertOk then
        -- 并发竞态导致插入失败，重新查询
        local ok2, record2 = safeMongo("login.recheck", function()
            return db.accounts:findOne({ _id = req.account })
        end)
        if ok2 and record2 then
            sendAuthResult(req, ErrCode.AUTH_OK, record2.uid)
            skynet.error(string.format("[DB] register race, recheck ok: %s -> %d", req.account, record2.uid))
            return
        end
        sendAuthResult(req, ErrCode.AUTH_DB_ERROR, nil)
        return
    end

    -- 初始化玩家文档
    safeMongo("login.initPlayer", function()
        db.players:update({ _id = uid }, { _id = uid, data = {} }, true)
    end)

    sendAuthResult(req, ErrCode.AUTH_OK, uid)
    skynet.error(string.format("[DB] register ok: %s -> uid=%d (server=%d player=%d)",
        req.account, uid, uid >> 13, uid & 0x1FFF))
end

----------------------------------------------------------------
-- 玩家数据读写
----------------------------------------------------------------

---@param source integer
---@param req table  { uid, agent, loadSeq }
function handler.load(source, req)
    local ok, doc = safeMongo("load", function()
        return db.players:findOne({ _id = req.uid })
    end)

    Cast.send(req.agent, "loadResult", {
        uid     = req.uid,
        data    = (ok and doc) and doc.data or {},
        loadSeq = req.loadSeq,
    })
end

--- 存盘(fire-and-forget), 失败时加入重试队列
---@param source integer
---@param req table  { uid, data }
function handler.save(source, req)
    local ok = safeMongo("save", function()
        db.players:update(
            { _id = req.uid },
            { ["$set"] = { data = req.data } },
            true
        )
    end)

    if not ok then
        local existing = saveRetryQueue[req.uid]
        if existing then
            -- 同uid已有重试项，用最新data替换(防旧data覆盖新data)
            existing.data = req.data
            skynet.error(string.format("[DB] save failed uid=%d, updated retry item", req.uid))
        else
            saveRetryQueue[req.uid] = {
                uid = req.uid,
                data = req.data,
                retryCount = 0,
            }
            skynet.error(string.format("[DB] save failed uid=%d, added to retry queue", req.uid))
        end
    else
        -- save成功时移除重试项(防旧重试覆盖新数据)
        if saveRetryQueue[req.uid] then
            saveRetryQueue[req.uid] = nil
        end
    end
end

--- 优雅关闭: flush重试队列后断开连接
---@param source integer
function handler.shutdown(source)
    stopping = true
    skynet.error("[DB] shutting down...")

    if not Cast.tableEmpty(saveRetryQueue) then
        local retryCount = Cast.tableSize(saveRetryQueue)
        skynet.error(string.format("[DB] flushing retry queue (%d items)...", retryCount))
        for uid, item in pairs(saveRetryQueue) do
            local ok = safeMongo(string.format("shutdown_flush_uid_%d", uid), function()
                db.players:update(
                    { _id = uid },
                    { ["$set"] = { data = item.data } },
                    true
                )
            end)
            if ok then
                skynet.error(string.format("[DB] shutdown flush success: uid=%d", uid))
            else
                skynet.error(string.format("[DB] CRITICAL: shutdown flush failed: uid=%d", uid))
            end
        end
        saveRetryQueue = {}
    end

    if client then
        pcall(client.disconnect, client)
        client = nil
        db = nil
    end
    skynet.error("[DB] shutdown complete")
    Cast.send(coordinator, "shutdownAck")
end

----------------------------------------------------------------
-- 启动: 先连接 MongoDB，再注册 dispatch
----------------------------------------------------------------
skynet.start(function()
    local Cfg = require "Config.Config"
    local mc = Cfg.mongo or {}
    local host     = mc.host or "127.0.0.1"
    local port     = mc.port or 27017
    local dbname   = mc.db or "game"
    local username = mc.username or ""
    local password = mc.password or ""
    local authdb   = mc.authdb or "admin"

    local conn_cfg = { host = host, port = port }
    if username ~= "" and password ~= "" then
        conn_cfg.username = username
        conn_cfg.password = password
        conn_cfg.authdb   = authdb
    end

    -- 连接(带重试，指数退避)
    local MAX_RETRY      = 10
    local RETRY_BASE_SEC = 2
    local connected      = false

    for attempt = 1, MAX_RETRY do
        local ok, err = pcall(function()
            if client then
                pcall(client.disconnect, client)
                client = nil
                db = nil
            end
            client = mongo.client(conn_cfg)
            db = client:getDB(dbname)
            db:runCommand("ping")
        end)

        if ok then
            connected = true
            break
        end

        skynet.error(string.format("[DB] connect attempt %d/%d failed (%s:%d/%s): %s",
            attempt, MAX_RETRY, host, port, dbname, tostring(err)))

        if attempt < MAX_RETRY then
            local waitSec = math.min(RETRY_BASE_SEC * (2 ^ (attempt - 1)), 30)
            skynet.error(string.format("[DB] retrying in %d seconds...", waitSec))
            skynet.sleep(waitSec * 100)
        end
    end

    if not connected then
        error(string.format("[DB] FATAL: connection failed after %d attempts (%s:%d/%s)",
            MAX_RETRY, host, port, dbname))
    end

    pcall(function()
        db.accounts:createIndex({{ uid = 1 }, unique = true })
    end)

    local auth_info = (username ~= "" and password ~= "")
        and string.format(" (auth: %s@%s)", username, authdb) or " (no auth)"
    skynet.error(string.format("[DB] connected to MongoDB %s:%d/%s%s",
        host, port, dbname, auth_info))

    Dispatch.register(handler)
end)