-- Logic/Player/Player.lua
-- 业务根对象(Context): 持有底层entry引用，作为所有模块的上下文
-- 不包含具体业务逻辑，模块实例由 ModuleManager.mount() 自动挂载到 self[modName]
--
-- 职责:
--   1. 封装对 entry 底层字段的访问(fd/gate/data等)
--   2. 提供通用工具方法(pushClient/kick/rebind)
--   3. 作为模块间相互访问的中介(player.bag / player.role)
--
-- 设计约束:
--   - Player 本身 不 注册为业务模块(scan时跳过 player/ 目录)
--   - Player 不持有业务状态，所有持久化数据存于 entry.data[modName]
--   - 模块间通信: player.bag:someMethod() (直接方法调用，同进程零开销)

local Cast  = require "Cast"

---@class Player
---@field entry    PlayerEntry  AgentService持有的原始数据条目(共享引用)
---@field uid      integer      冗余缓存，避免频繁 entry.uid
---@field fd       integer      当前连接fd
---@field gate     integer      当前gate地址
---@field [string] table        动态挂载的模块实例(player.bag, player.role, ...)
local Player = {}
Player.__index = Player

--- 构造Player上下文
--- 注意: 构造后需调用 ModuleManager.mount(player) 挂载模块
---@param entry PlayerEntry  AgentService中的玩家条目(共享引用，非拷贝)
---@return Player
function Player.new(entry)
    local self = setmetatable({}, Player)
    self.entry = entry
    self.uid   = entry.uid
    self.fd    = entry.fd
    self.gate  = entry.gate
    return self
end

--- Fix #11: 显式销毁，断开entry引用，使isOnline()返回false
--- AgentService 在 unmount 后调用
function Player:destroy()
    self.entry = nil
end

----------------------------------------------------------------
-- 连接管理
----------------------------------------------------------------

--- 更新连接信息(断线重连/顶号后)
---@param fd   integer  新的文件描述符
---@param gate integer  新的gate地址
function Player:rebind(fd, gate)
    self.fd   = fd
    self.gate = gate
    -- 同步回entry(AgentService持有的原始数据)
    self.entry.fd   = fd
    self.entry.gate = gate
end

----------------------------------------------------------------
-- 客户端通信
----------------------------------------------------------------

--- 向客户端推送消息(经由gate转发)
---@param msgId integer  协议号
---@param body  table    消息体
function Player:pushClient(msgId, body)
    Cast.send(self.gate, "push", {
        fd    = self.fd,
        msgId = msgId,
        body  = body,
    })
end

--- 踢下线(经由gate)
---@param reason integer  踢线原因码
function Player:kick(reason)
    Cast.send(self.gate, "kick", {
        fd     = self.fd,
        uid    = self.uid,   -- BugFix #B16: 携带uid供gate校验
        reason = reason or 0,
    })
end

----------------------------------------------------------------
-- 数据访问
----------------------------------------------------------------

--- 获取玩家持久化数据根表(直接引用)
---@return table
function Player:getData()
    return self.entry.data
end

--- 获取/初始化指定模块的数据段
--- 约定: entry.data[modName] 为该模块的持久化数据
--- 首次访问时自动创建空表
---@param modName string  模块名
---@return table  该模块的数据段(引用)
function Player:getModData(modName)
    local data = self.entry.data
    if not data[modName] then
        data[modName] = {}
    end
    return data[modName]
end

--- 检查玩家是否仍在线(entry未被移除)
---@return boolean
function Player:isOnline()
    return self.entry ~= nil and self.entry.loading == false
end

return Player