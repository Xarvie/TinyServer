--------------------------------------------------------------
-- pvp_db.lua — 模块 003 PVP 数据层
--------------------------------------------------------------
local M = {}
M._MODULE_ID    = 3
M._DATA_VERSION = 1

function M.GetDefaultData()
    return {
        total_matches  = 0,
        win_count      = 0,
        lose_count     = 0,
        rating         = 1000,
        in_match       = false,
        match_id       = nil,
        last_match_time = 0,
    }
end

function M.MigrateData(old, ver)
    if ver < 1 then
        old.rating          = old.rating          or 1000
        old.in_match        = old.in_match        or false
        old.last_match_time = old.last_match_time  or 0
    end
    return old
end

return M