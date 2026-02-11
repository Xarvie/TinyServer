--------------------------------------------------------------
-- test_full_flow.lua — M1+M2+M3 全架构集成测试
-- 独立运行: lua test/test_full_flow.lua
-- 依赖: luasocket, cjson
--------------------------------------------------------------
local socket = require "socket"
local json   = require "cjson.safe"

local HOST, PORT = "127.0.0.1", 8888
local pass_count, fail_count = 0, 0

local function log(tag, ...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end
    print(string.format("[%s][%s] %s", os.date("%H:%M:%S"), tag, table.concat(p, " ")))
end

local function encode(pid, data)
    local payload = json.encode({ id = pid, data = data or {} })
    local len = #payload
    return string.char(math.floor(len/256), len%256) .. payload
end

local function read_frame(conn, timeout)
    conn:settimeout(timeout or 5)
    local hdr, err = conn:receive(2)
    if not hdr then return nil, err end
    local plen = hdr:byte(1)*256 + hdr:byte(2)
    local body, err2 = conn:receive(plen)
    if not body then return nil, err2 end
    return json.decode(body)
end

local function request(conn, pid, data)
    conn:send(encode(pid, data))
    log("SEND", string.format("pid=%d", pid))
    local resp, err = read_frame(conn)
    if resp then
        log("RECV", string.format("pid=%d code=%s",
            resp.id or 0, resp.data and resp.data.code or "?"))
    else
        log("ERR", err or "no response")
    end
    return resp
end

local function check(name, ok)
    if ok then
        pass_count = pass_count + 1
        log("PASS", name)
    else
        fail_count = fail_count + 1
        log("FAIL", name)
    end
end

local function read_push(conn, timeout)
    return read_frame(conn, timeout or 1)
end

local function connect_and_login(uid)
    local conn, err = socket.connect(HOST, PORT)
    if not conn then return nil, err end
    local resp = request(conn, 1001001, { uid = uid })
    if not resp or not resp.data or resp.data.code ~= 0 then
        conn:close()
        return nil, "login failed"
    end
    return conn
end

--------------------------------------------------------------
-- TEST 1: M1 基础链路
--------------------------------------------------------------
local function test_m1_basic()
    log("TEST", "===== M1: Basic Flow =====")
    local conn = connect_and_login(10001)
    check("login", conn ~= nil)
    if not conn then return end

    local r = request(conn, 1099001, { msg = "hello", num = 42 })
    check("echo", r and r.data and r.data.code == 0)

    r = request(conn, 1099002, { t = os.time() })
    check("ping", r and r.data and r.data.code == 0)

    r = request(conn, 1001002, {})
    check("base_info", r and r.data and r.data.code == 0)

    r = request(conn, 1001003, { nickname = "TestHero" })
    check("set_nickname", r and r.data and r.data.code == 0)

    r = request(conn, 1001002, {})
    check("nickname_saved", r and r.data and r.data.data and r.data.data.nickname == "TestHero")

    r = request(conn, 1088001, {})
    check("unknown_module_rejected", r and r.data and r.data.code == -1)

    conn:close()
    socket.sleep(2)

    conn = connect_and_login(10001)
    check("reconnect", conn ~= nil)
    if conn then
        r = request(conn, 1001002, {})
        check("data_persisted",
            r and r.data and r.data.data and
            r.data.data.nickname == "TestHero" and
            r.data.data.login_count >= 2)
        conn:close()
    end
end

--------------------------------------------------------------
-- TEST 2: M2 背包系统
--------------------------------------------------------------
local function test_m2_bag()
    log("TEST", "===== M2: Bag System =====")
    local conn = connect_and_login(20001)
    check("bag_login", conn ~= nil)
    if not conn then return end

    local r = request(conn, 1002001, {})
    check("bag_empty", r and r.data and r.data.code == 0 and r.data.data and #r.data.data.items == 0)

    r = request(conn, 1002004, { item_id = 1001, count = 10 })
    check("add_item", r and r.data and r.data.code == 0)

    r = request(conn, 1002004, { item_id = 1002, count = 5 })
    check("add_item2", r and r.data and r.data.code == 0)

    r = request(conn, 1002001, {})
    check("bag_has_items", r and r.data and r.data.code == 0 and r.data.data and r.data.data.used_slots == 2)

    r = request(conn, 1002002, { item_id = 1001, count = 3 })
    check("use_item", r and r.data and r.data.code == 0)

    r = request(conn, 1002003, { item_id = 1002, count = 2 })
    check("sell_item", r and r.data and r.data.code == 0 and r.data.data and r.data.data.gold == 20)

    r = request(conn, 1002002, { item_id = 1001, count = 999 })
    check("use_insufficient", r and r.data and r.data.code == 2)

    conn:close()
    socket.sleep(2)

    conn = connect_and_login(20001)
    if conn then
        r = request(conn, 1002001, {})
        check("bag_persisted", r and r.data and r.data.code == 0 and r.data.data and #r.data.data.items > 0)
        conn:close()
    end
end

--------------------------------------------------------------
-- TEST 3: M2 排行榜 (需要 Inter)
--------------------------------------------------------------
local function test_m2_rank()
    log("TEST", "===== M2: Rank System =====")

    local connA = connect_and_login(30001)
    check("rankA_login", connA ~= nil)
    if not connA then return end

    local connB = connect_and_login(30002)
    check("rankB_login", connB ~= nil)
    if not connB then return end

    local connC = connect_and_login(30003)
    check("rankC_login", connC ~= nil)
    if not connC then return end

    local r = request(connA, 1006002, { score = 100 })
    check("A_submit", r and r.data and r.data.code == 0)
    socket.sleep(0.5)
    local pushA = read_push(connA)
    check("A_rank_push", pushA and pushA.id == 8006001)

    r = request(connB, 1006002, { score = 200 })
    check("B_submit", r and r.data and r.data.code == 0)
    socket.sleep(0.5)

    r = request(connC, 1006002, { score = 150 })
    check("C_submit", r and r.data and r.data.code == 0)
    socket.sleep(0.5)

    r = request(connA, 1006001, {})
    check("A_get_rank", r and r.data and r.data.code == 0)
    socket.sleep(0.5)

    local rankResult = read_push(connA)
    if rankResult and rankResult.id == 5006001 and rankResult.data then
        local list = rankResult.data.list
        if list and #list >= 3 then
            check("rank_order",
                list[1].uid == 30002 and
                list[2].uid == 30003 and
                list[3].uid == 30001)
        else
            check("rank_order", false)
        end
    else
        check("rank_order_push", rankResult ~= nil)
    end

    connA:close()
    connB:close()
    connC:close()
end

--------------------------------------------------------------
-- TEST 4: M2 模块并存互不干扰
--------------------------------------------------------------
local function test_m2_coexistence()
    log("TEST", "===== M2: Module Coexistence =====")
    local conn = connect_and_login(40001)
    check("coex_login", conn ~= nil)
    if not conn then return end

    local r = request(conn, 1001002, {})
    check("coex_login_mod", r and r.data and r.data.code == 0)

    r = request(conn, 1002004, { item_id = 2001, count = 3 })
    check("coex_bag_mod", r and r.data and r.data.code == 0)

    r = request(conn, 1006002, { score = 999 })
    check("coex_rank_mod", r and r.data and r.data.code == 0)

    r = request(conn, 1099001, { test = "coexist" })
    check("coex_echo_mod", r and r.data and r.data.code == 0)

    r = request(conn, 1002001, {})
    check("coex_bag_intact", r and r.data and r.data.code == 0)

    conn:close()
end

--------------------------------------------------------------
-- TEST 5: M3 PVP 跨服匹配
--------------------------------------------------------------
local function test_m3_pvp()
    log("TEST", "===== M3: PVP Cross Matching =====")

    -- 玩家 A
    local connA = connect_and_login(50001)
    check("pvpA_login", connA ~= nil)
    if not connA then return end

    -- 玩家 B
    local connB = connect_and_login(50002)
    check("pvpB_login", connB ~= nil)
    if not connB then return end

    -- A 查看 PVP 信息
    local r = request(connA, 1003001, {})
    check("A_pvp_info", r and r.data and r.data.code == 0)

    -- A 加入匹配
    r = request(connA, 1003002, {})
    check("A_join_match", r and r.data and r.data.code == 0)

    -- A 冷却期内再次加入应失败 (已在匹配中)
    r = request(connA, 1003002, {})
    check("A_already_matching", r and r.data and r.data.code == 1)

    -- B 加入匹配 → 应触发匹配
    r = request(connB, 1003002, {})
    check("B_join_match", r and r.data and r.data.code == 0)

    -- 等待匹配结果推送
    socket.sleep(1)

    -- 读取 A 的推送 (匹配结果 + 战斗结果)
    local pushA1 = read_push(connA, 2)
    local pushA2 = read_push(connA, 2)
    local a_got_match = false
    local a_got_battle = false
    for _, p in ipairs({pushA1, pushA2}) do
        if p then
            if p.id == 8003001 then a_got_match = true end
            if p.id == 8003002 then a_got_battle = true end
        end
    end
    check("A_match_result", a_got_match)
    check("A_battle_result", a_got_battle)

    -- 读取 B 的推送
    local pushB1 = read_push(connB, 2)
    local pushB2 = read_push(connB, 2)
    local b_got_match = false
    local b_got_battle = false
    for _, p in ipairs({pushB1, pushB2}) do
        if p then
            if p.id == 8003001 then b_got_match = true end
            if p.id == 8003002 then b_got_battle = true end
        end
    end
    check("B_match_result", b_got_match)
    check("B_battle_result", b_got_battle)

    -- 验证 PVP 数据已更新
    r = request(connA, 1003001, {})
    check("A_pvp_updated",
        r and r.data and r.data.code == 0 and
        r.data.data and r.data.data.total_matches == 1)

    r = request(connB, 1003001, {})
    check("B_pvp_updated",
        r and r.data and r.data.code == 0 and
        r.data.data and r.data.data.total_matches == 1)

    connA:close()
    connB:close()
end

--------------------------------------------------------------
-- TEST 6: M3 全模块协同
--------------------------------------------------------------
local function test_m3_full()
    log("TEST", "===== M3: Full Architecture =====")

    local conn = connect_and_login(60001)
    check("full_login", conn ~= nil)
    if not conn then return end

    -- Login
    local r = request(conn, 1001002, {})
    check("full_login_mod", r and r.data and r.data.code == 0)

    -- Bag
    r = request(conn, 1002004, { item_id = 5001, count = 1 })
    check("full_bag_mod", r and r.data and r.data.code == 0)

    -- Rank
    r = request(conn, 1006002, { score = 12345 })
    check("full_rank_mod", r and r.data and r.data.code == 0)

    -- PVP info
    r = request(conn, 1003001, {})
    check("full_pvp_mod", r and r.data and r.data.code == 0)

    -- Echo
    r = request(conn, 1099001, { all = "working" })
    check("full_echo_mod", r and r.data and r.data.code == 0)

    conn:close()

    -- 重连验证持久化
    socket.sleep(2)
    conn = connect_and_login(60001)
    if conn then
        r = request(conn, 1002001, {})
        check("full_bag_persisted", r and r.data and r.data.code == 0 and r.data.data and #r.data.data.items > 0)

        r = request(conn, 1003001, {})
        check("full_pvp_persisted", r and r.data and r.data.code == 0)

        conn:close()
    end
end

--------------------------------------------------------------
-- TEST 7: 断线恢复 (模拟 Agent 崩溃场景)
--------------------------------------------------------------
local function test_reconnect_recovery()
    log("TEST", "===== Reconnect Recovery =====")

    local conn = connect_and_login(70001)
    check("recovery_login", conn ~= nil)
    if not conn then return end

    -- 写入一些数据
    local r = request(conn, 1001003, { nickname = "RecoverMe" })
    check("recovery_set_data", r and r.data and r.data.code == 0)

    r = request(conn, 1002004, { item_id = 9001, count = 5 })
    check("recovery_add_item", r and r.data and r.data.code == 0)

    -- 粗暴断开 (模拟崩溃)
    conn:close()
    socket.sleep(3)  -- 等待自动保存

    -- 重新连接
    conn = connect_and_login(70001)
    check("recovery_reconnect", conn ~= nil)
    if conn then
        r = request(conn, 1001002, {})
        check("recovery_nickname",
            r and r.data and r.data.data and
            r.data.data.nickname == "RecoverMe")

        r = request(conn, 1002001, {})
        check("recovery_bag",
            r and r.data and r.data.code == 0 and
            r.data.data and #r.data.data.items > 0)

        conn:close()
    end
end

--------------------------------------------------------------
-- 执行全部测试
--------------------------------------------------------------
print("")
print("==============================================")
print("  Skynet Game Framework — M1+M2+M3 Test Suite")
print("==============================================")
print("")

test_m1_basic()
print("")
test_m2_bag()
print("")
test_m2_rank()
print("")
test_m2_coexistence()
print("")
test_m3_pvp()
print("")
test_m3_full()
print("")
test_reconnect_recovery()

print("")
print("==============================================")
print(string.format("  Results: %d PASSED, %d FAILED", pass_count, fail_count))
print("==============================================")
print("")

if fail_count > 0 then os.exit(1) end