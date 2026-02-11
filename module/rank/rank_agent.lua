--------------------------------------------------------------
-- rank_agent.lua — 模块 006 排行榜 Agent 层
--
-- 协议:
--   1006001 C2S_GetRank     → 5006001 (通过 Inter 异步返回)
--   1006002 C2S_SubmitScore → 5006002
--
-- 推送:
--   8006001 PUSH_RankingChange — 排名变化通知
--------------------------------------------------------------
local log = require "log"
local M = {}
M._MODULE_ID = 6

M.C2S = {
    [1006001] = "C2S_GetRank",
    [1006002] = "C2S_SubmitScore",
}

M.S2C = {
    [5006001] = "S2C_RankList",
    [5006002] = "S2C_SubmitScoreResult",
}

M.PUSH = {
    [8006001] = "PUSH_RankingChange",
}

function M.OnInit(player)
    if not player.RankData then
        player.RankData = require("rank_db").GetDefaultData()
        player.RankDirty = true
    end
end

--- 获取排行榜 — 请求 Inter 异步返回
function M.C2S_GetRank(player, req)
    SendToGate(player, "RouteToInter", "RankGetList", {
        uid    = player.uid,
        top_n  = req and req.top_n or 20,
    })
    -- Inter 处理后会通过 OnRankList 回调推送给客户端
    return { code = 0, msg = "requesting" }
end

--- 提交分数
function M.C2S_SubmitScore(player, req)
    local score = req and req.score
    if not score or type(score) ~= "number" or score < 0 then
        return { code = 1, msg = "invalid score" }
    end

    -- 只保留最高分
    local old = player.RankData.best_score or 0
    local updated = false
    if score > old then
        player.RankData.best_score = score
        updated = true
    end
    player.RankData.submit_count = (player.RankData.submit_count or 0) + 1
    player.RankDirty = true

    -- 通知 Inter 更新排行
    SendToGate(player, "RouteToInter", "RankSubmitScore", {
        uid   = player.uid,
        score = player.RankData.best_score,
    })

    log.info("[Rank] submit uid:", player.uid, "score:", score,
             "best:", player.RankData.best_score, "updated:", tostring(updated))
    return { code = 0, score = player.RankData.best_score, updated = updated }
end

--- Inter 回调: 排行榜列表结果
function M.OnRankList(player, data)
    SendToClient(player, 5006001, data)
end

--- Inter 回调: 排名变化通知
function M.OnRankChange(player, data)
    if data and data.rank then
        player.RankData.last_rank = data.rank
        player.RankDirty = true
    end
    SendToClient(player, 8006001, data)
end

return M