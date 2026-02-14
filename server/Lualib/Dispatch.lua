-- lualib/Dispatch.lua
-- 极简命令分发器，所有服务继承此范式
-- 约定: handler中每个函数对应一个cmd，纯cast无返回

local skynet = require "skynet"

---@class Dispatch
local Dispatch = {}
Dispatch.__index = Dispatch

--- 创建分发器并注册到skynet
--- Fix #17: handler执行增加pcall保护，防止单条消息异常影响后续调度
--- BugFix BUG-16: 保留 new() 向后兼容，新增 register()+start() 供需要在
---   skynet.start 内做额外初始化的服务使用(如 Main.lua)
---@param handler table  命令处理表 { cmdName = function(source, ...) end }
---@return Dispatch
function Dispatch.new(handler)
    local self = setmetatable({}, Dispatch)
    self.handler = handler or {}

    skynet.start(function()
        Dispatch._setupDispatch(self.handler)
    end)

    return self
end

--- BugFix BUG-16: 仅注册handler到skynet.dispatch，不调用skynet.start
--- 适用于已在 skynet.start 回调内的场景(如 Main.lua)
---@param handler table  命令处理表
function Dispatch.register(handler)
    Dispatch._setupDispatch(handler)
end

--- 内部: 设置 skynet.dispatch
---@param handler table
function Dispatch._setupDispatch(handler)
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

--- 动态注册命令
---@param cmd string
---@param fn function
function Dispatch:on(cmd, fn)
    self.handler[cmd] = fn
end

return Dispatch