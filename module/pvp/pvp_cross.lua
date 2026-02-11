--------------------------------------------------------------
-- pvp_cross.lua — 模块 103 PVP 跨服匹配系统
--
-- 由 CrossManager 启动，通过 Gate 与 Agent 通信
-- 维护匹配池，执行匹配演算，广播结果
--------------------------------------------------------------
local M = {}
M._MODULE_ID = 103

-- 匹配池: { {uid, rating, ticket, join_time}, ... }
local match_pool = {}
-- uid -> index (快速查找)
local uid_lookup = {}

local match_counter = 0

local function generate_match_id()
    match_counter = match_counter + 1
    return string.format("PVP_%d_%d", os.time(), match_counter)
end

local function remove_from_pool(uid)
    local idx = uid_lookup[uid]
    if not idx then return end
    table.remove(match_pool, idx)
    uid_lookup[uid] = nil
    -- 重建索引
    for i, entry in ipairs(match_pool) do
        uid_lookup[entry.uid] = i
    end
end

--- 玩家加入匹配 (Gate 授权后转发)
function M.PvpOnMatchJoin(uid, data)
    if not data then return end
    local ticket = data.ticket

    -- 验证凭证
    local ticket_mod = require "ticket"
    local ok, err = ticket_mod.verify(uid, ticket)
    if not ok then
        LogError("[PvpCross] ticket verify fail uid:", uid, err)
        RouteToAgent(uid, "OnMatchFailed", { code = 2, msg = "ticket invalid: " .. (err or "") })
        return
    end

    -- 防重复加入
    if uid_lookup[uid] then
        LogInfo("[PvpCross] already in pool uid:", uid)
        return
    end

    match_pool[#match_pool+1] = {
        uid       = uid,
        rating    = data.rating or 1000,
        ticket    = ticket,
        join_time = os.time(),
    }
    uid_lookup[uid] = #match_pool

    LogInfo("[PvpCross] join pool uid:", uid, "pool_size:", #match_pool)

    -- 尝试匹配
    try_match()
end

--- 玩家离开匹配
function M.PvpOnMatchLeave(uid, data)
    local target = (data and data.uid) or uid
    remove_from_pool(target)
    LogInfo("[PvpCross] leave pool uid:", target, "pool_size:", #match_pool)
end

--- 匹配演算 (简单版: 取评分最接近的两人)
function try_match()
    if #match_pool < 2 then return end

    -- 按 rating 排序后取相邻对
    table.sort(match_pool, function(a, b) return a.rating < b.rating end)
    -- 重建索引
    for i, e in ipairs(match_pool) do uid_lookup[e.uid] = i end

    local best_i, best_diff = nil, math.huge
    for i = 1, #match_pool - 1 do
        local diff = math.abs(match_pool[i].rating - match_pool[i+1].rating)
        if diff < best_diff then
            best_diff = diff
            best_i = i
        end
    end

    if not best_i then return end

    -- 评分差距太大且等待时间不够长则跳过
    local p1 = match_pool[best_i]
    local p2 = match_pool[best_i + 1]
    local wait1 = os.time() - p1.join_time
    local wait2 = os.time() - p2.join_time
    if best_diff > 500 and wait1 < 10 and wait2 < 10 then
        return  -- 等更多人加入
    end

    -- 创建对局
    local match_id = generate_match_id()

    -- 先移除(先移后面的索引不乱)
    local uid1, uid2 = p1.uid, p2.uid
    remove_from_pool(uid2)
    remove_from_pool(uid1)

    -- 通知双方匹配成功
    RouteToAgent(uid1, "OnMatchSuccess", {
        match_id = match_id,
        opponent = { uid = uid2, rating = p2.rating },
    })
    RouteToAgent(uid2, "OnMatchSuccess", {
        match_id = match_id,
        opponent = { uid = uid1, rating = p1.rating },
    })

    LogInfo("[PvpCross] matched!", match_id, uid1, "vs", uid2)

    -- 模拟即时战斗结算 (简化: 评分高者 60% 胜率)
    simulate_battle(match_id, uid1, p1.rating, uid2, p2.rating)
end

--- 模拟战斗结算
function simulate_battle(match_id, uid1, r1, uid2, r2)
    -- 简单胜率模型: 评分高者有优势
    local total = r1 + r2
    local roll = math.random(1, total)
    local winner = roll <= r1 and uid1 or uid2

    LogInfo("[PvpCross] battle result match:", match_id,
            "winner:", winner, "r1:", r1, "r2:", r2)

    RouteToAgent(uid1, "OnBattleEnd", {
        match_id = match_id,
        win      = (winner == uid1),
        opponent = uid2,
    })
    RouteToAgent(uid2, "OnBattleEnd", {
        match_id = match_id,
        win      = (winner == uid2),
        opponent = uid1,
    })
end

--- 获取匹配池状态 (管理用)
function M.PvpGetPoolStatus(uid, data)
    RouteToAgent(uid, "OnPoolStatus", {
        pool_size = #match_pool,
    })
end

return M