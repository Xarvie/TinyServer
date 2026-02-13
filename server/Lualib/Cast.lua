-- lualib/Cast.lua
-- 全局仅cast，零call，类erlang消息传递
-- 所有服务间通信只用 lua 结构 (table)

local skynet = require "skynet"

---@class Cast
local Cast = {}

--- 向目标服务发送消息(fire-and-forget)
--- target 可以是 integer 地址 或 string 服务名，skynet.send 原生支持两者
---@param target integer|string  服务地址或名字
---@param cmd string             命令名
---@param ... any                参数
function Cast.send(target, cmd, ...)
    skynet.send(target, "lua", cmd, ...)
end

--- 向目标服务发送原始消息(用于转发)
---@param target integer  服务地址
---@param msg any         打包的消息
---@param sz integer      消息大小
function Cast.redirect(target, msg, sz)
    skynet.redirect(target, 0, "client", 0, msg, sz)
end

--- 广播给一组服务
---@param targets integer[]  服务地址列表
---@param cmd string         命令名
---@param ... any            参数
function Cast.broadcast(targets, cmd, ...)
    for _, addr in ipairs(targets) do
        skynet.send(addr, "lua", cmd, ...)
    end
end

return Cast
