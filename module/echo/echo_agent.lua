local M = {}
M._MODULE_ID = 99

M.C2S = {
    [1099001] = "C2S_Echo",
    [1099002] = "C2S_Ping",
}
M.S2C = {
    [5099001] = "S2C_Echo",
    [5099002] = "S2C_Pong",
}

function M.C2S_Echo(player, req)
    return { code = 0, echo = req, uid = player.uid, time = os.time() }
end

function M.C2S_Ping(player, req)
    return { code = 0, server_time = os.time(), your_data = req }
end

return M
