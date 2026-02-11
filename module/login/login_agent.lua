local log = require "log"
local M = {}
M._MODULE_ID = 1

M.C2S = {
    [1001001] = "C2S_Login",
    [1001002] = "C2S_GetBaseInfo",
    [1001003] = "C2S_SetNickname",
}

M.S2C = {
    [5001001] = "S2C_LoginResult",
    [5001002] = "S2C_BaseInfo",
    [5001003] = "S2C_SetNicknameResult",
}

function M.OnInit(player)
    if player.LoginData then
        player.LoginData.last_login  = os.time()
        player.LoginData.login_count = (player.LoginData.login_count or 0) + 1
        player.LoginDirty = true
    end
end

function M.OnDestroy(player)
    if player.LoginData then
        local s = os.time() - (player.login_time or os.time())
        player.LoginData.total_online = (player.LoginData.total_online or 0) + s
        player.LoginDirty = true
    end
end

function M.C2S_Login(player, req)
    return {
        code = 0,
        uid  = player.uid,
        data = {
            nickname    = player.LoginData.nickname,
            level       = player.LoginData.level,
            create_time = player.LoginData.create_time,
        },
    }
end

function M.C2S_GetBaseInfo(player, req)
    return {
        code = 0,
        data = {
            uid          = player.uid,
            nickname     = player.LoginData.nickname,
            level        = player.LoginData.level,
            exp          = player.LoginData.exp,
            vip          = player.LoginData.vip,
            avatar       = player.LoginData.avatar,
            last_login   = player.LoginData.last_login,
            login_count  = player.LoginData.login_count,
            total_online = player.LoginData.total_online,
        },
    }
end

function M.C2S_SetNickname(player, req)
    local name = req and req.nickname
    if not name or type(name) ~= "string" then
        return { code = 1, msg = "invalid nickname" }
    end
    if #name < 2 or #name > 24 then
        return { code = 2, msg = "length 2-24" }
    end
    player.LoginData.nickname = name
    player.LoginDirty = true
    return { code = 0, nickname = name }
end

return M
