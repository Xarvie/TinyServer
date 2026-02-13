-- config/config.lua
--- 全局配置文件，提供全局可访问的常量和配置项

return {
    gateCount       = 4,       -- 1~4 gate进程
    agentCount      = 4,       -- 1~4 agent进程(agent池)
    dbCount         = 1,       -- 1个db进程
    wsPort          = 9948,    -- websocket起始端口(每个gate +1)
    maxClient       = 1024,    -- 每gate最大连接
    protoPath       = "./proto/",
    heartbeatSec    = 60,      -- 心跳超时(秒)，超过此时间无消息则踢下线
    heartbeatCheck  = 10,      -- 心跳扫描间隔(秒)
}
