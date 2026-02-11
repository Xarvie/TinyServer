--------------------------------------------------------------
-- test_hotreload.lua — 热更新验证脚本
--
-- 使用方式:
--   1. 启动服务器, 运行 test_client.lua 确认正常
--   2. 修改 bag_agent.lua 中 C2S_SellItem 的 gold 计算 (10 -> 20)
--   3. 通过控制台发送热更指令 (需实现 admin 接口)
--      或者在 skynet console 中: call gate hotreload bag agent
--   4. 运行此脚本验证
--------------------------------------------------------------
local socket = require "socket"
local json   = require "cjson.safe"

local HOST, PORT = "127.0.0.1", 8888

local function encode(pid, data)
    local payload = json.encode({ id = pid, data = data or {} })
    local len = #payload
    return string.char(math.floor(len/256), len%256) .. payload
end

local function read_frame(conn)
    conn:settimeout(5)
    local hdr = conn:receive(2)
    if not hdr then return nil end
    local plen = hdr:byte(1)*256 + hdr:byte(2)
    local body = conn:receive(plen)
    if not body then return nil end
    return json.decode(body)
end

local function request(conn, pid, data)
    conn:send(encode(pid, data))
    return read_frame(conn)
end

print("[HotReload Test]")
print("1. Connect and login...")
local conn = socket.connect(HOST, PORT)
assert(conn, "connect failed")
local r = request(conn, 1001001, { uid = 50001 })
assert(r and r.data.code == 0, "login failed")

print("2. Add test item...")
r = request(conn, 1002004, { item_id = 3001, count = 10 })
assert(r and r.data.code == 0, "add item failed")

print("3. Sell item (before hotreload)...")
r = request(conn, 1002003, { item_id = 3001, count = 1 })
print("   Gold received:", r and r.data and r.data.gold or "?")
print("   (Expected: 10 before reload, 20 after reload)")

print("")
print("4. Now modify bag_agent.lua C2S_SellItem: change 'count * 10' to 'count * 20'")
print("   Then trigger hotreload via admin console.")
print("   Then run this script again to verify gold = 20.")
print("")

conn:close()
print("[Done]")
