-- lualib/Proto.lua
-- protobuf编解码封装（适配 lua-protobuf / pb.dll）
-- 客户端协议: [2B msgId][protobuf payload]
-- 服务端内部: 纯lua table cast
--
-- msgId 有两层映射:
--   nameById:      msgId -> MsgId key name (调试/display用, 如 "C2S_Login")
--   protoNameById: msgId -> .proto message type name (pb编解码用, 如 "LoginReq")
-- decode/encode 优先查 protoNameById，fallback 到 nameById

local skynet = require "skynet"
local pb     = require "pb"

---@class Proto
local Proto = {}

local nameById      = {}  ---@type table<integer, string>
local idByName      = {}  ---@type table<string, integer>
local protoNameById = {}  ---@type table<integer, string>

--- 根据MsgId表自动注册所有协议映射
---@param msgIdTable table
function Proto.registerAll(msgIdTable)
    for name, id in pairs(msgIdTable) do
        nameById[id] = name
        idByName[name] = id
    end
end

--- 注册 msgId -> protobuf message type name 的独立映射
--- 当 .proto 中 message 名与 MsgId key 不同时(如 "LoginReq" vs "C2S_Login")必须注册
---@param mapping table<integer, string>
function Proto.registerProtoMapping(mapping)
    for id, protoName in pairs(mapping) do
        protoNameById[id] = protoName
    end
end

--- 获取 msgId 对应的 pb type name
---@param msgId integer
---@return string|nil
local function resolveTypeName(msgId)
    return protoNameById[msgId] or nameById[msgId]
end

--- 解码客户端二进制消息 -> msgId, lua table
---@param data string
---@return integer|nil msgId
---@return table|nil   body
function Proto.decode(data)
    if #data < 2 then
        skynet.error(string.format("[Proto] decode rejected: packet too short (%d bytes)", #data))
        return nil, nil
    end
    local hi, lo = data:byte(1, 2)
    local msgId = hi * 256 + lo
    local name = resolveTypeName(msgId)
    if not name then return msgId, nil end
    local ok, body = pcall(pb.decode, name, data:sub(3))
    if ok and body then
        return msgId, body
    end
    skynet.error(string.format("[Proto] decode failed: msgId=%d name=%s err=%s",
        msgId, name, tostring(body)))
    return msgId, nil
end

--- 编码lua table -> 客户端二进制消息
---@param msgId integer
---@param body table
---@return string|nil
function Proto.encode(msgId, body)
    local name = resolveTypeName(msgId)
    if not name then return nil end
    local ok, payload = pcall(pb.encode, name, body)
    if not ok or not payload then return nil end
    local hi = math.floor(msgId / 256)
    local lo = msgId % 256
    return string.char(hi, lo) .. payload
end

--- 通过名字编码
---@param name string
---@param body table
---@return string|nil
function Proto.encodeByName(name, body)
    local id = idByName[name]
    if not id then return nil end
    return Proto.encode(id, body)
end

--- 加载.pb文件并自动注册MsgId映射
---@param path string
function Proto.load(path)
    local f = io.open(path, "rb")
    if not f then
        error(string.format("[Proto] FATAL: cannot open pb file: %s", path))
    end
    local content = f:read("*a")
    f:close()
    if not content or #content == 0 then
        error(string.format("[Proto] FATAL: pb file is empty: %s", path))
    end

    local ok, err = pb.load(content)
    if not ok then
        error(string.format("[Proto] FATAL: pb.load failed: %s", tostring(err)))
    end

    local MsgId = require "Proto.MsgId"
    Proto.registerAll(MsgId)

    skynet.error(string.format("[Proto] loaded %s (%d bytes)", path, #content))
end

return Proto