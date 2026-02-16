-- lualib/Dispatch.lua
-- 极简命令分发器，所有服务继承此范式
-- 约定: handler中每个函数对应一个cmd，纯cast无返回
--
-- 使用方式(二选一):
--   方式A: 服务无额外初始化需求时，文件末尾调用 Dispatch.start(handler)
--   方式B: 需在 skynet.start 中做额外初始化后再 Dispatch.register(handler)

local skynet = require "skynet"

---@class Dispatch
local Dispatch = {}

--- 内部: 设置 skynet.dispatch (pcall保护每条消息)
---@param handler table
local function setupDispatch(handler)
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local fn = handler[cmd]
        if fn then
            local ok, err = pcall(fn, source, ...)
            if not ok then
                skynet.error(string.format("[Dispatch] error in cmd '%s' from %08x: %s",
                    cmd, source, tostring(err)))
            end
        else
            skynet.error(string.format("[Dispatch] unknown cmd: %s from: %08x", cmd, source))
        end
    end)
end

--- 启动服务并注册消息分发(包含 skynet.start)
---@param handler table  命令处理表 { cmdName = function(source, ...) end }
function Dispatch.start(handler)
    skynet.start(function()
        setupDispatch(handler)
    end)
end

--- 仅注册handler到skynet.dispatch，不调用skynet.start
--- 适用于已在 skynet.start 回调内的场景(如 DbService)
---@param handler table  命令处理表
function Dispatch.register(handler)
    setupDispatch(handler)
end

return Dispatch