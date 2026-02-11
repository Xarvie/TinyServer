local M = {}
M._MODULE_ID    = 1
M._DATA_VERSION = 2

function M.GetDefaultData()
    return {
        nickname     = "",
        level        = 1,
        exp          = 0,
        vip          = 0,
        avatar       = 1,
        create_time  = os.time(),
        last_login   = os.time(),
        login_count  = 0,
        total_online = 0,
    }
end

function M.MigrateData(old, ver)
    if ver < 2 then
        old.total_online = old.total_online or 0
        old.login_count  = old.login_count  or 0
    end
    return old
end

return M
