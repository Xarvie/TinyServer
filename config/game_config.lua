local M = {}

M.gate = {
    host             = "0.0.0.0",
    port             = 8888,
    max_connections  = 4096,
    msg_max_len      = 65535,
    heartbeat        = 60,
}

M.agent = {
    pool_size = 4,
}

M.db = {
    driver         = "mongo",
    host           = "127.0.0.1",
    port           = 27017,
    name           = "skynet_game",
    auth_db        = nil,
    username       = nil,
    password       = nil,
    player_col     = "players",
    save_interval  = 30,
}

M.inter = {
    broadcast_batch_size  = 50,
    broadcast_batch_delay = 5,   -- tick (1/100s)
}

M.cross = {
    -- 跨服类型 → 模块映射
    type_map = {
        pvp_match = { module = "pvp", cross_module_id = 103 },
    },
    ticket_expire = 3600,   -- 凭证过期秒数
}

M.module = {
    scan_paths = {
        "module/login",
        "module/echo",
        "module/bag",
        "module/rank",
        "module/pvp",
    },
}

M.hotreload = {
    allowed_suffixes   = { "_agent", "_inter", "_cross" },
    forbidden_suffixes = { "_db", "_gate" },
}

M.logger = {
    max_buffer = 10000,
    max_flow   = 10000,
}

return M