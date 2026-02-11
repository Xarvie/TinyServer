--------------------------------------------------------------
-- sdk.lua
-- 业务模块 SDK：log + send + ticket
--------------------------------------------------------------
local skynet = require "skynet"

local S = {}

--------------------------------------------------------------
-- log: 统一日志
--------------------------------------------------------------
local log = {}

local LOG_LEVEL = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local current_level = LOG_LEVEL.INFO

function log.set_level(level)
    current_level = LOG_LEVEL[level] or LOG_LEVEL.INFO
end

local function fmt(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

function log.debug(...)
    if current_level <= LOG_LEVEL.DEBUG then
        skynet.error("[DEBUG]", fmt(...))
    end
end

function log.info(...)
    if current_level <= LOG_LEVEL.INFO then
        skynet.error("[INFO]", fmt(...))
    end
end

function log.warn(...)
    if current_level <= LOG_LEVEL.WARN then
        skynet.error("[WARN]", fmt(...))
    end
end

function log.error(...)
    if current_level <= LOG_LEVEL.ERROR then
        skynet.error("[ERROR]", fmt(...))
    end
end

function log.flow(tag, data)
    local parts = { "[FLOW][" .. tostring(tag) .. "]" }
    if type(data) == "table" then
        for k, v in pairs(data) do
            parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
        end
    else
        parts[#parts+1] = tostring(data)
    end
    skynet.error(table.concat(parts, " "))
end

S.log = log

--------------------------------------------------------------
-- send: 消息发送
--------------------------------------------------------------
local codec  -- 延迟引用，在 install_compat 后可用
local send = {}

function send.SendToClient(player, pid, data)
    if not codec then codec = require("framework").codec end
    if not player or not player.gate_addr then
        log.warn("[Send] no gate_addr, uid:", player and player.uid or "?")
        return
    end
    local frame, err = codec.encode(pid, data)
    if not frame then
        log.error("[Send] encode fail pid:", pid, err)
        return
    end
    skynet.send(player.gate_addr, "lua", "forward_to_client", player.uid, frame)
end

function send.SendToGate(player, route_type, ...)
    if not player or not player.gate_addr then
        log.warn("[Send] no gate_addr for route:", route_type)
        return
    end
    skynet.send(player.gate_addr, "lua", "agent_route_request",
        player.uid, route_type, ...)
end

S.send = send

--------------------------------------------------------------
-- ticket: 跨服凭证
--------------------------------------------------------------
local ticket = {}

ticket.TICKET_EXPIRE = 3600
local ticket_counter = 0

local function random_str(len)
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local buf = {}
    for i = 1, len do
        local idx = math.random(1, #chars)
        buf[i] = chars:sub(idx, idx)
    end
    return table.concat(buf)
end

function ticket.generate(uid, cross_type)
    ticket_counter = ticket_counter + 1
    return string.format("%d_%s_%d_%d_%s",
        uid, cross_type, os.time(), ticket_counter, random_str(12))
end

function ticket.verify(uid, tk)
    if not tk or type(tk) ~= "string" then
        return false, "invalid ticket"
    end
    local t_uid, t_cross, t_time = tk:match("^(%d+)_([%w_]+)_(%d+)_")
    if not t_uid then
        return false, "malformed ticket"
    end
    if tonumber(t_uid) ~= uid then
        return false, "uid mismatch"
    end
    local ticket_time = tonumber(t_time) or 0
    if os.time() - ticket_time > ticket.TICKET_EXPIRE then
        return false, "ticket expired"
    end
    return true
end

function ticket.get_cross_type(tk)
    if not tk then return nil end
    local _, ct = tk:match("^(%d+)_([%w_]+)_")
    return ct
end

S.ticket = ticket

--------------------------------------------------------------
-- 兼容 shim：让旧的 require "log" 等继续工作
--------------------------------------------------------------
function S.install_compat()
    package.loaded["log"]    = log
    package.loaded["send"]   = send
    package.loaded["ticket"] = ticket
end

return S