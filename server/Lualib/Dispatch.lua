-- lualib/Dispatch.lua
-- 极简命令分发器，所有服务继承此范式
-- 约定: handler中每个函数对应一个cmd，纯cast无返回
--
-- 使用方式(二选一):
--
--   方式A (推荐): 服务无额外初始化需求时，直接启动
--     Dispatch.start(handler)
--     -- 等价于 skynet.start + 注册dispatch，文件末尾调用即可
--
--   方式B: 服务需在 skynet.start 中做额外初始化(如连接DB)后再注册dispatch
--     skynet.start(function()
--         -- ... 额外初始化 ...
--         Dispatch.register(handler)
--     end)
--
-- Phase1-Fix: 统一API语义，消除 new() 返回实例但极少使用实例方法的困惑
--   new() 保留向后兼容，内部委托给 start()

local skynet = require "skynet"

---@class Dispatch
local Dispatch = {}
Dispatch.__index = Dispatch

--- 内部: 设置 skynet.dispatch (pcall保护每条消息)
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

--- 【推荐】启动服务并注册消息分发
--- 包含 skynet.start()，适用于无额外初始化需求的服务
--- 在文件末尾调用: Dispatch.start(handler)
---@param handler table  命令处理表 { cmdName = function(source, ...) end }
function Dispatch.start(handler)
    skynet.start(function()
        Dispatch._setupDispatch(handler)
    end)
end

--- 仅注册handler到skynet.dispatch，不调用skynet.start
--- 适用于已在 skynet.start 回调内的场景(如 DbService, Main.lua)
---@param handler table  命令处理表
function Dispatch.register(handler)
    Dispatch._setupDispatch(handler)
end

--- @deprecated 向后兼容，推荐改用 Dispatch.start(handler)
--- 返回的实例仅在需要动态注册命令(:on)时有用
---@param handler table  命令处理表
---@return Dispatch
function Dispatch.new(handler)
    local self = setmetatable({}, Dispatch)
    self.handler = handler or {}
    Dispatch.start(self.handler)
    return self
end

--- 动态注册命令(需通过 new() 创建实例后使用)
---@param cmd string
---@param fn function
function Dispatch:on(cmd, fn)
    self.handler[cmd] = fn
end

return Dispatch