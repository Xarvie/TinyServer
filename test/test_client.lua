--------------------------------------------------------------
-- test_client.lua — M1+M2 完整验收测试
-- 独立运行: lua test/test_client.lua
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
        log("RECV", string.format("pid=%d code=%s", resp.id or 0, resp.data and resp.data.code or "?"))
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

-- 尝试读取推送消息 (非阻塞)
local function read_push(conn, timeout)
    return read_frame(conn, timeout or 1)
end

--------------------------------------------------------------
-- 创建连接并登录
--------------------------------------------------------------
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

    -- Echo
    local r = request(conn, 1099001, { msg = "hello", num = 42 })
    check("echo", r and r.data and r.data.code == 0 and r.data.echo and r.data.echo.msg == "hello")

    -- Ping
    r = request(conn, 1099002, { t = os.time() })
    check("ping", r and r.data and r.data.code == 0 and r.data.server_time)

    -- GetBaseInfo
    r = request(conn, 1001002, {})
    check("base_info", r and r.data and r.data.code == 0)

    -- SetNickname
    r = request(conn, 1001003, { nickname = "TestHero" })
    check("set_nickname", r and r.data and r.data.code == 0)

    -- Verify nickname
    r = request(conn, 1001002, {})
    check("nickname_saved", r and r.data and r.data.data and r.data.data.nickname == "TestHero")

    -- Unknown module
    r = request(conn, 1088001, {})
    check("unknown_module_rejected", r and r.data and r.data.code == -1)

    conn:close()

    -- Reconnect & verify persistence
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

    -- 初始背包为空
    local r = request(conn, 1002001, {})
    check("bag_empty", r and r.data and r.data.code == 0 and r.data.data and #r.data.data.items == 0)

    -- 添加测试物品
    r = request(conn, 1002004, { item_id = 1001, count = 10 })
    check("add_item", r and r.data and r.data.code == 0)

    r = request(conn, 1002004, { item_id = 1002, count = 5 })
    check("add_item2", r and r.data and r.data.code == 0)

    -- 查看背包
    r = request(conn, 1002001, {})
    check("bag_has_items", r and r.data and r.data.code == 0 and r.data.data and r.data.data.used_slots == 2)

    -- 使用物品
    r = request(conn, 1002002, { item_id = 1001, count = 3 })
    check("use_item", r and r.data and r.data.code == 0)

    -- 卖出物品
    r = request(conn, 1002003, { item_id = 1002, count = 2 })
    check("sell_item", r and r.data and r.data.code == 0 and r.data.data and r.data.data.gold == 20)

    -- 使用不够的物品
    r = request(conn, 1002002, { item_id = 1001, count = 999 })
    check("use_insufficient", r and r.data and r.data.code == 2)

    -- 验证 BagDirty 独立于 LoginDirty
    -- (需服务端日志确认，这里只验证功能正常)
    r = request(conn, 1002001, {})
    check("bag_final_state", r and r.data and r.data.code == 0)

    conn:close()

    -- 重连验证背包持久化
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

    -- 玩家 A
    local connA = connect_and_login(30001)
    check("rankA_login", connA ~= nil)
    if not connA then return end

    -- 玩家 B
    local connB = connect_and_login(30002)
    check("rankB_login", connB ~= nil)
    if not connB then return end

    -- 玩家 C
    local connC = connect_and_login(30003)
    check("rankC_login", connC ~= nil)
    if not connC then return end

    -- A 提交分数 100
    local r = request(connA, 1006002, { score = 100 })
    check("A_submit", r and r.data and r.data.code == 0)

    -- 读取 A 的推送
    socket.sleep(0.5)
    local pushA = read_push(connA)
    check("A_rank_push", pushA and pushA.id == 8006001)

    -- B 提交分数 200
    r = request(connB, 1006002, { score = 200 })
    check("B_submit", r and r.data and r.data.code == 0)
    socket.sleep(0.5)

    -- C 提交分数 150
    r = request(connC, 1006002, { score = 150 })
    check("C_submit", r and r.data and r.data.code == 0)
    socket.sleep(0.5)

    -- A 查看排行榜
    r = request(connA, 1006001, {})
    check("A_get_rank", r and r.data and r.data.code == 0)

    -- 读取排行榜结果推送
    socket.sleep(0.5)
    local rankResult = read_push(connA)
    if rankResult and rankResult.id == 5006001 and rankResult.data then
        local list = rankResult.data.list
        if list and #list >= 3 then
            check("rank_order",
                list[1].uid == 30002 and   -- B 第一
                list[2].uid == 30003 and   -- C 第二
                list[3].uid == 30001)      -- A 第三
        else
            check("rank_order", false)
        end
    else
        -- 排行榜结果可能在 S2C 5006001 里直接返回
        check("rank_order_push", rankResult ~= nil)
    end

    -- B 提交更高分
    r = request(connB, 1006002, { score = 500 })
    check("B_submit_higher", r and r.data and r.data.code == 0)

    -- B 不提高分不该更新
    r = request(connB, 1006002, { score = 50 })
    check("B_submit_lower", r and r.data and r.data.code == 0)

    connA:close()
    connB:close()
    connC:close()
end

--------------------------------------------------------------
-- TEST 4: 模块并存互不干扰
--------------------------------------------------------------
local function test_m2_coexistence()
    log("TEST", "===== M2: Module Coexistence =====")

    local conn = connect_and_login(40001)
    check("coex_login", conn ~= nil)
    if not conn then return end

    -- Login 模块
    local r = request(conn, 1001002, {})
    check("coex_login_mod", r and r.data and r.data.code == 0)

    -- Bag 模块
    r = request(conn, 1002004, { item_id = 2001, count = 3 })
    check("coex_bag_mod", r and r.data and r.data.code == 0)

    -- Rank 模块
    r = request(conn, 1006002, { score = 999 })
    check("coex_rank_mod", r and r.data and r.data.code == 0)

    -- Echo 模块
    r = request(conn, 1099001, { test = "coexist" })
    check("coex_echo_mod", r and r.data and r.data.code == 0)

    -- 全部正常
    r = request(conn, 1002001, {})
    check("coex_bag_intact", r and r.data and r.data.code == 0)

    conn:close()
end

--------------------------------------------------------------
-- 执行全部测试
--------------------------------------------------------------
print("")
print("==============================================")
print("  Skynet Game Framework — M1+M2 Test Suite")
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
print("==============================================")
print(string.format("  Results: %d PASSED, %d FAILED", pass_count, fail_count))
print("==============================================")
print("")

if fail_count > 0 then
    os.exit(1)
end
