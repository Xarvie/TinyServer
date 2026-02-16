-- config/Config.lua
--- 全局配置文件
---
--- 敏感信息(密码、地址)从环境变量读取，不硬编码在源码中
--- 环境变量未设置时使用开发默认值
---
--- UID 位布局 (int32):
---   bit31      = 0         (符号位)
---   bit30~13   = serverId  (18位, [0, 262143])
---   bit12~0    = playerId  (13位, [1, 8191])
---   uid = (serverId << 13) | playerId

local function env(key, default)
    return os.getenv(key) or default
end

local function envInt(key, default)
    local v = os.getenv(key)
    return v and tonumber(v) or default
end

return {
    serverId        = envInt("GAME_SERVER_ID", 1),
    gateCount       = 4,
    agentCount      = 4,
    dbCount         = 4,
    wsPort          = envInt("GAME_WS_PORT", 9948),
    maxClient       = 1024,
    protoPath       = "./Proto/",
    heartbeatSec    = 60,
    heartbeatCheck  = 10,

    mongo = {
        host     = env("MONGO_HOST",     "127.0.0.1"),
        port     = envInt("MONGO_PORT",   27017),
        db       = env("MONGO_DB",        "game"),
        authdb   = env("MONGO_AUTHDB",    "admin"),
        username = env("MONGO_USERNAME",  ""),
        password = env("MONGO_PASSWORD",  ""),
    },
}