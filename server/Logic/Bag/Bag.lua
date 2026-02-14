-- Logic/Bag/Bag.lua
-- 背包模块(示例业务模块)
-- 演示完整的模块接入规范: 自声明 · 依赖 · 路由 · 生命周期
--
-- 目录结构: logic/bag/Bag.lua
-- 自动发现: ModuleManager.scan 检测到 bag/ 目录下的 Bag.lua(同名匹配)
--
-- 持久化数据结构 (entry.data.bag):
--   items: table<string, BagItem>  物品表(itemId -> item)
--   cap:   integer                 背包容量
--
-- BugFix BUG-4: cap 为 number 类型，赋值是拷贝非引用，不能像 items(table)那样
--   通过 self.cap = data.cap 建立引用。改为持有 self.data 引用，统一通过
--   self.data.cap 读写，消除双源不一致风险。
--
-- 扩展指引:
--   新增协议: 在 handlers 表中添加 [MsgId.XXX] = "methodName"
--   新增依赖: 在 deps 表中添加模块名
--   新增钩子: 实现 onXxx(self, ...) 方法即可

local skynet = require "skynet"
local MsgId  = require "Proto.MsgId"

----------------------------------------------------------------
-- 模块元数据(ModuleManager 自动发现时读取)
----------------------------------------------------------------

---@class Bag
---@field player   Player       业务上下文
---@field data     table        持久化数据段引用(player:getModData("bag"))
---@field items    table        物品数据(引用 data.items，便捷别名)
---  BugFix BUG-4: 移除 self.cap 字段，cap 统一通过 self.data.cap 读写
---                number 赋值是拷贝而非引用，保留独立字段会产生双源不一致风险
local Bag = {}
Bag.__index = Bag

--- 模块名(必须，与目录名一致，全局唯一)
Bag.modName = "Bag"

--- 依赖声明(可选)
--- 本模块依赖的其他模块名，ModuleManager 保证依赖模块先于本模块初始化
--- 示例: 背包可能依赖 role 模块获取等级信息来计算容量上限
--- 无依赖时设为空表或省略
Bag.deps = {}

--- 客户端消息路由(可选)
--- key:   MsgId(协议号)
--- value: 方法名字符串(必须是 Bag 上的方法)
--- ModuleManager.init() 时自动聚合到全局路由表，检测冲突
Bag.handlers = {
    -- 实际项目中在此注册协议，示例:
    [MsgId.C2S_UseItem]    = "useItem",
    -- [MsgId.C2S_SellItem]   = "sellItem",
    -- [MsgId.C2S_SortBag]    = "sortBag",
}

----------------------------------------------------------------
-- 常量
----------------------------------------------------------------
local DEFAULT_CAP = 100   -- 默认背包容量
local MAX_CAP     = 500   -- 最大背包容量
local MAX_STACK   = 9999  -- 单格最大堆叠

----------------------------------------------------------------
-- 构造 / 销毁
----------------------------------------------------------------

--- 构造函数(必须)
--- ModuleManager.mount(player) 时按拓扑序调用
---@param player Player  业务根对象
---@return Bag
function Bag.new(player)
    local self = setmetatable({
        player = player,
    }, Bag)
    -- 获取该模块专属的持久化数据引用
    self.data = player:getModData("bag") 
    -- 如果数据段是空的，初始化默认值
    if not self.data.items then
        self.data.items = {} 
    end
    -- BugFix BUG-4: 初始化cap默认值，防止onDbInit前访问cap为nil
    if not self.data.cap then
        self.data.cap = DEFAULT_CAP
    end
    -- BugFix BUG-3: 初始化self.items别名，防止onDbInit前访问为nil
    self.items = self.data.items
    return self
end

----------------------------------------------------------------
-- 生命周期钩子(可选，按需实现)
-- ModuleManager.trigger(event, player) 按拓扑序调用
----------------------------------------------------------------

--- 数据库数据加载完毕，从持久化数据恢复内存状态
--- 此时所有依赖模块的 onDbInit 已完成(拓扑序保证)
function Bag:onDbInit()
    local data = self.player:getModData("bag")

    -- 初始化默认结构(新玩家 / 数据迁移)
    if not data.items then
        data.items = {}
    end
    if not data.cap then
        data.cap = DEFAULT_CAP
    end

    -- BugFix BUG-4: 持有 data 表引用，cap 通过 self.data.cap 读写(单源)
    --               items 是 table 引用天然同步，保留便捷别名
    self.data  = data
    self.items = data.items
end

--- 所有模块 onDbInit 完成后调用，玩家正式上线
--- 适合推送初始化数据给客户端
function Bag:onPlayerLogin()
    -- 示例: 推送背包快照给客户端
    -- self.player:pushClient(MsgId.S2C_BagSnapshot, {
    --     items = self:serializeItems(),
    --     cap   = self.data.cap,
    -- })
end

--- 在线时跨天触发(由外部定时器或登录时触发)
function Bag:onNewDay()
    -- 示例: 清理过期物品
    -- self:removeExpired()
end

--- 玩家登出/离线前(存盘前调用，逆拓扑序)
--- 可做最终数据修正、日志记录等
function Bag:onLogout()
    -- BugFix BUG-4: cap 已通过 self.data.cap 单源读写，无需手动回写
    -- 持久化数据均通过 self.data 引用直接修改，无额外同步需求
end

--- 服务关闭前(逆拓扑序)
function Bag:onShutdown()
    -- 同 onLogout，确保数据一致
    self:onLogout()
end

----------------------------------------------------------------
-- 业务逻辑(示例)
----------------------------------------------------------------

---@class BagItem
---@field itemId   string   物品唯一ID(配置表ID)
---@field count    integer  数量
---@field expireTs integer  过期时间戳(0=永不过期)

--- 添加物品
--- 示例API: 供其他模块调用(如: player.bag:addItem("item_001", 10))
---@param itemId string  物品ID
---@param count  integer 数量(>0)
---@return boolean ok
---@return string  reason  失败原因
function Bag:addItem(itemId, count)
    if count <= 0 then
        return false, "invalid_count"
    end

    local item = self.items[itemId]
    if item then
        -- 堆叠
        local newCount = item.count + count
        if newCount > MAX_STACK then
            return false, "stack_overflow"
        end
        item.count = newCount
    else
        -- 新物品: 检查容量
        local used = self:getUsedSlots()
        if used >= self.data.cap then
            return false, "bag_full"
        end
        self.items[itemId] = {
            itemId   = itemId,
            count    = count,
            expireTs = 0,
        }
    end

    -- 通知客户端(示例)
    -- self.player:pushClient(MsgId.S2C_BagUpdate, {
    --     itemId = itemId,
    --     count  = self.items[itemId].count,
    -- })

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

--- 查询物品数量
---@param itemId string
---@return integer
function Bag:getItemCount(itemId)
    local item = self.items[itemId]
    return item and item.count or 0
end

--- 已占用格数
---@return integer
function Bag:getUsedSlots()
    local n = 0
    for _ in pairs(self.items) do
        n = n + 1
    end
    return n
end

--- 扩展背包容量
---@param delta integer  增加的格数
---@return boolean ok
function Bag:expandCap(delta)
    if delta <= 0 then return false end
    local newCap = self.data.cap + delta
    if newCap > MAX_CAP then
        newCap = MAX_CAP
    end
    -- BugFix BUG-4: 直接写 self.data.cap，单源，无需额外回写
    self.data.cap = newCap
    return true
end

----------------------------------------------------------------
-- 客户端消息处理(示例，取消注释 handlers 中的注册后生效)
----------------------------------------------------------------

--- 使用物品
--- BugFix BUG-1: items[itemId] 是 table{itemId,count,expireTs}，不是 number
---               原代码将 table 当 number 比较/运算，必 crash
---               改为操作 item.count，并复用 removeItem 保证逻辑一致
---@param body table  { itemId: string, count: integer }
function Bag:useItem(body)
    local itemId = body.itemId
    local useCount = body.count or 1

    local ok, reason = self:removeItem(itemId, useCount)
    if ok then
        -- TODO: 执行使用效果(加属性、触发buff等)

        -- 推送更新给客户端
        self.player:pushClient(MsgId.S2C_BagUpdate, {
            itemId = itemId,
            count  = self:getItemCount(itemId),
        })
    else
        -- 错误处理: 数量不足 / 物品不存在
        skynet.error(string.format("[Bag] useItem failed: uid=%d itemId=%s reason=%s",
            self.player.uid, tostring(itemId), reason))
    end
end

return Bag