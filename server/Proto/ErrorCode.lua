-- Proto/ErrorCode.lua
-- 统一错误码定义，客户端/服务端对齐

---@class ErrorCode
local ErrorCode = {
    -- 认证
    AUTH_OK              = 0,
    AUTH_DB_ERROR        = 4,
    AUTH_NO_AGENT        = 99,

    -- 踢线原因码
    KICK_NORMAL_LOGOUT   = 0,
    KICK_REPLACED        = 1,
    KICK_HEARTBEAT       = -2,
    KICK_SERVER_SHUTDOWN = -1,

    -- 跨服房间
    ROOM_JOIN_OK         = 0,
    ROOM_FULL            = 1,

    -- 认证失败上限(gate authkey校验 + db authResult 共用同一阈值)
    AUTH_FAIL_LIMIT      = 5,
}

return ErrorCode