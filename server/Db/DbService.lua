-- Db/DbService.lua
-- DB服务: 认证、加载、存盘，单进程串行安全
-- 全cast，零call(唯一例外: DbService被注册流程中的IdService call)
-- 持久化: MongoDB (skynet.db.mongo)
--
-- MongoDB 集合设计:
--   accounts:   { _id: string(account), password: string, uid: integer }
--   players:    { _id: integer(uid), data: table }
--   id_counter: { _id: integer(serverId), cur: integer(playerId天花板) }
--
-- uid分配: 由 IdService 管理，通过 cast 读写 id_counter
--
-- BugFix BUG-38: MongoDB 连接移至 skynet.start 阶段完成(dispatch注册前)。
--   原方案在 handler.init(cast) 中连接 mongo，mongo.client() 是网络操作会 yield，
--   skynet 在 yield 期间会调度同服务的其他消息(如 IdService 发来的 loadIdCounter)，
--   此时 db 尚未赋值导致 "attempt to index a nil value (upvalue 'db')"。
--   修复: 在 skynet.start 回调中先完成 MongoDB 连接，再注册 dispatch，
--   确保第一条消息到达时 db 已就绪。handler.init 仅负责设置服务地址等非IO字段。

local skynet   = require "skynet"
local mongo    = require "skynet.db.mongo"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local MsgId    = require "Proto.MsgId"

local agents      = {}  ---@type integer[]
local gates       = {}  ---@type integer[]
local coordinator = 0   ---@type integer
local idAddr      = 0   ---@type integer  IdService地址

local client  ---@type table  MongoDB client handle
local db      ---@type table  MongoDB database handle

----------------------------------------------------------------
-- MongoDB 工具
----------------------------------------------------------------

--- 安全执行 mongo 操作, 失败时记录日志不崩溃
---@param tag string   操作标签(日志用)
---@param fn  function 操作函数
---@return boolean ok
---@return any     result  成功时为fn返回值, 失败时为nil
local function safeMongo(tag, fn)
    local ok, result = pcall(fn)
    if not ok then
        skynet.error(string.format("[DB] %s failed: %s", tag, tostring(result)))
        return false, nil
    end
    return true, result
end

----------------------------------------------------------------
-- 命令处理
----------------------------------------------------------------
local handler = {}

--- 初始化: 设置服务地址(MongoDB已在skynet.start中连接完毕)
--- BugFix BUG-38: 不再在此处连接MongoDB，避免yield导致后续消息竞态
---@param source integer
---@param cfg table
function handler.init(source, cfg)
    agents      = cfg.agents
    gates       = cfg.gates
    coordinator = cfg.coordinator or source
    idAddr      = cfg.idAddr

    skynet.error("[DB] init complete (service addresses set)")
end

----------------------------------------------------------------
-- IdService 专用: id_counter 读写(cast)
----------------------------------------------------------------

--- 加载 id_counter(IdService 启动时 cast 过来, 一次性)
---@param source integer
---@param req table  { serverId: integer, idAddr: integer }
function handler.loadIdCounter(source, req)
    local ok, doc = safeMongo("loadIdCounter", function()
        return db.id_counter:findOne({ _id = req.serverId })
    end)
    Cast.send(req.idAddr, "loadIdCounterResult", {
        cur = (ok and doc) and doc.cur or nil,
    })
end

--- 保存 id_counter(IdService 定期/触碰天花板/shutdown 时 cast 过来)
---@param source integer
---@param req table  { serverId: integer, cur: integer }
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
--- BugFix: authkey模式，gate已完成验证
--- 逻辑: 账号存在→返回uid, 不存在→自动注册→返回uid
---@param source integer
---@param req table  { account, fd, sessionId, gate }
function handler.login(source, req)
    local ok, record = safeMongo("login.check", function()
        return db.accounts:findOne({ _id = req.account })
    end)

    if not ok then
        -- 数据库错误
        Cast.send(req.gate, "authResult", {
            fd        = req.fd,
            sessionId = req.sessionId,
            code      = 4,
            uid       = nil,
            msgId     = MsgId.S2C_LoginResult,
        })
        return
    end

    -- 账号存在，直接登录
    if record then
        Cast.send(req.gate, "authResult", {
            fd        = req.fd,
            sessionId = req.sessionId,
            code      = 0,
            uid       = record.uid,
            msgId     = MsgId.S2C_LoginResult,
        })
        skynet.error(string.format("[DB] login ok: %s -> %d", req.account, record.uid))
        return
    end

    -- 账号不存在，自动注册
    local callOk, uid = pcall(skynet.call, idAddr, "lua", "allocUid")
    if not callOk then
        skynet.error(string.format("[DB] auto register allocUid failed: %s", tostring(uid)))
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 4, uid = nil, msgId = MsgId.S2C_LoginResult,
        })
        return
    end

    -- 插入新账号
    local insertOk = safeMongo("login.autoRegister", function()
        db.accounts:insert({
            _id  = req.account,
            password = "",  -- authkey模式无密码
            uid  = uid,
        })
    end)
    if not insertOk then
        -- 并发竞态导致插入失败，重新查询uid
        local ok2, record2 = safeMongo("login.recheck", function()
            return db.accounts:findOne({ _id = req.account })
        end)
        if ok2 and record2 then
            Cast.send(req.gate, "authResult", {
                fd = req.fd, sessionId = req.sessionId,
                code = 0, uid = record2.uid, msgId = MsgId.S2C_LoginResult,
            })
            skynet.error(string.format("[DB] auto register race, recheck ok: %s -> %d", req.account, record2.uid))
            return
        end
        -- 仍然失败
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 4, uid = nil, msgId = MsgId.S2C_LoginResult,
        })
        return
    end

    -- 初始化玩家文档
    safeMongo("login.initPlayer", function()
        db.players:update({ _id = uid }, { _id = uid, data = {} }, true)
    end)

    Cast.send(req.gate, "authResult", {
        fd        = req.fd,
        sessionId = req.sessionId,
        code      = 0,
        uid       = uid,
        msgId     = MsgId.S2C_LoginResult,
    })
    skynet.error(string.format("[DB] auto register ok: %s -> uid=%d (server=%d player=%d)",
        req.account, uid, uid >> 13, uid & 0x1FFF))
end

--- 注册(gate cast 过来)
--- uid 由 IdService 分配(call)
---@param source integer
---@param req table  { account, password, fd, sessionId, gate }
function handler.register(source, req)
    -- 1. 快速检查
    local ok, existing = safeMongo("register.check", function()
        return db.accounts:findOne({ _id = req.account })
    end)
    if not ok then
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 4, uid = nil, msgId = MsgId.S2C_RegisterResult,
        })
        return
    end
    if existing then
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 3, uid = nil, msgId = MsgId.S2C_RegisterResult,
        })
        return
    end

    -- 2. 向 IdService 申请 uid (skynet.call — 全服唯一的 call 调用点)
    local callOk, uid = pcall(skynet.call, idAddr, "lua", "allocUid")
    if not callOk then
        skynet.error(string.format("[DB] register allocUid failed: %s", tostring(uid)))
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 4, uid = nil, msgId = MsgId.S2C_RegisterResult,
        })
        return
    end

    -- 3. 插入账号(_id 唯一约束兜底并发竞态)
    local insertOk = safeMongo("register.insert", function()
        db.accounts:insert({
            _id      = req.account,
            password = req.password,
            uid      = uid,
        })
    end)
    if not insertOk then
        Cast.send(req.gate, "authResult", {
            fd = req.fd, sessionId = req.sessionId,
            code = 3, uid = nil, msgId = MsgId.S2C_RegisterResult,
        })
        return
    end

    -- 4. 初始化空玩家文档(upsert)
    safeMongo("register.player", function()
        db.players:update({ _id = uid }, { _id = uid, data = {} }, true)
    end)

    Cast.send(req.gate, "authResult", {
        fd        = req.fd,
        sessionId = req.sessionId,
        code      = 0,
        uid       = uid,
        msgId     = MsgId.S2C_RegisterResult,
    })
    skynet.error(string.format("[DB] register ok: %s -> uid=%d (server=%d player=%d)",
        req.account, uid, uid >> 13, uid & 0x1FFF))
end

----------------------------------------------------------------
-- 玩家数据读写
----------------------------------------------------------------

--- 加载玩家数据(agent cast 过来)
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

--- 存盘(agent cast 过来, fire-and-forget)
---@param source integer
---@param req table  { uid, data }
function handler.save(source, req)
    safeMongo("save", function()
        db.players:update(
            { _id = req.uid },
            { ["$set"] = { data = req.data } },
            true
        )
    end)
end

--- 优雅关闭
---@param source integer
function handler.shutdown(source)
    skynet.error("[DB] shutting down...")
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
-- BugFix BUG-38: MongoDB 连接在 skynet.start 回调中完成，
--   此时 dispatch 尚未注册，不会有任何消息被处理。
--   连接完成后再调用 Dispatch.register 开始接收消息，
--   保证第一条消息(init/loadIdCounter等)到达时 db 已就绪。
----------------------------------------------------------------
skynet.start(function()
    local Cfg = require "Config.Config"
    local mc = Cfg.mongo or {}
    local host = mc.host or "127.0.0.1"
    local port = mc.port or 27017
    local dbname = mc.db or "game"
    local username = mc.username or ""
    local password = mc.password or ""
    local authdb   = mc.authdb or "admin"  -- BugFix BUG-40: 认证库默认admin，不再用业务库名

    -- 连接 MongoDB
    local conn_cfg = {
        host = host,
        port = port,
    }

    -- 如果配置了用户名密码，添加认证信息
    if username ~= "" and password ~= "" then
        conn_cfg.username = username
        conn_cfg.password = password
        conn_cfg.authdb = authdb  -- BugFix BUG-40: 使用独立的认证数据库配置
    end

    -- 连接并验证(带重试: MongoDB可能还没就绪，等它而不是直接崩)
    -- BugFix BUG-39: 添加重试机制，指数退避，最多尝试 MAX_RETRY 次
    local MAX_RETRY = 10
    local RETRY_BASE_SEC = 2   -- 首次重试等待2秒，之后翻倍，上限30秒
    local connected = false

    for attempt = 1, MAX_RETRY do
        local ok, err = pcall(function()
            -- 每次重试需要重新创建 client(旧的可能处于异常状态)
            if client then
                pcall(client.disconnect, client)
                client = nil
                db = nil
            end
            client = mongo.client(conn_cfg)
            db = client:getDB(dbname)
            -- 验证连接
            db:runCommand("ping")
        end)

        if ok then
            connected = true
            break
        end

        skynet.error(string.format(
            "[DB] MongoDB connection attempt %d/%d failed (%s:%d/%s): %s",
            attempt, MAX_RETRY, host, port, dbname, tostring(err)))

        if attempt < MAX_RETRY then
            local waitSec = math.min(RETRY_BASE_SEC * (2 ^ (attempt - 1)), 30)
            skynet.error(string.format("[DB] retrying in %d seconds...", waitSec))
            skynet.sleep(waitSec * 100)  -- skynet.sleep 单位是 centisecond
        end
    end

    if not connected then
        local msg = string.format(
            "[DB] FATAL: MongoDB connection failed after %d attempts (%s:%d/%s)",
            MAX_RETRY, host, port, dbname)
        skynet.error(msg)
        error(msg)
    end

    -- 创建索引(幂等)
    pcall(function()
        db.accounts:createIndex({{ uid = 1 }, unique = true })
    end)

    local auth_info = (username ~= "" and password ~= "")
        and string.format(" (auth: %s@%s)", username, authdb) or " (no auth)"
    skynet.error(string.format("[DB] connected to MongoDB %s:%d/%s%s",
        host, port, dbname, auth_info))

    -- MongoDB 就绪后，注册消息分发(此后才开始处理 init/loadIdCounter 等消息)
    Dispatch.register(handler)
end)