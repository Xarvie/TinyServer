-- lualib/Session.lua
-- 会话管理: fd <-> uid <-> agent 映射
-- 纯内存table，无锁，单服务内使用
--
-- Fix #1:  remove() 校验 byUid 归属，防止同gate顶号时删错新连接映射
-- Fix #5:  引入单调递增 sessionId，防止fd复用导致authResult错误绑定
-- Fix #8:  用计数器替代遍历 count()
-- BugFix #B7: 统一使用 skynet.now() 原始值(centisecond)，避免除法产生的浮点精度问题
-- BugFix #B19: auth() 返回被同uid顶替的旧entry，供调用方主动踢线

local skynet = require "skynet"

---@class SessionEntry
---@field fd integer
---@field sessionId integer  单调递增会话标识，解决fd复用问题
---@field uid integer|nil
---@field agent integer|nil
---@field gate integer
---@field lastActive integer  最后活跃时间(centisecond, skynet.now()原始值)

---@class SessionMgr
local SessionMgr = {}
SessionMgr.__index = SessionMgr

function SessionMgr.new()
    local self = setmetatable({}, SessionMgr)
    self.byFd    = {}  ---@type table<integer, SessionEntry>
    self.byUid   = {}  ---@type table<string, SessionEntry>
    self._count  = 0   -- Fix #8: O(1) 计数
    self._nextId = 0   -- Fix #5: sessionId 生成器
    return self
end

---@param fd integer
---@param gate integer
---@return SessionEntry
function SessionMgr:bind(fd, gate)
    -- 如果旧fd还在(不应该，防御性)，先清理
    if self.byFd[fd] then
        self:remove(fd)
    end
    self._nextId = self._nextId + 1
    local entry = {
        fd         = fd,
        sessionId  = self._nextId,  -- Fix #5
        uid        = nil,
        agent      = nil,
        gate       = gate,
        lastActive = skynet.now(),  -- BugFix #B7: 直接存centisecond
    }
    self.byFd[fd] = entry
    self._count = self._count + 1
    return entry
end

--- BugFix #B19: 返回被顶号的旧entry(含fd)，供调用方主动踢线
---              在清除旧entry字段之前，调用方可用返回值处理旧连接
---@param fd integer
---@param uid integer
---@param agent integer
---@return SessionEntry|nil oldEntry  被同uid顶替的旧session(不同fd)，nil表示无碰撞
function SessionMgr:auth(fd, uid, agent)
    local entry = self.byFd[fd]
    if not entry then return nil end

    -- BugFix BUG-8: 同fd以不同uid重新认证时，清理旧uid的byUid映射
    -- 防止 byUid[oldUid] 变成悬挂引用
    if entry.uid and entry.uid ~= uid then
        if self.byUid[entry.uid] == entry then
            self.byUid[entry.uid] = nil
        end
    end

    -- 如果另一个fd已绑定同uid(同gate顶号)，先解除旧映射
    local oldEntry = self.byUid[uid]
    local displaced = nil
    if oldEntry and oldEntry ~= entry then
        displaced = {
            fd    = oldEntry.fd,
            uid   = oldEntry.uid,
            agent = oldEntry.agent,
            gate  = oldEntry.gate,  -- BugFix BUG-19: 补充gate字段，支持跨gate场景
        }
        oldEntry.uid   = nil
        oldEntry.agent = nil
    end
    entry.uid    = uid
    entry.agent  = agent
    self.byUid[uid] = entry
    return displaced
end

---@param fd integer
function SessionMgr:touch(fd)
    local entry = self.byFd[fd]
    if entry then
        entry.lastActive = skynet.now()  -- BugFix #B7
    end
end

---@param fd integer
---@return SessionEntry|nil
function SessionMgr:getByFd(fd)
    return self.byFd[fd]
end

--- 通过fd和sessionId联合获取，防止fd复用后取到新session
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

--- Fix #1: 删除前校验byUid归属，防止同gate顶号时误删新连接映射
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

--- Fix #8: O(1) 计数
---@return integer
function SessionMgr:count()
    return self._count
end

--- 收集超时的fd列表
--- BugFix #B7: 使用centisecond单位比较，timeoutSec参数仍为秒
---@param timeoutSec number  超时阈值(秒)
---@return integer[]  超时的fd列表
function SessionMgr:collectTimeout(timeoutSec)
    local now = skynet.now()
    local timeoutCs = timeoutSec * 100  -- BugFix #B7: 转为centisecond
    local result = {}
    for fd, entry in pairs(self.byFd) do
        if now - entry.lastActive > timeoutCs then
            result[#result + 1] = fd
        end
    end
    return result
end

return SessionMgr