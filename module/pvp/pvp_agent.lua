--------------------------------------------------------------
-- pvp_agent.lua — 模块 003 PVP Agent 层
--
-- 协议:
--   1003001 C2S_GetPVPInfo   → 5003001
--   1003002 C2S_JoinMatch    → 5003002
--   1003003 C2S_LeaveMatch   → 5003003
--
-- 推送:
--   8003001 PUSH_MatchResult  — 匹配结果
--   8003002 PUSH_BattleResult — 战斗结果
--------------------------------------------------------------
local log = require "log"
local M = {}
M._MODULE_ID = 3

M.C2S = {
    [1003001] = "C2S_GetPVPInfo",
    [1003002] = "C2S_JoinMatch",
    [1003003] = "C2S_LeaveMatch",
}

M.S2C = {
    [5003001] = "S2C_PVPInfo",
    [5003002] = "S2C_JoinMatchResult",
    [5003003] = "S2C_LeaveMatchResult",
}

M.PUSH = {
    [8003001] = "PUSH_MatchResult",
    [8003002] = "PUSH_BattleResult",
}

function M.OnInit(player)
    if not player.PvpData then
        player.PvpData = require("pvp_db").GetDefaultData()
        player.PvpDirty = true
    end
    -- 如果上次异常下线时还在匹配中，重置
    if player.PvpData.in_match then
        player.PvpData.in_match = false
        player.PvpData.match_id = nil
        player.PvpDirty = true
    end
end

function M.OnDestroy(player)
    -- 下线时如果在匹配中，通知 Cross 移除
    if player.PvpData and player.PvpData.in_match then
        SendToGate(player, "RouteToCross", "pvp_match", "PvpOnMatchLeave", {
            uid = player.uid,
        })
        player.PvpData.in_match = false
        player.PvpData.match_id = nil
        player.PvpDirty = true
    end
end

function M.C2S_GetPVPInfo(player, req)
    return {
        code = 0,
        data = {
            total_matches = player.PvpData.total_matches,
            win_count     = player.PvpData.win_count,
            lose_count    = player.PvpData.lose_count,
            rating        = player.PvpData.rating,
            in_match      = player.PvpData.in_match,
        },
    }
end

function M.C2S_JoinMatch(player, req)
    if player.PvpData.in_match then
        return { code = 1, msg = "already in match" }
    end

    -- 冷却检查
    local now = os.time()
    if now - (player.PvpData.last_match_time or 0) < 5 then
        return { code = 2, msg = "cooldown" }
    end

    -- 请求跨服授权
    SendToGate(player, "RequestCrossAuth", "pvp_match", {
        uid    = player.uid,
        rating = player.PvpData.rating,
    })

    player.PvpData.in_match = true
    player.PvpData.last_match_time = now
    player.PvpDirty = true

    log.info("[PVP] join match uid:", player.uid, "rating:", player.PvpData.rating)
    return { code = 0 }
end

function M.C2S_LeaveMatch(player, req)
    if not player.PvpData.in_match then
        return { code = 1, msg = "not in match" }
    end

    SendToGate(player, "RouteToCross", "pvp_match", "PvpOnMatchLeave", {
        uid = player.uid,
    })

    player.PvpData.in_match = false
    player.PvpData.match_id = nil
    player.PvpDirty = true

    log.info("[PVP] leave match uid:", player.uid)
    return { code = 0 }
end

--- Cross 回调: 匹配成功
function M.OnMatchSuccess(player, data)
    player.PvpData.in_match = false
    player.PvpData.match_id = data.match_id
    player.PvpDirty = true

    log.info("[PVP] match success uid:", player.uid, "match:", data.match_id)
    SendToClient(player, 8003001, {
        match_id = data.match_id,
        opponent = data.opponent,
    })
end

--- Cross 回调: 战斗结束
function M.OnBattleEnd(player, data)
    local win = data.win
    if win then
        player.PvpData.win_count = player.PvpData.win_count + 1
        player.PvpData.rating = player.PvpData.rating + 20
    else
        player.PvpData.lose_count = player.PvpData.lose_count + 1
        player.PvpData.rating = math.max(0, player.PvpData.rating - 15)
    end
    player.PvpData.total_matches = player.PvpData.total_matches + 1
    player.PvpData.match_id = nil
    player.PvpDirty = true

    log.info("[PVP] battle end uid:", player.uid, "win:", tostring(win),
             "rating:", player.PvpData.rating)
    SendToClient(player, 8003002, {
        win    = win,
        rating = player.PvpData.rating,
        delta  = win and 20 or -15,
    })
end

return M