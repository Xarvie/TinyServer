-- Agent/ModuleManager.lua
-- 模块管理器: 自动发现 · DAG拓扑排序 · O(1)路由 · 生命周期编排
-- 全局单例，AgentService init阶段调用一次 scan+init，运行时为每个Player mount/trigger/dispatch
--
-- 设计原则:
--   1. 模块通过目录结构自动发现(零配置)
--   2. 模块内部声明依赖(modName/deps/handlers)，管理器自动编排
--   3. 路由表扁平化(msgId -> handler)，O(1)分发
--   4. 生命周期按拓扑序触发，保证依赖先于被依赖者初始化

local skynet = require "skynet"
local lfs    = require "lfs"
local Cast   = require "Cast"

---@class ModuleDescriptor
---@field modName  string
---@field deps     string[]
---@field class    table
---@field order    integer|nil

---@class RouteEntry
---@field modName  string
---@field method   string

---@class ModuleManager
local M = {}

----------------------------------------------------------------
-- 内部状态(单例)
----------------------------------------------------------------
---@type table<string, ModuleDescriptor>
local registry = {}

---@type string[]  拓扑排序后的模块名列表
local sortedNames = {}

---@type table<integer, RouteEntry>
local router = {}

---@type boolean
local initialized = false

--- 标准生命周期钩子
local LIFECYCLE_HOOKS = {
    "onDbInit",
    "onPlayerLogin",
    "onReconnect",
    "onNewDay",
    "onLevelUp",
    "onLogout",
    "onShutdown",
}

---@type table<string, true>
local LIFECYCLE_HOOK_SET = {}
for _, name in ipairs(LIFECYCLE_HOOKS) do
    LIFECYCLE_HOOK_SET[name] = true
end

----------------------------------------------------------------
-- 1. 模块注册
----------------------------------------------------------------

---@param desc  table   { modName: string, deps?: string[] }
---@param class table   模块类(需提供 new(player) 构造函数)
function M.register(desc, class)
    assert(type(desc) == "table", "[ModuleManager] register: desc must be a table")
    assert(type(desc.modName) == "string" and #desc.modName > 0,
        "[ModuleManager] register: desc.modName required")
    assert(type(class) == "table",
        string.format("[ModuleManager] register: class for '%s' must be a table", desc.modName))
    assert(type(class.new) == "function",
        string.format("[ModuleManager] register: class '%s' must have new(player)", desc.modName))

    if registry[desc.modName] then
        error(string.format("[ModuleManager] FATAL: duplicate module name '%s'", desc.modName))
    end

    registry[desc.modName] = {
        modName = desc.modName,
        deps    = desc.deps or {},
        class   = class,
        order   = nil,
    }

    skynet.error(string.format("[ModuleManager] registered '%s' deps=[%s]",
        desc.modName, table.concat(desc.deps or {}, ",")))
end

----------------------------------------------------------------
-- 2. 自动发现(lfs扫描)
----------------------------------------------------------------

local function isValidFile(fileName)
    if not fileName:match("%.lua$") then return false end
    if fileName:match("^_") then return false end
    if fileName:match("%.off%.lua$") then return false end
    return true
end

--- 扫描 baseDir 目录，自动发现并require所有业务模块
--- 规则: 遍历一级子目录(跳过Player/)，查找与目录同名的.lua文件
---
--- baseDir 格式约束:
---   lfs路径用 "/" 拼接，require路径用 "." 拼接
---   baseDir 使用 "." 分隔的模块风格(如 "Logic")
---   内部自动转换为文件系统路径
---@param baseDir string  默认 "Logic"
function M.scan(baseDir)
    baseDir = baseDir or "Logic"
    baseDir = baseDir:gsub("[/%.]+$", "")
    if #baseDir == 0 then
        skynet.error("[ModuleManager] WARNING: empty baseDir after normalization")
        return
    end

    local fsBaseDir = baseDir:gsub("%.", "/")

    local baseAttr = lfs.attributes(fsBaseDir)
    if not baseAttr or baseAttr.mode ~= "directory" then
        skynet.error(string.format("[ModuleManager] WARNING: cannot scan '%s': not a directory", fsBaseDir))
        return
    end

    local discovered = 0
    for dirName in lfs.dir(fsBaseDir) do
        if dirName ~= "." and dirName ~= ".."
            and dirName:lower() ~= "player" then

            local dirPath = fsBaseDir .. "/" .. dirName
            local attr = lfs.attributes(dirPath)

            if attr and attr.mode == "directory" then
                local dirNameLower = dirName:lower()
                for fileName in lfs.dir(dirPath) do
                    if isValidFile(fileName) then
                        local baseName = fileName:gsub("%.lua$", "")
                        if baseName:lower() == dirNameLower then
                            local requirePath = baseDir .. "." .. dirName .. "." .. baseName
                            local reqOk, mod = pcall(require, requirePath)
                            if not reqOk then
                                skynet.error(string.format(
                                    "[ModuleManager] WARN: failed to require '%s': %s",
                                    requirePath, tostring(mod)))
                            elseif type(mod) == "table" and mod.modName then
                                if not registry[mod.modName] then
                                    M.register({
                                        modName = mod.modName,
                                        deps    = mod.deps or {},
                                    }, mod)
                                end
                                discovered = discovered + 1
                            else
                                skynet.error(string.format(
                                    "[ModuleManager] WARN: '%s' missing modName field, skipped",
                                    requirePath))
                            end
                        end
                    end
                end
            end
        end
    end

    skynet.error(string.format("[ModuleManager] scan complete: %d modules discovered", discovered))
end

----------------------------------------------------------------
-- 3. DAG拓扑排序(Kahn's Algorithm)
----------------------------------------------------------------

---@return string[]
local function topoSort()
    ---@type table<string, integer>
    local inDegree = {}
    ---@type table<string, string[]>
    local dependents = {}

    for name, _ in pairs(registry) do
        inDegree[name] = 0
        dependents[name] = {}
    end

    for name, desc in pairs(registry) do
        for _, dep in ipairs(desc.deps) do
            if not registry[dep] then
                error(string.format(
                    "[ModuleManager] FATAL: module '%s' depends on unregistered '%s'",
                    name, dep))
            end
            inDegree[name] = inDegree[name] + 1
            dependents[dep][#dependents[dep] + 1] = name
        end
    end

    -- Kahn's BFS
    local queue = {}
    local head = 1
    local result = {}

    -- 确定性排序: 入度为0的节点按名字排序入队
    local zeroNodes = {}
    for name, deg in pairs(inDegree) do
        if deg == 0 then
            zeroNodes[#zeroNodes + 1] = name
        end
    end
    table.sort(zeroNodes)
    for _, name in ipairs(zeroNodes) do
        queue[#queue + 1] = name
    end

    while head <= #queue do
        local curr = queue[head]
        head = head + 1
        result[#result + 1] = curr

        local nexts = {}
        for _, dep in ipairs(dependents[curr]) do
            inDegree[dep] = inDegree[dep] - 1
            if inDegree[dep] == 0 then
                nexts[#nexts + 1] = dep
            end
        end
        table.sort(nexts)
        for _, name in ipairs(nexts) do
            queue[#queue + 1] = name
        end
    end

    local totalModules = Cast.tableSize(registry)
    if #result ~= totalModules then
        local sorted = {}
        for _, name in ipairs(result) do sorted[name] = true end
        local cycleNodes = {}
        for name, _ in pairs(registry) do
            if not sorted[name] then
                cycleNodes[#cycleNodes + 1] = name
            end
        end
        error(string.format(
            "[ModuleManager] FATAL: circular dependency detected among: [%s]",
            table.concat(cycleNodes, ", ")))
    end

    for i, name in ipairs(result) do
        registry[name].order = i
    end

    return result
end

----------------------------------------------------------------
-- 4. 路由表构建
----------------------------------------------------------------

local function buildRouter()
    router = {}
    for modName, desc in pairs(registry) do
        local handlers = desc.class.handlers
        if handlers then
            for msgId, method in pairs(handlers) do
                if router[msgId] then
                    error(string.format(
                        "[ModuleManager] FATAL: msgId %d route conflict: '%s.%s' vs '%s.%s'",
                        msgId,
                        router[msgId].modName, router[msgId].method,
                        modName, method))
                end
                if type(desc.class[method]) ~= "function" then
                    error(string.format(
                        "[ModuleManager] FATAL: module '%s' handler '%s' for msgId %d is not a function",
                        modName, method, msgId))
                end
                router[msgId] = {
                    modName = modName,
                    method  = method,
                }
            end
        end
    end

    skynet.error(string.format("[ModuleManager] router built: %d message routes",
        Cast.tableSize(router)))
end

----------------------------------------------------------------
-- 5. 初始化(scan之后调用)
----------------------------------------------------------------

function M.init()
    if initialized then
        skynet.error("[ModuleManager] WARNING: already initialized, skipping")
        return
    end

    local modCount = Cast.tableSize(registry)
    if modCount == 0 then
        skynet.error("[ModuleManager] WARNING: no modules registered")
        sortedNames = {}
        initialized = true
        return
    end

    sortedNames = topoSort()
    skynet.error(string.format("[ModuleManager] topo order: [%s]",
        table.concat(sortedNames, " -> ")))

    buildRouter()

    initialized = true
    skynet.error(string.format("[ModuleManager] init complete: %d modules ready", modCount))
end

----------------------------------------------------------------
-- 6. 挂载/卸载
----------------------------------------------------------------

---@param player table
function M.mount(player)
    assert(initialized, "[ModuleManager] must call init() before mount()")
    for _, modName in ipairs(sortedNames) do
        local desc = registry[modName]
        local inst = desc.class.new(player)
        player[modName] = inst
    end
end

---@param player table
function M.unmount(player)
    for _, modName in ipairs(sortedNames) do
        player[modName] = nil
    end
end

----------------------------------------------------------------
-- 7. 消息分发(O(1))
----------------------------------------------------------------

--- handler 返回 false 表示只读(未修改数据)，nil/true 视为有修改
---@param player table
---@param msgId  integer
---@param body   table
---@return boolean handled
---@return boolean modified
function M.dispatch(player, msgId, body)
    local route = router[msgId]
    if not route then
        return false, false
    end
    local mod = player[route.modName]
    if not mod then
        skynet.error(string.format(
            "[ModuleManager] dispatch: module '%s' not mounted on player %s",
            route.modName, tostring(player.uid)))
        return false, false
    end
    local fn = mod[route.method]
    if not fn then
        return false, false
    end
    local ok, ret = pcall(fn, mod, body)
    if not ok then
        skynet.error(string.format(
            "[ModuleManager] dispatch error: %s.%s msgId=%d uid=%s: %s",
            route.modName, route.method, msgId,
            tostring(player.uid), tostring(ret)))
        return true, false
    end
    -- handler 显式返回 false 表示只读
    return true, (ret ~= false)
end

----------------------------------------------------------------
-- 8. 生命周期触发
----------------------------------------------------------------

---@param event  string
---@param player table
---@param ...    any
function M.trigger(event, player, ...)
    assert(initialized, "[ModuleManager] must call init() before trigger()")
    if not LIFECYCLE_HOOK_SET[event] then
        skynet.error(string.format(
            "[ModuleManager] WARNING: trigger unknown hook '%s', check for typo", event))
    end
    for _, modName in ipairs(sortedNames) do
        local mod = player[modName]
        if mod then
            local fn = mod[event]
            if type(fn) == "function" then
                local ok, err = pcall(fn, mod, ...)
                if not ok then
                    skynet.error(string.format(
                        "[ModuleManager] trigger error: %s.%s uid=%s: %s",
                        modName, event, tostring(player.uid), tostring(err)))
                end
            end
        end
    end
end

---@param event  string
---@param player table
---@param ...    any
function M.triggerReverse(event, player, ...)
    assert(initialized, "[ModuleManager] must call init() before triggerReverse()")
    if not LIFECYCLE_HOOK_SET[event] then
        skynet.error(string.format(
            "[ModuleManager] WARNING: triggerReverse unknown hook '%s', check for typo", event))
    end
    for i = #sortedNames, 1, -1 do
        local modName = sortedNames[i]
        local mod = player[modName]
        if mod then
            local fn = mod[event]
            if type(fn) == "function" then
                local ok, err = pcall(fn, mod, ...)
                if not ok then
                    skynet.error(string.format(
                        "[ModuleManager] triggerReverse error: %s.%s uid=%s: %s",
                        modName, event, tostring(player.uid), tostring(err)))
                end
            end
        end
    end
end

----------------------------------------------------------------
-- 9. 查询接口(调试/监控)
----------------------------------------------------------------

function M.getModuleCount()
    return Cast.tableSize(registry)
end

function M.getSortedNames()
    local copy = {}
    for i, v in ipairs(sortedNames) do copy[i] = v end
    return copy
end

function M.getRoutes()
    local copy = {}
    for msgId, route in pairs(router) do
        copy[msgId] = { modName = route.modName, method = route.method }
    end
    return copy
end

function M.hasRoute(msgId)
    return router[msgId] ~= nil
end

function M.getDescriptor(modName)
    return registry[modName]
end

function M.getLifecycleHooks()
    local copy = {}
    for i, v in ipairs(LIFECYCLE_HOOKS) do copy[i] = v end
    return copy
end

return M