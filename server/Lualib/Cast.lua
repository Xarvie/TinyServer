-- lualib/Cast.lua
-- 基础设施: 消息传递 + 通用工具
-- 全局仅cast，零call，类erlang消息传递

local skynet = require "skynet"

---@class Cast
local Cast = {}

----------------------------------------------------------------
-- 消息传递
----------------------------------------------------------------

--- 向目标服务发送消息(fire-and-forget)
---@param target integer|string  服务地址或名字
---@param cmd string             命令名
---@param ... any                参数
function Cast.send(target, cmd, ...)
    skynet.send(target, "lua", cmd, ...)
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

----------------------------------------------------------------
-- 通用工具(避免各文件重复实现)
----------------------------------------------------------------

--- O(n) 计算 hash table 大小
---@param t table
---@return integer
function Cast.tableSize(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- 判断 hash table 是否为空(O(1))
---@param t table
---@return boolean
function Cast.tableEmpty(t)
    return next(t) == nil
end

--- 周期定时器(消除各服务重复的伪递归 self-scheduling 模式)
--- 返回值无意义，调用即启动，stopFn 返回 true 时自动终止
---@param intervalSec number     间隔(秒)
---@param stopFn      function   () -> boolean, 返回true时停止
---@param taskFn      function   实际执行的任务
function Cast.setInterval(intervalSec, stopFn, taskFn)
    local function tick()
        if stopFn() then return end
        skynet.timeout(intervalSec * 100, function()
            if stopFn() then return end
            tick()    -- 先注册下一轮，防止任务耗时拉长间隔
            taskFn()
        end)
    end
    tick()
end

return Cast