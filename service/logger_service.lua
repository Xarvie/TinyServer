--------------------------------------------------------------
-- logger_service.lua — 日志服务 (M3)
--
-- 职责:
--   1. 接收所有服务的结构化日志
--   2. 关键操作流水记录
--   3. 按玩家 UID / 模块名 / 时间段可查询
--------------------------------------------------------------
local skynet = require "skynet"
local log    = require "log"

local CMD = {}

-- 内存日志缓冲 (生产环境应写入文件/数据库)
-- { { time, level, source, uid, module, message, extra }, ... }
local log_buffer = {}
local MAX_BUFFER = 10000

-- 流水日志 { { time, tag, data }, ... }
local flow_buffer = {}
local MAX_FLOW = 10000

local function trim_buffer(buf, max)
    while #buf > max do
        table.remove(buf, 1)
    end
end

--------------------------------------------------------------
-- CMD
--------------------------------------------------------------

function CMD.init(_)
    log.info("[Logger] initialized")
    return true
end

--- 记录普通日志
-- @param level   "DEBUG" | "INFO" | "WARN" | "ERROR"
-- @param uid     玩家 UID (可为 nil)
-- @param module  模块名 (可为 nil)
-- @param message 日志内容
-- @param extra   附加数据 table (可为 nil)
function CMD.log(_, level, uid, module_name, message, extra)
    local entry = {
        time    = os.time(),
        level   = level or "INFO",
        uid     = uid,
        module  = module_name,
        message = message,
        extra   = extra,
    }
    log_buffer[#log_buffer+1] = entry
    trim_buffer(log_buffer, MAX_BUFFER)

    -- 也输出到 skynet 控制台
    skynet.error(string.format("[%s][%s] uid:%s mod:%s %s",
        entry.level,
        os.date("%H:%M:%S", entry.time),
        tostring(uid or "-"),
        tostring(module_name or "-"),
        tostring(message)
    ))
end

--- 记录流水日志
-- @param tag   流水标签 (如 "LOGIN", "TRADE", "PVP")
-- @param data  流水数据 table
function CMD.flow(_, tag, data)
    local entry = {
        time = os.time(),
        tag  = tag,
        data = data,
    }
    flow_buffer[#flow_buffer+1] = entry
    trim_buffer(flow_buffer, MAX_FLOW)

    -- 控制台输出
    local parts = { "[FLOW][" .. tostring(tag) .. "]" }
    if type(data) == "table" then
        for k, v in pairs(data) do
            parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    skynet.error(table.concat(parts, " "))
end

--- 查询日志 (按条件过滤)
-- @param filter { uid, module, level, time_start, time_end, limit }
function CMD.query(_, filter)
    filter = filter or {}
    local results = {}
    local limit = filter.limit or 100
    local count = 0

    for i = #log_buffer, 1, -1 do
        if count >= limit then break end
        local e = log_buffer[i]
        local match = true

        if filter.uid and e.uid ~= filter.uid then match = false end
        if filter.module and e.module ~= filter.module then match = false end
        if filter.level and e.level ~= filter.level then match = false end
        if filter.time_start and e.time < filter.time_start then match = false end
        if filter.time_end and e.time > filter.time_end then match = false end

        if match then
            results[#results+1] = e
            count = count + 1
        end
    end

    return results
end

--- 查询流水日志
-- @param filter { tag, uid, time_start, time_end, limit }
function CMD.query_flow(_, filter)
    filter = filter or {}
    local results = {}
    local limit = filter.limit or 100
    local count = 0

    for i = #flow_buffer, 1, -1 do
        if count >= limit then break end
        local e = flow_buffer[i]
        local match = true

        if filter.tag and e.tag ~= filter.tag then match = false end
        if filter.uid and (not e.data or e.data.uid ~= filter.uid) then match = false end
        if filter.time_start and e.time < filter.time_start then match = false end
        if filter.time_end and e.time > filter.time_end then match = false end

        if match then
            results[#results+1] = e
            count = count + 1
        end
    end

    return results
end

--- 获取统计信息
function CMD.stats(_)
    return {
        log_count  = #log_buffer,
        flow_count = #flow_buffer,
        max_log    = MAX_BUFFER,
        max_flow   = MAX_FLOW,
    }
end

--------------------------------------------------------------
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session ~= 0 then skynet.ret(skynet.pack(f(source, ...)))
            else f(source, ...) end
        end
    end)
    log.info("[Logger] service loaded")
end)