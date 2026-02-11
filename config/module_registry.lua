local M = {}

M.registered = {
    [1]   = { name = "login",      desc = "登录系统" },
    [2]   = { name = "bag",        desc = "背包系统" },
    [3]   = { name = "pvp",        desc = "PVP系统" },
    [6]   = { name = "rank",       desc = "排行榜系统" },
    [99]  = { name = "echo",       desc = "回显测试" },
    [103] = { name = "pvp_cross",  desc = "PVP跨服匹配" },
    [206] = { name = "rank_inter", desc = "排行榜协调" },
}

M.ranges = {
    { min = 1,   max = 99,  desc = "基础系统模块" },
    { min = 100, max = 199, desc = "跨服系统模块 (Cross)" },
    { min = 200, max = 299, desc = "Inter 协调模块" },
    { min = 300, max = 999, desc = "业务玩法模块" },
}

function M.is_occupied(id)
    return M.registered[id] ~= nil
end

function M.next_available(range_min, range_max)
    for id = range_min, range_max do
        if not M.registered[id] then return id end
    end
    return nil
end

return M