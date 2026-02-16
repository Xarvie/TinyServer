-- lualib/Session.lua
-- 会话管理: fd <-> uid <-> agent 映射
-- 纯内存table，无锁，单服务内使用
--
-- 设计要点:
--   - 单调递增 sessionId 解决 fd 复用问题(fd被OS回收再分配后不会匹配旧session)
--   - auth() 返回被同uid顶替的旧entry，供调用方主动踢线
--   - remove() 校验 byUid 归属，防止同gate顶号时删错新连接映射
--   - 时间统一使用 skynet.now() 原始值(centisecond)，避免浮点精度问题

local skynet = require "skynet"

---@class SessionEntry
---@field fd            integer
---@field sessionId     integer  单调递增会话标识
---@field uid           integer|nil
---@field agent         integer|nil
---@field gate          integer
---@field lastActive    integer  最后活跃时间(centisecond)
---@field authFailCount integer  认证失败计数
---@field pendingAuth   boolean  是否有待处理的认证请求

---@class SessionMgr
local SessionMgr = {}
SessionMgr.__index = SessionMgr

function SessionMgr.new()
    local self = setmetatable({}, SessionMgr)
    self.byFd    = {}  ---@type table<integer, SessionEntry>
    self.byUid   = {}  ---@type table<integer, SessionEntry>
    self._count  = 0
    self._nextId = 0
    return self
end

---@param fd integer
---@param gate integer
---@return SessionEntry
function SessionMgr:bind(fd, gate)
    if self.byFd[fd] then
        self:remove(fd)
    end
    self._nextId = self._nextId + 1
    local entry = {
        fd            = fd,
        sessionId     = self._nextId,
        uid           = nil,
        agent         = nil,
        gate          = gate,
        lastActive    = skynet.now(),
        authFailCount = 0,
        pendingAuth   = false,
    }
    self.byFd[fd] = entry
    self._count = self._count + 1
    return entry
end

--- 绑定认证信息，返回被同uid顶替的旧entry(含fd)供调用方踢线
---@param fd integer
---@param uid integer
---@param agent integer
---@return SessionEntry|nil displaced  被顶替的旧session，nil表示无碰撞
function SessionMgr:auth(fd, uid, agent)
    local entry = self.byFd[fd]
    if not entry then return nil end

    -- 同fd以不同uid重新认证时，清理旧uid的byUid映射
    if entry.uid and entry.uid ~= uid then
        if self.byUid[entry.uid] == entry then
            self.byUid[entry.uid] = nil
        end
    end

    -- 另一个fd已绑定同uid(同gate顶号)，解除旧映射
    local oldEntry = self.byUid[uid]
    local displaced = nil
    if oldEntry and oldEntry ~= entry then
        displaced = {
            fd    = oldEntry.fd,
            uid   = oldEntry.uid,
            agent = oldEntry.agent,
            gate  = oldEntry.gate,
        }
        oldEntry.uid   = nil
        oldEntry.agent = nil
    end

    entry.uid   = uid
    entry.agent = agent
    self.byUid[uid] = entry
    return displaced
end

---@param fd integer
function SessionMgr:touch(fd)
    local entry = self.byFd[fd]
    if entry then
        entry.lastActive = skynet.now()
    end
end

---@param fd integer
---@return SessionEntry|nil
function SessionMgr:getByFd(fd)
    return self.byFd[fd]
end

--- 通过fd+sessionId联合获取，防止fd复用后取到新session
---@param fd integer
---@param sessionId integer
---@return SessionEntry|nil
function SessionMgr:getByFdAndSession(fd, sessionId)
    local entry = self.byFd[fd]
    if entry and entry.sessionId == sessionId then
        return entry
    end
    return nil
end

---@param uid integer
---@return SessionEntry|nil
function SessionMgr:getByUid(uid)
    return self.byUid[uid]
end

--- 删除前校验byUid归属，防止同gate顶号时误删新连接映射
---@param fd integer
---@return SessionEntry|nil
function SessionMgr:remove(fd)
    local entry = self.byFd[fd]
    if not entry then return nil end
    self.byFd[fd] = nil
    self._count = self._count - 1
    if entry.uid and self.byUid[entry.uid] == entry then
        self.byUid[entry.uid] = nil
    end
    return entry
end

---@return integer
function SessionMgr:count()
    return self._count
end

--- 收集超时的fd列表
---@param timeoutSec number  超时阈值(秒)
---@return integer[]
function SessionMgr:collectTimeout(timeoutSec)
    local now = skynet.now()
    local timeoutCs = timeoutSec * 100
    local result = {}
    for fd, entry in pairs(self.byFd) do
        if now - entry.lastActive > timeoutCs then
            result[#result + 1] = fd
        end
    end
    return result
end

return SessionMgr