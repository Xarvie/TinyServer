-- Cross/CrossService.lua
-- 跨服多人玩法进程: 房间管理
-- 模式: 1~4个gate + 此进程
-- 全cast，零call
-- BugFix #B20: joinRoom先检查新房间容量，再移除旧房间，防止满房时丢失原房间

local skynet   = require "skynet"
local Cast     = require "Cast"
local Dispatch = require "Dispatch"
local MsgId    = require "Proto.MsgId"

----------------------------------------------------------------
-- 房间数据
----------------------------------------------------------------
---@class RoomMember
---@field uid integer
---@field fd integer
---@field gate integer
---@field agent integer

---@class Room
---@field roomId string
---@field members table<integer, RoomMember>
---@field memberCount integer  Fix #8: O(1)计数
---@field state table

---@type table<string, Room>
local rooms = {}

---@type table<integer, string>  uid -> roomId (反向索引)
local uidToRoomId = {}

local MAX_ROOM_SIZE = 8
local coordinator   = 0  ---@type integer

----------------------------------------------------------------
-- 向房间成员广播(经agent)
----------------------------------------------------------------
---@param room Room
---@param msgId integer
---@param body table
---@param excludeUid string|nil
local function broadcastRoom(room, msgId, body, excludeUid)
    for uid, member in pairs(room.members) do
        if uid ~= excludeUid then
            Cast.send(member.agent, "crossResult", {
                uid   = uid,
                msgId = msgId,
                body  = body,
            })
        end
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
--- BugFix #B20: 先检查新房间容量，再移除旧房间，防止满房时丢失原房间
---@param source integer
---@param req table  { uid, roomId, fd, gate, agent }
function handler.joinRoom(source, req)
    local oldRoomId = uidToRoomId[req.uid]

    -- BugFix #B20: 先检查新房间容量(在移除旧房间之前)
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

    -- 如果玩家已在目标房间，更新成员信息即可
    if oldRoomId == req.roomId and room.members[req.uid] then
        room.members[req.uid] = {
            uid   = req.uid,
            fd    = req.fd,
            gate  = req.gate,
            agent = req.agent,
        }
        Cast.send(req.agent, "crossResult", {
            uid   = req.uid,
            msgId = MsgId.S2C_JoinResult,
            body  = { code = 0, roomId = req.roomId },
        })
        return
    end

    -- 人数上限检查(不计算玩家自身，因为还没加入)
    if room.memberCount >= MAX_ROOM_SIZE then
        Cast.send(req.agent, "crossResult", {
            uid   = req.uid,
            msgId = MsgId.S2C_JoinResult,
            body  = { code = 1, roomId = req.roomId },
        })
        return  -- BugFix #B20: 拒绝时不动旧房间，玩家保留原房间
    end

    -- 容量检查通过，现在安全移除旧房间
    if oldRoomId then
        local oldRoom = rooms[oldRoomId]
        if oldRoom and oldRoom.members[req.uid] then
            oldRoom.members[req.uid] = nil
            oldRoom.memberCount = oldRoom.memberCount - 1
            if oldRoom.memberCount <= 0 then
                rooms[oldRoomId] = nil
                skynet.error(string.format("[Cross] room %s destroyed (empty)", oldRoomId))
            end
        end
        uidToRoomId[req.uid] = nil
    end

    room.members[req.uid] = {
        uid   = req.uid,
        fd    = req.fd,
        gate  = req.gate,
        agent = req.agent,
    }
    room.memberCount = room.memberCount + 1
    uidToRoomId[req.uid] = req.roomId  -- 反向索引

    Cast.send(req.agent, "crossResult", {
        uid   = req.uid,
        msgId = MsgId.S2C_JoinResult,
        body  = { code = 0, roomId = req.roomId },
    })

    skynet.error(string.format("[Cross] %s joined room %s", req.uid, req.roomId))
end

--- 房间操作 -- O(1) 定位房间
---@param source integer
---@param req table  { uid, actionType, payload }
function handler.roomAction(source, req)
    local roomId = uidToRoomId[req.uid]
    if not roomId then return end
    local room = rooms[roomId]
    if not room then return end

    -- 处理逻辑(此处简化为广播同步)
    broadcastRoom(room, MsgId.S2C_RoomSync, {
        snapshot = req.payload or "",
    })
end

--- 玩家离开房间 -- O(1) 定位房间
---@param source integer
---@param req table  { uid }
function handler.leaveRoom(source, req)
    local roomId = uidToRoomId[req.uid]
    if not roomId then return end

    uidToRoomId[req.uid] = nil

    local room = rooms[roomId]
    if not room then return end

    if room.members[req.uid] then
        room.members[req.uid] = nil
        room.memberCount = room.memberCount - 1
    end
    if room.memberCount <= 0 then
        rooms[roomId] = nil
        skynet.error(string.format("[Cross] room %s destroyed", roomId))
    end
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
Dispatch.new(handler)