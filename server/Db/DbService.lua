-- Db/DbService.lua
-- DB服务: 认证、加载、存盘，单进程串行安全
-- 全cast，零call
-- 实际项目替换为redis/mysql异步驱动
--
-- BugFix #B10: uidCounter 基于已有数据恢复，防止重启后uid碰撞
-- Fix #10: uid 从 string("U%08d") 改为 int32，减少序列化/哈希/比较开销

local skynet   = require "skynet"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local MsgId    = require "Proto.MsgId"

local agents      = {}  ---@type integer[]
local gates       = {}  ---@type integer[]
local coordinator = 0   ---@type integer  关闭协调者(main服务)

----------------------------------------------------------------
-- 模拟存储(实际替换为持久化)
----------------------------------------------------------------
---@class DbRecord
---@field password string
---@field uid integer
---@field data table

---@type table<string, DbRecord>    account -> record
local storage = {}

---@type table<integer, DbRecord>   uid -> record (反向索引)
local byUid = {}

local uidCounter = 0   ---@type integer  int32 自增, 范围 [1, 0x7FFFFFFF]
local MAX_UID    = 0x7FFFFFFF  -- int32上限

--- BugFix #B10: 从已有数据中恢复uidCounter，防止重启后生成重复uid
--- 实际项目应从持久化存储(redis INCR / mysql AUTO_INCREMENT)获取
--- NOTE: 当前为内存模拟存储，重启后 byUid 为空，此函数不会生效(no-op)
---        替换为真实持久化后需重新验证此逻辑
local function recoverUidCounter()
    local maxId = 0
    for uid, _ in pairs(byUid) do
        if type(uid) == "number" and uid > maxId then
            maxId = uid
        end
    end
    if maxId > uidCounter then
        uidCounter = maxId
        skynet.error(string.format("[DB] recovered uidCounter to %d", uidCounter))
    end
end

---@return integer
local function genUid()
    uidCounter = uidCounter + 1
    assert(uidCounter <= MAX_UID, "[DB] FATAL: uid overflow int32 range")
    return uidCounter
end

----------------------------------------------------------------
-- 命令处理
----------------------------------------------------------------
local handler = {}

--- 初始化
---@param source integer
---@param cfg table
function handler.init(source, cfg)
    agents      = cfg.agents
    gates       = cfg.gates
    coordinator = cfg.coordinator or source

    -- BugFix #B10: 初始化时恢复计数器
    recoverUidCounter()

    skynet.error("[DB] initialized")
end

--- 登录验证(gate cast过来)
--- Fix #5: 透传 sessionId，供gate校验fd未被复用
---@param source integer
---@param req table  { account, password, fd, sessionId, gate }
function handler.login(source, req)
    local record = storage[req.account]
    if not record then
        Cast.send(req.gate, "authResult", {
            fd        = req.fd,
            sessionId = req.sessionId,  -- Fix #5
            code      = 1,  -- 账号不存在
            uid       = nil,
            msgId     = MsgId.S2C_LoginResult,
        })
        return
    end

    if record.password ~= req.password then
        Cast.send(req.gate, "authResult", {
            fd        = req.fd,
            sessionId = req.sessionId,  -- Fix #5
            code      = 2,  -- 密码错误
            uid       = nil,
            msgId     = MsgId.S2C_LoginResult,
        })
        return
    end

    Cast.send(req.gate, "authResult", {
        fd        = req.fd,
        sessionId = req.sessionId,  -- Fix #5
        code      = 0,
        uid       = record.uid,
        msgId     = MsgId.S2C_LoginResult,
    })
    skynet.error(string.format("[DB] login ok: %s -> %d", req.account, record.uid))
end

--- 注册(gate cast过来)
--- Fix #5: 透传 sessionId
---@param source integer
---@param req table  { account, password, fd, sessionId, gate }
function handler.register(source, req)
    if storage[req.account] then
        Cast.send(req.gate, "authResult", {
            fd        = req.fd,
            sessionId = req.sessionId,  -- Fix #5
            code      = 3,  -- 账号已存在
            uid       = nil,
            msgId     = MsgId.S2C_RegisterResult,
        })
        return
    end

    local uid = genUid()
    local record = {
        password = req.password,
        uid      = uid,
        data     = {},
    }
    storage[req.account] = record
    byUid[uid] = record  -- 反向索引

    Cast.send(req.gate, "authResult", {
        fd        = req.fd,
        sessionId = req.sessionId,  -- Fix #5
        code      = 0,
        uid       = uid,
        msgId     = MsgId.S2C_RegisterResult,
    })
    skynet.error(string.format("[DB] register ok: %s -> %d", req.account, uid))
end

--- 加载玩家数据(agent cast过来) -- O(1)
--- Fix #9: 透传 loadSeq，供agent校验顶号后的竞态
---@param source integer
---@param req table  { uid, agent, loadSeq }
function handler.load(source, req)
    local record = byUid[req.uid]
    Cast.send(req.agent, "loadResult", {
        uid     = req.uid,
        data    = record and record.data or {},
        loadSeq = req.loadSeq,  -- Fix #9
    })
end

--- 存盘(agent cast过来，fire-and-forget) -- O(1)
---@param source integer
---@param req table  { uid, data }
function handler.save(source, req)
    local record = byUid[req.uid]
    if record then
        record.data = req.data
    end
end

--- 优雅关闭
---@param source integer
function handler.shutdown(source)
    skynet.error("[DB] flushing all data...")
    -- 实际项目: flush所有pending writes
    skynet.error("[DB] shutdown complete")
    Cast.send(coordinator, "shutdownAck")
end

----------------------------------------------------------------
Dispatch.new(handler)