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

---@class ModuleDescriptor
---@field modName  string          模块名(全局唯一，同目录名)
---@field deps     string[]        依赖的模块名列表
---@field class    table           模块类(含new/handlers/生命周期方法)
---@field order    integer|nil     拓扑排序后的执行顺序(init后填充)

---@class RouteEntry
---@field modName  string          目标模块名
---@field method   string          方法名(string key)

---@class ModuleManager
local M = {}

----------------------------------------------------------------
-- 内部状态(单例)
----------------------------------------------------------------
---@type table<string, ModuleDescriptor>  modName -> descriptor
local registry = {}

---@type string[]  拓扑排序后的模块名列表(初始化/触发顺序)
local sortedNames = {}

---@type table<integer, RouteEntry>  msgId -> { modName, method }
local router = {}

---@type boolean  是否已完成init
local initialized = false

--- 标准生命周期钩子名(按典型调用时序排列，仅做文档用途)
--- 模块可实现其中任意子集，管理器按sortedNames顺序调用
local LIFECYCLE_HOOKS = {
    "onDbInit",       -- 数据库数据加载完毕(data已挂载到entry)
    "onPlayerLogin",  -- 所有模块onDbInit完成后，玩家正式上线
    "onReconnect",    -- 断线重连(fd/gate更新后)
    "onNewDay",       -- 在线时跨天触发
    "onLevelUp",      -- 升级(可携带参数 oldLv, newLv)
    "onLogout",       -- 玩家登出/离线前(存盘前)
    "onShutdown",     -- 服务关闭前
}

----------------------------------------------------------------
-- 1. 模块注册
----------------------------------------------------------------

--- 注册一个业务模块
--- 通常由模块文件的顶层代码调用，或由scan自动完成
---@param desc table   { modName: string, deps?: string[] }
---@param class table  模块类(需提供 new(player) 构造函数)
function M.register(desc, class)
    assert(type(desc) == "table", "[ModuleManager] register: desc must be a table")
    assert(type(desc.modName) == "string" and #desc.modName > 0,
        "[ModuleManager] register: desc.modName required")
    assert(type(class) == "table",
        string.format("[ModuleManager] register: class for '%s' must be a table", desc.modName))
    assert(type(class.new) == "function",
        string.format("[ModuleManager] register: class '%s' must have new(player) constructor", desc.modName))

    if registry[desc.modName] then
        error(string.format("[ModuleManager] FATAL: duplicate module name '%s'", desc.modName))
    end

    registry[desc.modName] = {
        modName = desc.modName,
        deps    = desc.deps or {},
        class   = class,
        order   = nil,
    }

    skynet.error(string.format("[ModuleManager] registered module '%s' deps=[%s]",
        desc.modName, table.concat(desc.deps or {}, ",")))
end

----------------------------------------------------------------
-- 2. 自动发现(lfs扫描)
----------------------------------------------------------------

--- 判断文件名是否为有效模块文件
---@param fileName string
---@return boolean
local function isValidFile(fileName)
    -- 必须以.lua结尾
    if not fileName:match("%.lua$") then return false end
    -- 忽略以_开头的文件
    if fileName:match("^_") then return false end
    -- 忽略以.off.lua结尾的文件(软关闭)
    if fileName:match("%.off%.lua$") then return false end
    return true
end

--- 扫描 Logic/ 目录，自动发现并require所有业务模块
--- 规则:
---   - 遍历 baseDir 下的一级子目录
---   - 跳过 Player/ 目录(Player.lua不是业务模块)
---   - 在每个子目录中查找与目录名同名(大小写不敏感)的.lua文件
---   - require该文件，如果返回值包含 modName 字段则视为有效模块
---   - 有效模块自动注册到registry(如果模块内部未自行register)
---
--- 示例: Logic/Bag/Bag.lua -> require "Logic.Bag.Bag"
---
---@param baseDir string  扫描根目录(相对于工作目录)，默认 "Logic"
---  建议-7: baseDir 格式约束
---    - lfs 路径使用 "/" 拼接: baseDir .. "/" .. dirName
---    - require 路径使用 "." 拼接: baseDir .. "." .. dirName .. "." .. baseName
---    因此 baseDir 不能包含尾部 "/" 或 "."，也不能包含路径分隔符 "/"
---    (应使用 "Logic.Sub" 风格而非 "Logic/Sub")
---    下方做防御性规范化处理
function M.scan(baseDir)
    baseDir = baseDir or "Logic"

    -- 建议-7: 防御性规范化
    -- 去除尾部 / 或 .（防止 "Logic/" 或 "Logic." 导致拼接异常）
    baseDir = baseDir:gsub("[/%.]+$", "")
    if #baseDir == 0 then
        skynet.error("[ModuleManager] WARNING: empty baseDir after normalization")
        return
    end

    -- baseDir 用于两种拼接:
    --   lfs路径:     baseDir .. "/" .. dirName          (文件系统遍历)
    --   require路径:  baseDir .. "." .. dirName .. "." .. baseName  (Lua模块加载)
    -- 如果 baseDir 包含 "/"，require 路径会出错；包含 "."，lfs 路径会出错
    -- skynet 的 lua_path 通常将 "." 映射到 "/"，因此这里统一使用 "." 分隔的模块风格
    -- lfs 遍历时将 "." 替换为 "/" 作为文件系统路径
    local fsBaseDir = baseDir:gsub("%.", "/")

    local ok, iter, dir = pcall(lfs.dir, fsBaseDir)
    if not ok then
        skynet.error(string.format("[ModuleManager] WARNING: cannot scan '%s': %s", fsBaseDir, tostring(iter)))
        return
    end

    local discovered = 0
    for dirName in iter, dir do
        -- 跳过 . .. 和 Player 目录
        if dirName ~= "." and dirName ~= ".."
            and dirName:lower() ~= "player" then

            local dirPath = fsBaseDir .. "/" .. dirName  -- 建议-7: 文件系统路径
            local attr = lfs.attributes(dirPath)

            if attr and attr.mode == "directory" then
                -- 扫描子目录内的文件
                local dirNameLower = dirName:lower()
                for fileName in lfs.dir(dirPath) do
                    if isValidFile(fileName) then
                        local baseName = fileName:gsub("%.lua$", "")
                        -- 文件名(不含后缀)小写 == 目录名小写 -> 命中主模块文件
                        if baseName:lower() == dirNameLower then
                            local requirePath = baseDir .. "." .. dirName .. "." .. baseName  -- 建议-7: Lua模块路径
                            local reqOk, mod = pcall(require, requirePath)
                            if not reqOk then
                                skynet.error(string.format(
                                    "[ModuleManager] WARN: failed to require '%s': %s",
                                    requirePath, tostring(mod)))
                            elseif type(mod) == "table" and mod.modName then
                                -- 如果模块返回了合法描述但尚未自行注册，自动注册
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

--- 执行拓扑排序，生成 sortedNames
--- 检测循环依赖和缺失依赖，异常时阻止启动(error)
---@return string[]  排序后的模块名列表
local function topoSort()
    ---@type table<string, integer>
    local inDegree = {}
    ---@type table<string, string[]>  被依赖者 -> 依赖它的模块列表
    local dependents = {}

    for name, _ in pairs(registry) do
        inDegree[name] = 0
        dependents[name] = {}
    end

    for name, desc in pairs(registry) do
        for _, dep in ipairs(desc.deps) do
            if not registry[dep] then
                error(string.format(
                    "[ModuleManager] FATAL: module '%s' depends on '%s' which is not registered",
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
        local cur = queue[head]
        head = head + 1
        result[#result + 1] = cur

        local nexts = {}
        for _, dep in ipairs(dependents[cur]) do
            inDegree[dep] = inDegree[dep] - 1
            if inDegree[dep] == 0 then
                nexts[#nexts + 1] = dep
            end
        end
        table.sort(nexts)
        for _, n in ipairs(nexts) do
            queue[#queue + 1] = n
        end
    end

    local totalModules = 0
    for _ in pairs(registry) do totalModules = totalModules + 1 end

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

    local count = 0
    for _ in pairs(router) do count = count + 1 end
    skynet.error(string.format("[ModuleManager] router built: %d message routes", count))
end

----------------------------------------------------------------
-- 5. 初始化(scan之后调用)
----------------------------------------------------------------

function M.init()
    if initialized then
        skynet.error("[ModuleManager] WARNING: already initialized, skipping")
        return
    end

    local modCount = 0
    for _ in pairs(registry) do modCount = modCount + 1 end

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
-- 6. 挂载(为Player创建模块实例)
----------------------------------------------------------------

---@param player table  Player实例
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

---@param player table
---@param msgId  integer
---@param body   table
---@return boolean handled   是否找到路由并执行
---@return boolean modified  是否修改了数据(handler返回false表示只读)
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
    if fn then
        local ok, ret = pcall(fn, mod, body)
        if not ok then
            skynet.error(string.format(
                "[ModuleManager] dispatch error: %s.%s msgId=%d uid=%s: %s",
                route.modName, route.method, msgId,
                tostring(player.uid), tostring(ret)))
            -- BugFix BUG-10: handler异常时 modified=false
            return true, false
        end
        -- BugFix BUG-21: handler 显式返回 false 表示只读(未修改数据)
        -- 未返回值(nil)或返回 true 均视为有修改，向后兼容
        local modified = (ret ~= false)
        return true, modified
    end
    return false, false
end

----------------------------------------------------------------
-- 8. 生命周期触发
----------------------------------------------------------------

---@param event  string
---@param player table
---@param ...    any
function M.trigger(event, player, ...)
    assert(initialized, "[ModuleManager] must call init() before trigger()")
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
-- 9. 查询接口(调试/监控用)
----------------------------------------------------------------

function M.getModuleCount()
    local n = 0
    for _ in pairs(registry) do n = n + 1 end
    return n
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