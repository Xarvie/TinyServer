-- Cross/CrossService.lua
-- 跨服多人玩法进程: 房间管理
-- 全cast，零call
--
-- 房间数据全内存，进程重启后丢失。
-- 客户端断线重连后需重新 joinRoom。

local skynet   = require "skynet"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local MsgId    = require "Proto.MsgId"
local ErrCode  = require "Proto.ErrorCode"

----------------------------------------------------------------
-- 房间数据
----------------------------------------------------------------
---@class RoomMember
---@field uid   integer
---@field fd    integer
---@field gate  integer
---@field agent integer

---@class Room
---@field roomId      string
---@field members     table<integer, RoomMember>
---@field memberCount integer
---@field state       table

---@type table<string, Room>
local rooms = {}

---@type table<integer, string>  uid -> roomId
local uidToRoomId = {}

local MAX_ROOM_SIZE = 8
local coordinator   = 0  ---@type integer

----------------------------------------------------------------
-- 向房间成员广播(直接 cast gate，跳过 agent 中转)
----------------------------------------------------------------
---@param room Room
---@param msgId integer
---@param body table
---@param excludeUid integer|nil
local function broadcastRoom(room, msgId, body, excludeUid)
    for uid, member in pairs(room.members) do
        if uid ~= excludeUid then
            Cast.send(member.gate, "push", {
                fd    = member.fd,
                msgId = msgId,
                body  = body,
            })
        end
    end
end

--- 通知单个成员(经 agent，用于需要 agent 处理的场景如 joinResult)
---@param member RoomMember
---@param msgId integer
---@param body table
local function notifyViaAgent(member, msgId, body)
    Cast.send(member.agent, "crossResult", {
        uid   = member.uid,
        msgId = msgId,
        body  = body,
    })
end

----------------------------------------------------------------
-- 从旧房间移除玩家(内部工具函数)
----------------------------------------------------------------
---@param uid integer
local function removeFromOldRoom(uid)
    local roomId = uidToRoomId[uid]
    if not roomId then return end

    uidToRoomId[uid] = nil

    local room = rooms[roomId]
    if not room then return end

    if room.members[uid] then
        room.members[uid] = nil
        room.memberCount = room.memberCount - 1
    end
    if room.memberCount <= 0 then
        rooms[roomId] = nil
        skynet.error(string.format("[Cross] room %s destroyed (empty)", roomId))
    end
end

----------------------------------------------------------------
-- 命令处理
----------------------------------------------------------------
local handler = {}

---@param source integer
---@param cfg table
function handler.init(source, cfg)
    coordinator = cfg.coordinator or source
    skynet.error("[Cross] initialized")
end

--- 加入房间(agent cast过来)
--- 先检查新房间容量，再移除旧房间，防止满房时丢失原房间
---@param source integer
---@param req table  { uid, roomId, fd, gate, agent }
function handler.joinRoom(source, req)
    local oldRoomId = uidToRoomId[req.uid]

    -- 获取或创建目标房间
    local room = rooms[req.roomId]
    if not room then
        room = {
            roomId      = req.roomId,
            members     = {},
            memberCount = 0,
            state       = {},
        }
        rooms[req.roomId] = room
    end

    local member = {
        uid   = req.uid,
        fd    = req.fd,
        gate  = req.gate,
        agent = req.agent,
    }

    -- 已在目标房间，更新成员信息即可
    if oldRoomId == req.roomId and room.members[req.uid] then
        room.members[req.uid] = member
        notifyViaAgent(member, MsgId.S2C_JoinResult,
            { code = ErrCode.ROOM_JOIN_OK, roomId = req.roomId })
        return
    end

    -- 人数上限检查
    if room.memberCount >= MAX_ROOM_SIZE then
        notifyViaAgent(member, MsgId.S2C_JoinResult,
            { code = ErrCode.ROOM_FULL, roomId = req.roomId })
        return  -- 拒绝时不动旧房间
    end

    -- 容量检查通过，安全移除旧房间
    removeFromOldRoom(req.uid)

    room.members[req.uid] = member
    room.memberCount = room.memberCount + 1
    uidToRoomId[req.uid] = req.roomId

    notifyViaAgent(member, MsgId.S2C_JoinResult,
        { code = ErrCode.ROOM_JOIN_OK, roomId = req.roomId })

    skynet.error(string.format("[Cross] %s joined room %s", req.uid, req.roomId))
end

--- 房间操作
---@param source integer
---@param req table  { uid, actionType, payload }
function handler.roomAction(source, req)
    local roomId = uidToRoomId[req.uid]
    if not roomId then return end
    local room = rooms[roomId]
    if not room then return end

    broadcastRoom(room, MsgId.S2C_RoomSync, {
        snapshot = req.payload or "",
    })
end

--- 玩家离开房间
---@param source integer
---@param req table  { uid }
function handler.leaveRoom(source, req)
    removeFromOldRoom(req.uid)
end

--- 优雅关闭
---@param source integer
function handler.shutdown(source)
    skynet.error("[Cross] shutting down, clearing rooms...")
    rooms = {}
    uidToRoomId = {}
    skynet.error("[Cross] shutdown complete")
    Cast.send(coordinator, "shutdownAck")
end

----------------------------------------------------------------
Dispatch.start(handler)