-- config/config.lua
--- 全局配置文件，提供全局可访问的常量和配置项
---
--- UID 位布局 (int32):
---   bit31      = 0         (符号位)
---   bit30~13   = serverId  (18位, [0, 262143])
---   bit12~0    = playerId  (13位, [1, 8191])
---   uid = (serverId << 13) | playerId
---   每服最多 8191 个玩家

return {
    serverId        = 1,       -- 服务器ID (18位, 范围 [0, 262143])

    gateCount       = 4,       -- 1~4 gate进程
    agentCount      = 4,       -- 1~4 agent进程(agent池)
    dbCount         = 4,       -- 4个db进程
    wsPort          = 9948,    -- websocket起始端口(每个gate +1)
    maxClient       = 1024,    -- 每gate最大连接
    protoPath       = "./Proto/",
    heartbeatSec    = 60,      -- 心跳超时(秒)，超过此时间无消息则踢下线
    heartbeatCheck  = 10,      -- 心跳扫描间隔(秒)

    -- MongoDB 持久化配置
    mongo = {
        host     = "118.89.55.243",   -- MongoDB 地址
        port     = 27017,          -- MongoDB 端口
        db       = "game",         -- 业务数据库名
        authdb   = "admin",        -- 认证数据库名(用户建在哪个库就填哪个)
        username = "root",         -- MongoDB 用户名（无认证时留空 ""）
        password = "xiaweiye123",        -- MongoDB 密码（无认证时留空 ""）
    },
}