--------------------------------------------------------------
-- bag_db.lua — 模块 002 背包数据层
--------------------------------------------------------------
local M = {}
M._MODULE_ID    = 2
M._DATA_VERSION = 2

function M.GetDefaultData()
    return {
        items       = {},      -- { {id=1001, count=5}, ... }
        max_slots   = 100,
        expand_count = 0,
    }
end

function M.MigrateData(old, ver)
    if ver < 2 then
        old.max_slots    = old.max_slots    or 100
        old.expand_count = old.expand_count or 0
    end
    return old
end

return M
