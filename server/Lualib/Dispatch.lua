-- lualib/Dispatch.lua
-- 极简命令分发器，所有服务继承此范式
-- 约定: handler中每个函数对应一个cmd，纯cast无返回

local skynet = require "skynet"

---@class Dispatch
local Dispatch = {}
Dispatch.__index = Dispatch

--- 创建分发器并注册到skynet
--- Fix #17: handler执行增加pcall保护，防止单条消息异常影响后续调度
---@param handler table  命令处理表 { cmdName = function(source, ...) end }
---@return Dispatch
function Dispatch.new(handler)
    local self = setmetatable({}, Dispatch)
    self.handler = handler or {}

    skynet.start(function()
        skynet.dispatch("lua", function(session, source, cmd, ...)
            local fn = self.handler[cmd]
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
    end)

    return self
end

--- 动态注册命令
---@param cmd string
---@param fn function
function Dispatch:on(cmd, fn)
    self.handler[cmd] = fn
end

return Dispatch