--------------------------------------------------------------
-- gate_service.lua
-- Gate 中心路由服务 (M3: 完整版)
-- 支持 Agent / Inter / Cross 路由 + 跨服授权
--------------------------------------------------------------
local skynet    = require "skynet"
local socket    = require "skynet.socket"
local codec     = require "codec"
local protocol  = require "protocol"
local game_conf = require "game_config"
local ticket    = require "ticket"
local log       = require "log"

local CMD = {}

local db_addr, inter_addr, cross_mgr_addr, logger_addr

-- fd -> { uid, agent_addr, ip, connect_time, _logging_in }
local fd_map = {}
-- uid -> { fd, agent_addr, login_time }
local uid_map = {}
-- fd -> read buffer
local read_buf = {}
-- uid -> { authorized, cross_type, ticket, expire_time }
local cross_auth = {}

--------------------------------------------------------------
-- TCP 工具
--------------------------------------------------------------
local function extract_frames(fd)
    local buf = read_buf[fd]
    if not buf or #buf < 2 then return nil end
    local frames = {}
    while #buf >= 2 do
        local hi, lo = buf:byte(1, 2)
        local plen = hi * 256 + lo
        if plen > codec.MAX_FRAME_LEN then return nil, "too_large" end
        if #buf < 2 + plen then break end
        frames[#frames+1] = buf:sub(3, 2 + plen)
        buf = buf:sub(3 + plen)
    end
    read_buf[fd] = buf
    return frames
end

local function send_to_fd(fd, frame)
    if fd and fd_map[fd] then pcall(socket.write, fd, frame) end
end

local function on_disconnect(fd)
    local conn = fd_map[fd]
    if not conn then return end
    log.info("disconnect fd:", fd, "uid:", conn.uid or "?")
    if conn.uid and conn.agent_addr then
        local u = conn.uid
        skynet.send(conn.agent_addr, "lua", "on_disconnect", u)
        cross_auth[u] = nil
        skynet.timeout(10, function() uid_map[u] = nil end)
    end
    read_buf[fd] = nil
    fd_map[fd] = nil
    socket.close(fd)
end

--------------------------------------------------------------
-- 登录流程
--------------------------------------------------------------
local function handle_login(fd, pid, msg_data)
    local conn = fd_map[fd]
    if not conn or conn._logging_in then return end
    conn._logging_in = true

    local uid = msg_data and msg_data.uid
    if not uid or type(uid) ~= "number" then
        local f = codec.encode(5001001, { code = 1, msg = "invalid uid" })
        if f then send_to_fd(fd, f) end
        conn._logging_in = false
        return
    end

    log.info("login uid:", uid, "fd:", fd)

    -- 踢旧连接
    if uid_map[uid] then
        local old = uid_map[uid]
        if old.agent_addr then
            skynet.send(old.agent_addr, "lua", "on_disconnect", uid)
        end
        if old.fd and fd_map[old.fd] then
            local kf = codec.encode(5001099, { code = 99, msg = "kicked" })
            if kf then send_to_fd(old.fd, kf) end
            on_disconnect(old.fd)
        end
        uid_map[uid] = nil
        cross_auth[uid] = nil
    end

    local ok, db_res = pcall(skynet.call, db_addr, "lua", "load_player", uid)
    if not ok or not db_res then
        local f = codec.encode(5001001, { code = 2, msg = "db error" })
        if f then send_to_fd(fd, f) end
        conn._logging_in = false
        return
    end

    local agent = skynet.newservice("agent_service")
    local iok, ierr = pcall(skynet.call, agent, "lua", "init", uid, skynet.self(), db_res)
    if not iok then
        log.error("agent init fail:", ierr)
        skynet.send(agent, "lua", "force_exit")
        local f = codec.encode(5001001, { code = 3, msg = "agent error" })
        if f then send_to_fd(fd, f) end
        conn._logging_in = false
        return
    end

    conn.uid = uid
    conn.agent_addr = agent
    conn._logging_in = false
    uid_map[uid] = { fd = fd, agent_addr = agent, login_time = os.time() }
    skynet.send(agent, "lua", "set_client_fd", fd)

    log.info("login ok uid:", uid, "agent:", skynet.address(agent))
    log.flow("LOGIN", { uid = uid, ip = conn.ip, time = os.time() })
end

--------------------------------------------------------------
-- 数据到达
--------------------------------------------------------------
local function on_data(fd, data)
    if not fd_map[fd] then return end
    read_buf[fd] = (read_buf[fd] or "") .. data
    local frames, err = extract_frames(fd)
    if err then on_disconnect(fd); return end
    if not frames then return end

    for _, payload in ipairs(frames) do
        local pid, msg, derr = codec.decode(payload)
        if derr then goto cont end
        if not protocol.is_c2s(pid) then goto cont end
        local _, mid, _, perr = protocol.parse(pid)
        if perr then goto cont end

        local conn = fd_map[fd]
        if not conn.uid then
            if mid ~= 1 then goto cont end
            handle_login(fd, pid, msg)
        else
            if conn.agent_addr then
                skynet.send(conn.agent_addr, "lua", "handle_c2s", conn.uid, pid, msg)
            end
        end
        ::cont::
    end
end

--------------------------------------------------------------
-- 新连接
--------------------------------------------------------------
local function on_connect(fd, addr)
    if not fd then return end
    local ip = addr:match("([^:]+)")
    log.info("connect fd:", fd, "from:", addr)

    local n = 0; for _ in pairs(fd_map) do n = n + 1 end
    if n >= game_conf.gate.max_connections then socket.close(fd); return end

    fd_map[fd] = { uid = nil, agent_addr = nil, ip = ip, connect_time = os.time() }
    read_buf[fd] = ""
    socket.start(fd)

    skynet.fork(function()
        while fd_map[fd] do
            local d = socket.read(fd)
            if not d then on_disconnect(fd); return end
            on_data(fd, d)
        end
    end)
end

--------------------------------------------------------------
-- CMD
--------------------------------------------------------------

function CMD.init(_, db, inter, cross_mgr, logger)
    db_addr = db
    inter_addr = inter
    cross_mgr_addr = cross_mgr
    logger_addr = logger
    log.info("Gate init DB:", skynet.address(db_addr),
             "Inter:", skynet.address(inter_addr),
             "CrossMgr:", cross_mgr_addr and skynet.address(cross_mgr_addr) or "nil",
             "Logger:", logger_addr and skynet.address(logger_addr) or "nil")

    local h, p = game_conf.gate.host, game_conf.gate.port
    local lfd = socket.listen(h, p)
    log.info("TCP listen", h .. ":" .. p)
    socket.start(lfd, on_connect)
    return true
end

function CMD.forward_to_client(_, uid, frame)
    local info = uid_map[uid]
    if info and info.fd then send_to_fd(info.fd, frame) end
end

--- Agent 路由请求 (M3: Inter + Cross + Auth)
function CMD.agent_route_request(source, uid, route_type, ...)
    if route_type == "RouteToInter" then
        if inter_addr then
            local func_name, data = ...
            skynet.send(inter_addr, "lua", "handle_request", uid, func_name, data)
        else
            log.warn("Inter not available")
        end

    elseif route_type == "RouteToCross" then
        if not cross_mgr_addr then
            log.warn("CrossManager not available")
            return
        end
        local cross_type, func_name, data = ...
        -- 检查授权
        local auth = cross_auth[uid]
        if not auth or not auth.authorized or auth.cross_type ~= cross_type then
            log.warn("Cross unauthorized uid:", uid, "type:", cross_type)
            return
        end
        -- 检查过期
        if os.time() > (auth.expire_time or 0) then
            log.warn("Cross auth expired uid:", uid)
            cross_auth[uid] = nil
            return
        end
        -- 附带 ticket 转发
        data = data or {}
        data.ticket = auth.ticket
        skynet.send(cross_mgr_addr, "lua", "route_to_cross",
                    uid, cross_type, func_name, data)

    elseif route_type == "RequestCrossAuth" then
        if not cross_mgr_addr then
            log.warn("CrossManager not available for auth")
            return
        end
        local cross_type, player_info = ...
        -- 生成凭证
        local tk = ticket.generate(uid, cross_type)
        local expire = game_conf.cross.ticket_expire or 3600
        cross_auth[uid] = {
            authorized  = true,
            cross_type  = cross_type,
            ticket      = tk,
            expire_time = os.time() + expire,
        }
        log.info("Cross auth granted uid:", uid, "type:", cross_type)
        log.flow("CROSS_AUTH", { uid = uid, cross_type = cross_type })

        -- 直接将玩家信息 + 凭证发给 CrossManager
        local join_data = player_info or {}
        join_data.ticket = tk
        join_data.uid = uid
        -- 确定要调用的 Cross 函数
        local type_map = game_conf.cross.type_map or {}
        local mapping = type_map[cross_type]
        local func_name = "PvpOnMatchJoin"  -- 默认
        if mapping and mapping.module then
            -- 约定: {Module}OnMatchJoin, 首字母大写
            local cap = mapping.module:sub(1,1):upper() .. mapping.module:sub(2)
            func_name = cap .. "OnMatchJoin"
        end
        skynet.send(cross_mgr_addr, "lua", "route_to_cross",
                    uid, cross_type, func_name, join_data)
    else
        log.error("unknown route:", route_type)
    end
end

--- Inter/Cross → Gate → Agent (函数名回调)
function CMD.route_to_agent(_, uid, func_name, data)
    local info = uid_map[uid]
    if info and info.agent_addr then
        skynet.send(info.agent_addr, "lua", "handle_cmd", uid, func_name, data)
    end
end

--- 广播给多个 Agent
function CMD.broadcast(_, uid_list, func_name, data)
    if not uid_list then return end
    local batch = game_conf.inter.broadcast_batch_size or 50
    local delay = game_conf.inter.broadcast_batch_delay or 5
    for i, uid in ipairs(uid_list) do
        local info = uid_map[uid]
        if info and info.agent_addr then
            skynet.send(info.agent_addr, "lua", "handle_cmd", uid, func_name, data)
        end
        if i % batch == 0 and i < #uid_list then skynet.sleep(delay) end
    end
end

--- 广播帧到客户端 (直接下发, 不经 Agent)
function CMD.broadcast_frame(_, uid_list, frame)
    if not uid_list or not frame then return end
    local batch = game_conf.inter.broadcast_batch_size or 50
    local delay = game_conf.inter.broadcast_batch_delay or 5
    for i, uid in ipairs(uid_list) do
        local info = uid_map[uid]
        if info and info.fd then send_to_fd(info.fd, frame) end
        if i % batch == 0 and i < #uid_list then skynet.sleep(delay) end
    end
end

--- 保存请求
function CMD.request_save(_, uid, dirty_map)
    if db_addr and dirty_map then
        skynet.send(db_addr, "lua", "save_player", uid, dirty_map)
    end
end

function CMD.request_full_save(_, uid, all_data)
    if db_addr and all_data then
        skynet.send(db_addr, "lua", "save_player_full", uid, all_data)
    end
end

function CMD.agent_exited(source, uid)
    if uid_map[uid] and uid_map[uid].agent_addr == source then
        uid_map[uid] = nil
        cross_auth[uid] = nil
    end
end

--- 获取所有在线 UID
function CMD.get_online_uids(_)
    local uids = {}
    for uid in pairs(uid_map) do uids[#uids+1] = uid end
    return uids
end

--- 热更新指令
function CMD.hotreload(_, module_name, module_type)
    local conf = game_conf.hotreload
    for _, forbidden in ipairs(conf.forbidden_suffixes) do
        if module_type == forbidden:sub(2) then
            return false, "forbidden to reload " .. module_type .. " modules"
        end
    end

    if module_type == "agent" then
        for uid, info in pairs(uid_map) do
            if info.agent_addr then
                skynet.send(info.agent_addr, "lua", "hotreload", module_name, module_type)
            end
        end
        return true, "reload broadcast to all agents"
    elseif module_type == "inter" then
        if inter_addr then
            return skynet.call(inter_addr, "lua", "hotreload", module_name)
        end
        return false, "inter not available"
    elseif module_type == "cross" then
        if cross_mgr_addr then
            return skynet.call(cross_mgr_addr, "lua", "hotreload", module_name)
        end
        return false, "cross manager not available"
    end

    return false, "unsupported type: " .. module_type
end

--- 查询跨服授权状态
function CMD.get_cross_auth(_, uid)
    return cross_auth[uid]
end

--- 清理过期授权 (定时调用)
local function cleanup_expired_auth()
    local now = os.time()
    local removed = 0
    for uid, auth in pairs(cross_auth) do
        if auth.expire_time and now > auth.expire_time then
            cross_auth[uid] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        log.info("Cleaned", removed, "expired cross auths")
    end
    skynet.timeout(6000, cleanup_expired_auth)  -- 每 60 秒清理
end

--------------------------------------------------------------
-- 分发
--------------------------------------------------------------
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session ~= 0 then skynet.ret(skynet.pack(f(source, ...)))
            else f(source, ...) end
        else
            log.error("Gate unknown cmd:", cmd)
        end
    end)
    -- 启动过期清理定时器
    skynet.timeout(6000, cleanup_expired_auth)
    log.info("Gate service loaded (M3)")
end)