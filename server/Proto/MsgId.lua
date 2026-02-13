-- proto/MsgId.lua
-- 协议号定义，客户端服务端共用

---@class MsgId
local MsgId = {
    -- 认证
    C2S_Login       = 1001,
    S2C_LoginResult = 1002,
    C2S_Register    = 1003,
    S2C_RegisterResult = 1004,

    -- 玩家
    C2S_Logout      = 1101,
    S2C_Kick        = 1102,

    -- 跨服/多人玩法
    C2S_JoinRoom    = 2001,
    S2C_JoinResult  = 2002,
    C2S_RoomAction  = 2003,
    S2C_RoomSync    = 2004,

    -- 背包业务 (3xxx)
    C2S_UseItem    = 3001,
    S2C_BagUpdate  = 3002,
    
    -- 心跳
    C2S_Ping        = 9001,
    S2C_Pong        = 9002,
}

return MsgId
