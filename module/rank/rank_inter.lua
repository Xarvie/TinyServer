--------------------------------------------------------------
-- rank_inter.lua — 模块 206 排行榜 Inter 协调层
--
-- 维护全服内存排行榜，处理提交/查询/广播
--------------------------------------------------------------
local M = {}
M._MODULE_ID = 206

-- 排行榜数据: { {uid=xxx, score=yyy}, ... } 按 score 降序
local rank_list = {}
-- uid -> index in rank_list (快速查找)
local uid_index = {}

local MAX_RANK_SIZE = 200

local function rebuild_index()
    uid_index = {}
    for i, entry in ipairs(rank_list) do
        uid_index[entry.uid] = i
    end
end

local function sort_and_trim()
    table.sort(rank_list, function(a, b)
        if a.score == b.score then return a.uid < b.uid end
        return a.score > b.score
    end)
    -- 裁剪
    while #rank_list > MAX_RANK_SIZE do
        local removed = table.remove(rank_list)
        uid_index[removed.uid] = nil
    end
    rebuild_index()
end

--- 提交分数 (Agent → Inter)
function M.RankSubmitScore(uid, data)
    if not data or not data.uid or not data.score then return end
    local s_uid  = data.uid
    local score  = data.score

    local idx = uid_index[s_uid]
    if idx then
        -- 只更新更高分
        if score > rank_list[idx].score then
            rank_list[idx].score = score
        end
    else
        rank_list[#rank_list+1] = { uid = s_uid, score = score }
    end

    sort_and_trim()

    -- 通知提交者排名变化
    local new_idx = uid_index[s_uid]
    if new_idx then
        RouteToAgent(s_uid, "OnRankChange", {
            uid   = s_uid,
            rank  = new_idx,
            score = score,
        })
    end

    LogInfo("[RankInter] submit uid:", s_uid, "score:", score,
            "rank:", new_idx or "unranked")
end

--- 查询排行榜 (Agent → Inter → Agent)
function M.RankGetList(uid, data)
    if not data or not data.uid then return end
    local req_uid = data.uid
    local top_n   = data.top_n or 20

    local list = {}
    for i = 1, math.min(top_n, #rank_list) do
        list[i] = {
            rank  = i,
            uid   = rank_list[i].uid,
            score = rank_list[i].score,
        }
    end

    -- 查询者自己的排名
    local my_rank = uid_index[req_uid] or 0

    RouteToAgent(req_uid, "OnRankList", {
        list    = list,
        my_rank = my_rank,
    })
end

return M