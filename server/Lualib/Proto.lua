-- lualib/Proto.lua
-- protobuf编解码封装（适配 lua-protobuf / pb.dll）
-- 客户端协议: [2B msgId][protobuf payload]
-- 服务端内部: 纯lua table cast

local skynet = require "skynet"
local pb     = require "pb"

---@class Proto
local Proto = {}

local nameById = {}  ---@type table<integer, string>  msgId -> MsgId key name (display/debug)
local idByName = {}  ---@type table<string, integer>  MsgId key name -> msgId

-- BugFix BUG-14: 独立的 msgId -> protobuf message type name 映射
-- 解耦 MsgId 的 key(如 "C2S_Login") 与 .proto 中的 message 名(如 "LoginReq")
-- 未注册 proto mapping 时，fallback 到 nameById(即假设 proto name == MsgId key)
local protoNameById = {}  ---@type table<integer, string>  msgId -> proto type name

--- 注册单个协议映射
---@param id integer
---@param name string
function Proto.register(id, name)
    nameById[id] = name
    idByName[name] = id
end

--- 根据MsgId表自动注册所有协议映射
---@param msgIdTable table
function Proto.registerAll(msgIdTable)
    for name, id in pairs(msgIdTable) do
        nameById[id] = name
        idByName[name] = id
    end
end

--- BugFix BUG-14: 注册 msgId -> protobuf message type name 的独立映射
--- 若 .proto 中 message 名与 MsgId key 不同(如 "LoginReq" vs "C2S_Login")，
--- 必须通过此函数注册，否则 pb.decode/encode 找不到类型
--- 示例:
---   Proto.registerProtoMapping({
---       [1001] = "LoginReq",
---       [1002] = "LoginResp",
---   })
---@param mapping table<integer, string>  msgId -> proto message type name
function Proto.registerProtoMapping(mapping)
    for id, protoName in pairs(mapping) do
        protoNameById[id] = protoName
    end
end

--- 解码客户端二进制消息 -> msgId, lua table
---@param data string  raw bytes
---@return integer|nil msgId
---@return table|nil   body
function Proto.decode(data)
    if #data < 2 then return nil, nil end
    local hi, lo = data:byte(1, 2)
    local msgId = hi * 256 + lo
    -- BugFix BUG-14: 优先使用 proto type name 映射，fallback 到 MsgId key name
    local name = protoNameById[msgId] or nameById[msgId]
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
    -- BugFix BUG-14: 优先使用 proto type name 映射，fallback 到 MsgId key name
    local name = protoNameById[msgId] or nameById[msgId]
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
        local msg = string.format("[Proto] FATAL: cannot open pb file: %s", path)
        skynet.error(msg)
        error(msg)
    end
    local content = f:read("*a")
    f:close()
    if not content or #content == 0 then
        local msg = string.format("[Proto] FATAL: pb file is empty: %s", path)
        skynet.error(msg)
        error(msg)
    end

    -- lua-protobuf 使用 pb.load() 而非 protobuf.register()
    local ok, err = pb.load(content)
    if not ok then
        local msg = string.format("[Proto] FATAL: pb.load failed: %s", tostring(err))
        skynet.error(msg)
        error(msg)
    end

    -- 自动注册MsgId <-> proto name映射
    local MsgId = require "Proto.MsgId"
    Proto.registerAll(MsgId)

    skynet.error(string.format("[Proto] loaded %s (%d bytes)", path, #content))
end

return Proto