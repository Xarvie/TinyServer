-- Login/IdService.lua
-- UID分配服务: 全服唯一可被 skynet.call 的服务
-- 设计: 启动时 cast DbService 读一次 → 内存自增 → 定期 cast DbService 回写
-- 本服务不直连 MongoDB，所有持久化走 DbService
--
-- 防crash重复机制(预留步长):
--   DbService 中存的是 ceiling = curPlayerId + STEP
--   crash重启后从 ceiling 继续, 中间最多浪费 STEP 个id, 但绝不重复
--   正常shutdown时写精确值, 无浪费
--
-- UID 位布局 (int32, 正数):
--   bit31      = 0         (符号位, 恒为0)
--   bit30~13   = serverId  (18位, [0, 262143])
--   bit12~0    = playerId  (13位, [1, 8191])
--   uid = (serverId << 13) | playerId
--
-- 优化: 记录上次写入的 ceiling，每 5 秒检测一次，仅在值变化时才写入 MongoDB

local skynet = require "skynet"
local Cast   = require "Cast"

----------------------------------------------------------------
-- 常量
----------------------------------------------------------------
local BITS_PLAYER   = 13
local MAX_PLAYER_ID = (1 << BITS_PLAYER) - 1   -- 8191
local MAX_SERVER_ID = (1 << 18) - 1             -- 262143
local STEP          = 200                        -- 预留步长, crash最多浪费200个id
local SAVE_INTERVAL = 5                          -- 定期检测间隔(秒)，改为5秒检测一次

----------------------------------------------------------------
-- 状态
----------------------------------------------------------------
local serverId         = 0
local curPlayerId      = 0   -- 当前已分配的最大 playerId
local ceiling          = 0   -- 当前计算的天花板值
local lastSavedCeiling = 0   -- 上次写入 MongoDB 的天花板值(用于检测变化)
local dbAddr           = 0   ---@type integer
local coordinator      = 0
local stopping         = false
local ready            = false  -- 收到 DbService 回传数据后置 true

----------------------------------------------------------------
-- 命令表
----------------------------------------------------------------
local CMD = {}

--- 分配一个全局唯一 uid (唯一的 call 接口)
---@return integer uid
function CMD.allocUid()
    assert(ready, "[IdService] not ready, data not loaded yet")

    curPlayerId = curPlayerId + 1

    if curPlayerId > MAX_PLAYER_ID then
        error(string.format("[IdService] FATAL: playerId=%d exceeds max %d for serverId=%d",
            curPlayerId, MAX_PLAYER_ID, serverId))
    end

    -- 触碰天花板: 推高并 cast DbService 持久化
    if curPlayerId > ceiling then
        ceiling = curPlayerId + STEP
        if ceiling > MAX_PLAYER_ID then
            ceiling = MAX_PLAYER_ID
        end
        -- 立即保存新的 ceiling
        Cast.send(dbAddr, "saveIdCounter", { serverId = serverId, cur = ceiling })
        lastSavedCeiling = ceiling  -- 更新已保存的值
    end

    return (serverId << BITS_PLAYER) | curPlayerId
end

--- DbService 回传 id_counter 数据(启动时一次性)
---@param result table  { cur: integer|nil }
function CMD.loadIdCounterResult(result)
    if result and result.cur then
        curPlayerId = math.tointeger(result.cur) or math.floor(result.cur)
    end

    -- 预留步长写入(防crash后重复)
    ceiling = curPlayerId + STEP
    if ceiling > MAX_PLAYER_ID then
        ceiling = MAX_PLAYER_ID
    end
    Cast.send(dbAddr, "saveIdCounter", { serverId = serverId, cur = ceiling })
    lastSavedCeiling = ceiling  -- 记录初始保存值

    ready = true
    skynet.error(string.format(
        "[IdService] ready | serverId=%d | allocated=%d/%d | remaining=%d",
        serverId, curPlayerId, MAX_PLAYER_ID, MAX_PLAYER_ID - curPlayerId))
end

--- 查询剩余可分配数量(监控用)
function CMD.remaining()
    return MAX_PLAYER_ID - curPlayerId
end

--- 优雅关闭: 精确回写(无 gap), 然后 ack
--- 注意: IdService 在 Shutdown phase2 关闭(早于 DbService 的 phase3),
---       确保此处的 saveIdCounter cast 能被 DbService 处理
function CMD.shutdown()
    stopping = true
    skynet.error(string.format("[IdService] shutdown, saving exact curPlayerId=%d", curPlayerId))
    Cast.send(dbAddr, "saveIdCounter", { serverId = serverId, cur = curPlayerId })
    lastSavedCeiling = curPlayerId  -- 更新最后保存值
    skynet.error("[IdService] shutdown complete")
    if coordinator > 0 then
        Cast.send(coordinator, "shutdownAck")
    end
end

--- 初始化(cast)
---@param cfg table  { dbAddr, coordinator }
function CMD.init(cfg)
    coordinator = cfg.coordinator or 0
    dbAddr      = cfg.dbAddr

    -- 向 DbService 请求加载 id_counter(一次性)
    Cast.send(dbAddr, "loadIdCounter", {
        serverId = serverId,
        idAddr   = skynet.self(),
    })

    -- 定期检测并保存: 每 5 秒检查一次，只有 ceiling 变化时才写入
    local function periodicSave()
        if stopping then return end
        skynet.timeout(SAVE_INTERVAL * 100, function()
            if stopping then return end
            periodicSave()  -- 先注册下一轮定时器
            
            -- 计算当前应有的 ceiling
            local newCeiling = curPlayerId + STEP
            if newCeiling > MAX_PLAYER_ID then
                newCeiling = MAX_PLAYER_ID
            end
            ceiling = newCeiling
            
            -- 仅在 ceiling 发生变化时才写入 MongoDB
            if ceiling ~= lastSavedCeiling then
                Cast.send(dbAddr, "saveIdCounter", { serverId = serverId, cur = ceiling })
                skynet.error(string.format(
                    "[IdService] ceiling changed: %d -> %d, saving to MongoDB (cur=%d)",
                    lastSavedCeiling, ceiling, curPlayerId))
                lastSavedCeiling = ceiling  -- 更新已保存的值
            else
                -- 可选: 输出调试日志，表明无需保存
                -- skynet.error(string.format(
                --     "[IdService] ceiling unchanged (%d), skip save (cur=%d)",
                --     ceiling, curPlayerId))
            end
        end)
    end
    periodicSave()
end

----------------------------------------------------------------
-- 启动
----------------------------------------------------------------
skynet.start(function()
    local Cfg = require "Config.Config"

    -- serverId 校验
    serverId = Cfg.serverId or 1
    assert(type(serverId) == "number" and serverId >= 0 and serverId <= MAX_SERVER_ID,
        string.format("[IdService] FATAL: serverId=%s out of range [0,%d]",
            tostring(serverId), MAX_SERVER_ID))

    -- dispatch: allocUid 走 call(有返回), 其余走 cast
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.error(string.format("[IdService] unknown cmd: %s", cmd))
            return
        end
        if cmd == "allocUid" then
            skynet.ret(skynet.pack(f(...)))
        else
            f(...)
        end
    end)
end)