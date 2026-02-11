--------------------------------------------------------------
-- rank_db.lua — 模块 006 排行榜数据层
--------------------------------------------------------------
local M = {}
M._MODULE_ID    = 6
M._DATA_VERSION = 1

function M.GetDefaultData()
    return {
        best_score    = 0,
        last_rank     = 0,
        submit_count  = 0,
    }
end

function M.MigrateData(old, ver)
    if ver < 1 then
        old.best_score   = old.best_score   or 0
        old.last_rank    = old.last_rank    or 0
        old.submit_count = old.submit_count or 0
    end
    return old
end

return M