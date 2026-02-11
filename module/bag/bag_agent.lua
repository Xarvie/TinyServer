--------------------------------------------------------------
-- bag_agent.lua — 模块 002 背包业务层
--
-- 协议:
--   1002001 C2S_GetBagInfo  → 5002001
--   1002002 C2S_UseItem     → 5002002
--   1002003 C2S_SellItem    → 5002003
--   1002004 C2S_AddTestItem → 5002004 (测试用)
--------------------------------------------------------------
local log = require "log"
local M = {}
M._MODULE_ID = 2

M.C2S = {
    [1002001] = "C2S_GetBagInfo",
    [1002002] = "C2S_UseItem",
    [1002003] = "C2S_SellItem",
    [1002004] = "C2S_AddTestItem",
}

M.S2C = {
    [5002001] = "S2C_BagInfo",
    [5002002] = "S2C_UseItemResult",
    [5002003] = "S2C_SellItemResult",
    [5002004] = "S2C_AddTestItemResult",
}

function M.OnInit(player)
    if not player.BagData then
        player.BagData = require("bag_db").GetDefaultData()
        player.BagDirty = true
    end
end

function M.C2S_GetBagInfo(player, req)
    return {
        code = 0,
        data = {
            items      = player.BagData.items,
            max_slots  = player.BagData.max_slots,
            used_slots = #player.BagData.items,
        },
    }
end

function M.C2S_UseItem(player, req)
    local item_id = req and req.item_id
    local count   = req and req.count or 1
    if not item_id then
        return { code = 1, msg = "missing item_id" }
    end

    if not HasItem(player, item_id, count) then
        return { code = 2, msg = "insufficient items" }
    end

    -- 使用物品逻辑 (简化: 直接消耗)
    local ok, msg = RemoveItem(player, item_id, count)
    if not ok then
        return { code = 3, msg = msg }
    end

    log.info("[Bag] use item uid:", player.uid, "item:", item_id, "x", count)
    return { code = 0, item_id = item_id, count = count }
end

function M.C2S_SellItem(player, req)
    local item_id = req and req.item_id
    local count   = req and req.count or 1
    if not item_id then
        return { code = 1, msg = "missing item_id" }
    end

    if not HasItem(player, item_id, count) then
        return { code = 2, msg = "insufficient items" }
    end

    local ok, msg = RemoveItem(player, item_id, count)
    if not ok then
        return { code = 3, msg = msg }
    end

    -- 简化: 每个物品卖 10 金币
    local gold = count * 10
    log.info("[Bag] sell uid:", player.uid, "item:", item_id, "x", count, "gold:", gold)
    return { code = 0, item_id = item_id, count = count, gold = gold }
end

--- 测试用: 给自己添加物品
function M.C2S_AddTestItem(player, req)
    local item_id = req and req.item_id or 1001
    local count   = req and req.count   or 1

    local slots = #(player.BagData.items or {})
    if slots >= player.BagData.max_slots then
        return { code = 1, msg = "bag full" }
    end

    local ok, msg = AddItem(player, item_id, count)
    if not ok then
        return { code = 2, msg = msg }
    end

    return { code = 0, item_id = item_id, count = count }
end

return M
