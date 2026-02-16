-- Logic/Player/Player.lua
-- 业务根对象(Context): 持有底层entry引用，作为所有模块的上下文
-- 不包含具体业务逻辑，模块实例由 ModuleManager.mount() 自动挂载到 self[modName]
--
-- 职责:
--   1. 封装对 entry 底层字段的访问(fd/gate/data等)
--   2. 提供通用工具方法(pushClient/kick)
--   3. 作为模块间相互访问的中介(player.Bag / player.Role)
--
-- 生命周期契约:
--   - Player 本身不注册为业务模块(scan时跳过 Player/ 目录)
--   - destroy() 后 entry=nil, isOnline()=false, getData()/getModData() 返回 nil
--   - 上层(AgentService)保证 destroy 后不再对 Player 发起业务调用
--   - 模块内的防御性 nil 检查仅作为安全网，不应被常规流程触发

local Cast  = require "Cast"

---@class Player
---@field entry    PlayerEntry  AgentService持有的原始数据条目(共享引用)
---@field uid      integer      冗余缓存
---@field fd       integer      当前连接fd
---@field gate     integer      当前gate地址
---@field [string] table        动态挂载的模块实例(player.Bag, player.Role, ...)
local Player = {}
Player.__index = Player

---@param entry PlayerEntry
---@return Player
function Player.new(entry)
    local self = setmetatable({}, Player)
    self.entry = entry
    self.uid   = entry.uid
    self.fd    = entry.fd
    self.gate  = entry.gate
    return self
end

--- 显式销毁，断开entry引用
function Player:destroy()
    self.entry = nil
end

----------------------------------------------------------------
-- 客户端通信
----------------------------------------------------------------

---@param msgId integer
---@param body  table
function Player:pushClient(msgId, body)
    Cast.send(self.gate, "push", {
        fd    = self.fd,
        msgId = msgId,
        body  = body,
    })
end

---@param reason integer  踢线原因码
function Player:kick(reason)
    Cast.send(self.gate, "kick", {
        fd     = self.fd,
        uid    = self.uid,
        reason = reason or 0,
    })
end

----------------------------------------------------------------
-- 数据访问
----------------------------------------------------------------

--- 获取玩家持久化数据根表(直接引用)
---@return table|nil
function Player:getData()
    if not self.entry then return nil end
    return self.entry.data
end

--- 获取/初始化指定模块的数据段
--- 约定: entry.data[modName] 为该模块的持久化数据，首次访问时自动创建空表
---@param modName string
---@return table|nil
function Player:getModData(modName)
    if not self.entry then return nil end
    local data = self.entry.data
    if not data[modName] then
        data[modName] = {}
    end
    return data[modName]
end

---@return boolean
function Player:isOnline()
    return self.entry ~= nil and self.entry.loading == false
end

return Player