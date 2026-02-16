-- Logic/Bag/Bag.lua
-- 背包模块(示例业务模块)
-- 演示完整的模块接入规范: 自声明 · 依赖 · 路由 · 生命周期
--
-- 持久化数据结构 (entry.data.Bag):
--   items: table<string, BagItem>  物品表(itemId -> item)
--   cap:   integer                 背包容量
--
-- 注意: cap 为 number 类型(赋值是拷贝非引用)，统一通过 self.data.cap 读写，
--       不设独立 self.cap 字段，避免双源不一致。

local skynet = require "skynet"
local MsgId  = require "Proto.MsgId"
local Cast   = require "Cast"

----------------------------------------------------------------
-- 模块元数据
----------------------------------------------------------------

---@class Bag
---@field player   Player
---@field data     table   持久化数据段引用
---@field items    table   物品数据(引用 data.items，便捷别名)
local Bag = {}
Bag.__index = Bag

Bag.modName = "Bag"
Bag.deps = {}

--- 客户端消息路由: msgId -> 方法名
Bag.handlers = {
    [MsgId.C2S_UseItem] = "useItem",
}

----------------------------------------------------------------
-- 常量
----------------------------------------------------------------
local DEFAULT_CAP = 100
local MAX_CAP     = 500
local MAX_STACK   = 9999

----------------------------------------------------------------
-- 构造 / 销毁
----------------------------------------------------------------

--- 构造函数: 只保存player引用，不访问数据(数据在onDbInit中初始化)
---@param player Player
---@return Bag
function Bag.new(player)
    return setmetatable({
        player = player,
        data   = nil,
        items  = nil,
    }, Bag)
end

----------------------------------------------------------------
-- 生命周期钩子
----------------------------------------------------------------

function Bag:onDbInit()
    local data = self.player:getModData(self.modName)
    if not data then
        skynet.error(string.format("[Bag] onDbInit: getModData returned nil for uid=%s, skip",
            tostring(self.player.uid)))
        return
    end

    if not data.items then data.items = {} end
    if not data.cap   then data.cap = DEFAULT_CAP end

    self.data  = data
    self.items = data.items
end

function Bag:onPlayerLogin()
    -- 示例: 推送背包快照给客户端
end

function Bag:onNewDay()
    -- 示例: 清理过期物品
end

function Bag:onLogout()
    -- 数据通过 self.data 引用直接修改，无额外同步需求
end

function Bag:onShutdown()
    self:onLogout()
end

----------------------------------------------------------------
-- 业务逻辑
----------------------------------------------------------------

---@class BagItem
---@field itemId   string
---@field count    integer
---@field expireTs integer  0=永不过期

--- 添加物品
---@param itemId string
---@param count  integer  >0
---@return boolean ok
---@return string  reason
function Bag:addItem(itemId, count)
    if count <= 0 then
        return false, "invalid_count"
    end

    local item = self.items[itemId]
    if item then
        local newCount = item.count + count
        if newCount > MAX_STACK then
            return false, "stack_overflow"
        end
        item.count = newCount
    else
        if self:getUsedSlots() >= self.data.cap then
            return false, "bag_full"
        end
        self.items[itemId] = {
            itemId   = itemId,
            count    = count,
            expireTs = 0,
        }
    end
    return true, ""
end

--- 移除物品
---@param itemId string
---@param count  integer
---@return boolean ok
---@return string  reason
function Bag:removeItem(itemId, count)
    if count <= 0 then
        return false, "invalid_count"
    end
    local item = self.items[itemId]
    if not item then
        return false, "item_not_found"
    end
    if item.count < count then
        return false, "insufficient"
    end
    item.count = item.count - count
    if item.count <= 0 then
        self.items[itemId] = nil
    end
    return true, ""
end

---@param itemId string
---@return integer
function Bag:getItemCount(itemId)
    local item = self.items[itemId]
    return item and item.count or 0
end

---@return integer
function Bag:getUsedSlots()
    return Cast.tableSize(self.items)
end

---@param delta integer  增加的格数
---@return boolean ok
function Bag:expandCap(delta)
    if delta <= 0 then return false end
    local newCap = self.data.cap + delta
    if newCap > MAX_CAP then
        newCap = MAX_CAP
    end
    self.data.cap = newCap
    return true
end

----------------------------------------------------------------
-- 客户端消息处理
----------------------------------------------------------------

--- 使用物品
---@param body table  { itemId: string, count: integer }
function Bag:useItem(body)
    local itemId = body.itemId
    local useCount = body.count or 1

    if not itemId or type(itemId) ~= "string" or #itemId == 0 then
        skynet.error(string.format("[Bag] useItem rejected: uid=%d invalid itemId",
            self.player.uid))
        return false
    end

    if type(useCount) ~= "number" or useCount <= 0 then
        skynet.error(string.format("[Bag] useItem rejected: uid=%d invalid count=%s",
            self.player.uid, tostring(useCount)))
        return false
    end

    local ok, reason = self:removeItem(itemId, useCount)
    if not ok then
        skynet.error(string.format("[Bag] useItem failed: uid=%d itemId=%s reason=%s",
            self.player.uid, tostring(itemId), reason))
        return false  -- 返回false: 未修改数据，不标记dirty
    end

    -- TODO: 执行使用效果(加属性、触发buff等)

    self.player:pushClient(MsgId.S2C_BagUpdate, {
        itemId = itemId,
        count  = self:getItemCount(itemId),
    })
end

return Bag