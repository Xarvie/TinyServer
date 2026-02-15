#!/usr/bin/env python3
"""
test_server.py — Skynet 游戏服务器 WebSocket 测试脚本

登录认证方式: AuthKey (MD5 + 时间窗口)
  - 客户端生成: authkey = base64(md5(floor(timestamp/60) + account + serverId))
  - 服务端验证: 检查当前分钟、上一分钟、下一分钟三个时间窗口
  - 有效期: ±1分钟 (约120秒窗口)
  - 3次失败自动断连

使用方法:
    python test_server.py                       # 运行全部测试 (默认 ws://127.0.0.1:9948)
    python test_server.py --host 192.168.1.10   # 指定主机
    python test_server.py --port 9949           # 指定端口
    python test_server.py --test register       # 只跑注册测试
    python test_server.py --test login           # 只跑登录测试
    python test_server.py --test heartbeat       # 只跑心跳测试
    python test_server.py --test reconnect       # 只跑顶号/重连测试
    python test_server.py --test stress          # 压力测试(多连接)
    python test_server.py --test all             # 全部测试(默认)

依赖:
    pip install websockets protobuf grpcio-tools

Proto 编译(首次):
    python -m grpc_tools.protoc -I. --python_out=. Game.proto
"""

import asyncio
import argparse
import struct
import time
import sys
import os
import traceback
import hashlib
import base64

import websockets

# ── Proto 编译 & 导入 ──────────────────────────────────────────
# 尝试导入编译后的 pb 文件，若不存在则当场编译
try:
    import Game_pb2 as pb
except ImportError:
    # 获取当前脚本所在目录 (Test 目录)
    current_dir = os.path.dirname(os.path.abspath(__file__))
    # 获取项目根目录 (server 目录)
    root_dir = os.path.dirname(current_dir)
    # 定义 Proto 文件夹路径
    proto_dir = os.path.join(root_dir, "Proto")
    proto_file = os.path.join(proto_dir, "Game.proto")

    if os.path.exists(proto_file):
        print(f"[*] Compiling {proto_file} ...")
        from grpc_tools import protoc
        # 核心修复：-I 必须指向包含 proto 文件的目录
        protoc.main([
            "grpc_tools.protoc",
            f"-I{proto_dir}", 
            f"--python_out={current_dir}", 
            proto_file
        ])
        
        # 确保编译后的文件能被 import
        sys.path.append(current_dir)
        import Game_pb2 as pb
        print("[*] Compiled successfully.")
    else:
        print(f"[!] Game.proto not found at {proto_file}")
        sys.exit(1)


# ── 协议号(与 Proto/MsgId.lua 一致) ──────────────────────────
class MsgId:
    C2S_Login          = 1001
    S2C_LoginResult    = 1002
    # C2S_Register/S2C_RegisterResult 已删除(authkey模式自动注册)
    C2S_Logout         = 1101
    S2C_Kick           = 1102
    C2S_JoinRoom       = 2001
    S2C_JoinResult     = 2002
    C2S_RoomAction     = 2003
    S2C_RoomSync       = 2004
    C2S_Ping           = 9001
    S2C_Pong           = 9002


# ── msgId -> protobuf 消息类 映射 ────────────────────────────
ENCODE_MAP = {
    MsgId.C2S_Login:      pb.C2S_Login,
    # C2S_Register 已删除(authkey模式自动注册)
    MsgId.C2S_Logout:     pb.C2S_Logout,
    MsgId.C2S_JoinRoom:   pb.C2S_JoinRoom,
    MsgId.C2S_RoomAction: pb.C2S_RoomAction,
    MsgId.C2S_Ping:       pb.C2S_Ping,
}

DECODE_MAP = {
    MsgId.S2C_LoginResult:    pb.S2C_LoginResult,
    # S2C_RegisterResult 已删除
    MsgId.S2C_Kick:           pb.S2C_Kick,
    MsgId.S2C_JoinResult:     pb.S2C_JoinResult,
    MsgId.S2C_RoomSync:       pb.S2C_RoomSync,
    MsgId.S2C_Pong:           pb.S2C_Pong,
}

MSGID_NAME = {v: k for k, v in vars(MsgId).items() if isinstance(v, int)}


# ── 编解码 ────────────────────────────────────────────────────
def encode(msg_id: int, **fields) -> bytes:
    """编码: [2B msgId big-endian][protobuf payload]"""
    cls = ENCODE_MAP.get(msg_id)
    if cls is None:
        raise ValueError(f"Unknown encode msgId: {msg_id}")
    msg = cls(**fields)
    payload = msg.SerializeToString()
    header = struct.pack("!H", msg_id)
    return header + payload


def decode(data: bytes):
    """解码: 返回 (msgId, protobuf message object)"""
    if len(data) < 2:
        return None, None
    msg_id = struct.unpack("!H", data[:2])[0]
    cls = DECODE_MAP.get(msg_id)
    if cls is None:
        return msg_id, None
    msg = cls()
    msg.ParseFromString(data[2:])
    return msg_id, msg


# ── AuthKey 生成 (MD5方案) ────────────────────────────────────
def generate_authkey(timestamp: int, account: str, server_id: int) -> str:
    """
    生成authkey: base64(md5(minute + account + serverId))
    对应服务端 GateService.lua 的 generateAuthKey 函数
    """
    minute = timestamp // 60
    plain = f"{minute}{account}{server_id}"
    md5_hash = hashlib.md5(plain.encode()).digest()
    return base64.b64encode(md5_hash).decode()


# ── 客户端封装 ────────────────────────────────────────────────
class GameClient:
    """轻量 WebSocket 客户端，封装收发逻辑"""

    def __init__(self, uri: str, name: str = "Client"):
        self.uri = uri
        self.name = name
        self.ws = None
        self.uid = None

    async def connect(self):
        self.ws = await websockets.connect(self.uri, max_size=1 << 20)
        log(self.name, "connected")

    async def close(self):
        if self.ws:
            await self.ws.close()
            log(self.name, "disconnected")

    async def send(self, msg_id: int, **fields):
        data = encode(msg_id, **fields)
        await self.ws.send(data)
        log(self.name, f">>> {MSGID_NAME.get(msg_id, msg_id)}  {fields}")

    async def recv(self, timeout: float = 5.0):
        """接收一条消息，超时抛异常"""
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        msg_id, msg = decode(raw)
        name = MSGID_NAME.get(msg_id, str(msg_id))
        fields = {f.name: getattr(msg, f.name) for f in msg.DESCRIPTOR.fields} if msg else {}
        log(self.name, f"<<< {name}  {fields}")
        return msg_id, msg

    async def recv_optional(self, timeout: float = 1.0):
        """尝试接收，超时返回 (None, None)"""
        try:
            return await self.recv(timeout=timeout)
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            return None, None

    async def login(self, account: str, server_id: int = 1):
        """登录 (使用authkey认证，首次登录自动注册)"""
        timestamp = int(time.time())
        authkey = generate_authkey(timestamp, account, server_id)
        await self.send(MsgId.C2S_Login, account=account, authkey=authkey)
        msg_id, msg = await self.recv()
        assert msg_id == MsgId.S2C_LoginResult, f"Expected LoginResult, got {msg_id}"
        if msg.code == 0:
            self.uid = msg.uid
        return msg

    async def ping(self):
        ts = int(time.time() * 1000)
        await self.send(MsgId.C2S_Ping, timestamp=ts)
        msg_id, msg = await self.recv()
        assert msg_id == MsgId.S2C_Pong, f"Expected Pong, got {msg_id}"
        return msg


# ── 日志 ──────────────────────────────────────────────────────
def log(tag: str, msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"  [{ts}] {tag}: {msg}")


def section(title: str):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def ok(msg: str):
    print(f"  ✅ {msg}")


def fail(msg: str):
    print(f"  ❌ {msg}")


# ── 测试用例 ──────────────────────────────────────────────────

async def test_register(uri: str):
    """测试首次登录自动注册"""
    section("TEST: Auto Register on First Login")
    c = GameClient(uri, "AutoReg")
    try:
        await c.connect()

        # 首次登录自动注册
        account = f"testuser_{int(time.time())}"
        result = await c.login(account)
        assert result.code == 0, f"Auto register failed with code {result.code}"
        assert result.uid > 0, f"Invalid uid: {result.uid}"
        ok(f"首次登录自动注册成功: account={account}, uid={result.uid}")

    except Exception as e:
        fail(f"自动注册测试失败: {e}")
        traceback.print_exc()
    finally:
        await c.close()


async def test_register_duplicate(uri: str):
    """测试重复登录（同一账号）"""
    section("TEST: Login Same Account Twice")
    account = f"dup_user_{int(time.time())}"

    c1 = GameClient(uri, "First")
    try:
        await c1.connect()
        result = await c1.login(account)
        assert result.code == 0
        uid1 = result.uid
        ok(f"首次登录: uid={uid1}")
    finally:
        await c1.close()

    await asyncio.sleep(0.3)

    c2 = GameClient(uri, "Second")
    try:
        await c2.connect()
        result = await c2.login(account)
        assert result.code == 0
        assert result.uid == uid1, f"UID不一致: {result.uid} vs {uid1}"
        ok(f"再次登录成功: uid={result.uid} (UID一致)")
    except Exception as e:
        fail(f"重复登录测试失败: {e}")
        traceback.print_exc()
    finally:
        await c2.close()


async def test_login(uri: str):
    """测试登录流程"""
    section("TEST: Login")
    account = f"login_user_{int(time.time())}"

    # 直接登录（首次自动注册）
    c1 = GameClient(uri, "Login1")
    try:
        await c1.connect()
        result = await c1.login(account)
        assert result.code == 0, f"Login failed: code={result.code}"
        uid = result.uid
        ok(f"首次登录: uid={uid}")
    finally:
        await c1.close()

    await asyncio.sleep(0.3)

    # 再次登录（应返回相同uid）
    c2 = GameClient(uri, "Login2")
    try:
        await c2.connect()
        result = await c2.login(account)
        assert result.code == 0, f"Login failed: code={result.code}"
        assert result.uid == uid, f"UID mismatch: expected {uid}, got {result.uid}"
        ok(f"再次登录成功: uid={result.uid}")
    except Exception as e:
        fail(f"登录测试失败: {e}")
        traceback.print_exc()
    finally:
        await c2.close()


async def test_login_wrong_authkey(uri: str):
    """测试错误authkey (使用错误的account生成)"""
    section("TEST: Login Wrong AuthKey")
    account = f"authkey_test_{int(time.time())}"

    # 先用正确authkey登录
    c1 = GameClient(uri, "CorrectAK")
    try:
        await c1.connect()
        result = await c1.login(account)
        assert result.code == 0
        ok(f"正确authkey登录成功: uid={result.uid}")
    finally:
        await c1.close()

    await asyncio.sleep(0.3)

    c2 = GameClient(uri, "WrongAK")
    try:
        await c2.connect()
        # 使用错误的account生成authkey (故意不匹配)
        timestamp = int(time.time())
        wrong_authkey = generate_authkey(timestamp, "wrong_account", 1)
        await c2.send(MsgId.C2S_Login, account=account, authkey=wrong_authkey)
        
        # authkey验证失败，gate会关闭连接或不回复
        msg_id, msg = await c2.recv_optional(timeout=2.0)
        if msg_id is None:
            ok("错误authkey导致连接关闭(符合预期)")
        elif msg_id == MsgId.S2C_LoginResult and msg.code != 0:
            ok(f"错误authkey正确返回错误码: code={msg.code}")
        else:
            fail(f"错误authkey未被拒绝: msgId={msg_id}")
    except Exception as e:
        fail(f"错误authkey测试失败: {e}")
        traceback.print_exc()
    finally:
        await c2.close()


async def test_login_nonexistent(uri: str):
    """测试不存在账号（现在会自动注册）"""
    section("TEST: Login Nonexistent Account (Auto Register)")
    c = GameClient(uri, "NewAcc")
    try:
        await c.connect()
        account = f"no_such_account_{int(time.time())}"
        result = await c.login(account)
        assert result.code == 0, f"Expected code=0 (auto register), got {result.code}"
        ok(f"不存在账号自动注册成功: uid={result.uid}")
    except Exception as e:
        fail(f"不存在账号测试失败: {e}")
        traceback.print_exc()
    finally:
        await c.close()


async def test_heartbeat(uri: str):
    """测试心跳"""
    section("TEST: Heartbeat (Ping/Pong)")
    account = f"hb_user_{int(time.time())}"

    # 登录（自动注册）
    c = GameClient(uri, "HB")
    try:
        await c.connect()
        result = await c.login(account)
        assert result.code == 0

        # 发送3次心跳
        for i in range(3):
            pong = await c.ping()
            assert pong.timestamp > 0
            ok(f"Ping/Pong #{i+1}: timestamp={pong.timestamp}")
            await asyncio.sleep(0.2)

    except Exception as e:
        fail(f"心跳测试失败: {e}")
        traceback.print_exc()
    finally:
        await c.close()


async def test_heartbeat_before_login(uri: str):
    """测试未登录时发心跳(应被忽略，不崩溃)"""
    section("TEST: Heartbeat Before Login")
    c = GameClient(uri, "HBNoAuth")
    try:
        await c.connect()

        # 未认证就发 ping — gate 应该不转发(uid=nil), 无回复
        ts = int(time.time() * 1000)
        await c.send(MsgId.C2S_Ping, timestamp=ts)

        msg_id, msg = await c.recv_optional(timeout=2.0)
        if msg_id is None:
            ok("未认证的心跳被忽略(无响应)，符合预期")
        else:
            # 某些实现可能仍然回复 pong, 不算错误
            ok(f"未认证心跳收到响应: {MSGID_NAME.get(msg_id, msg_id)} (可接受)")

    except Exception as e:
        fail(f"未登录心跳测试失败: {e}")
        traceback.print_exc()
    finally:
        await c.close()


async def test_reconnect(uri: str):
    """测试顶号: 同一账号从另一个连接登录, 旧连接应被踢"""
    section("TEST: Reconnect / Kick Duplicate Login")
    account = f"recon_user_{int(time.time())}"

    # 第一次登录（自动注册）
    c1 = GameClient(uri, "Old")
    try:
        await c1.connect()
        r1 = await c1.login(account)
        assert r1.code == 0
        ok(f"第一次登录成功: uid={r1.uid}")

        # 第二次登录(顶号)
        c2 = GameClient(uri, "New")
        try:
            await c2.connect()
            r2 = await c2.login(account)
            assert r2.code == 0
            ok(f"第二次登录成功: uid={r2.uid}")

            # 旧连接应收到 Kick 或被断开
            await asyncio.sleep(0.5)
            kick_id, kick_msg = await c1.recv_optional(timeout=2.0)
            if kick_id == MsgId.S2C_Kick:
                ok(f"旧连接收到 Kick: reason={kick_msg.reason}")
            elif kick_id is None:
                ok("旧连接已被断开(连接关闭)")
            else:
                log("Old", f"收到意外消息: {MSGID_NAME.get(kick_id, kick_id)}")

            # 新连接应正常工作
            pong = await c2.ping()
            ok(f"新连接心跳正常: timestamp={pong.timestamp}")

        finally:
            await c2.close()

    except websockets.exceptions.ConnectionClosed:
        ok("旧连接被服务端关闭(符合预期)")
    except Exception as e:
        fail(f"顶号测试失败: {e}")
        traceback.print_exc()
    finally:
        try:
            await c1.close()
        except Exception:
            pass


async def test_stress(uri: str, count: int = 20):
    """并发多连接压力测试"""
    section(f"TEST: Stress ({count} concurrent connections)")

    results = {"ok": 0, "fail": 0}

    async def single_client(index: int):
        account = f"stress_{int(time.time())}_{index}"
        c = GameClient(uri, f"S{index:03d}")
        try:
            await c.connect()
            login = await c.login(account)
            if login.code != 0:
                results["fail"] += 1
                return

            pong = await c.ping()
            assert pong.timestamp > 0

            results["ok"] += 1
        except Exception as e:
            log(f"S{index:03d}", f"error: {e}")
            results["fail"] += 1
        finally:
            try:
                await c.close()
            except Exception:
                pass

    # 分批执行, 每批 5 个
    batch_size = 5
    for start in range(0, count, batch_size):
        batch = [single_client(i) for i in range(start, min(start + batch_size, count))]
        await asyncio.gather(*batch)
        await asyncio.sleep(0.2)

    ok(f"压力测试完成: 成功={results['ok']}, 失败={results['fail']}")
    if results["fail"] > 0:
        fail(f"{results['fail']} 个连接失败")


async def test_join_room(uri: str):
    """测试加入房间(跨服玩法)"""
    section("TEST: Join Room")
    account = f"room_user_{int(time.time())}"

    c = GameClient(uri, "Room")
    try:
        await c.connect()
        result = await c.login(account)
        assert result.code == 0
        ok(f"登录成功: uid={result.uid}")

        # 加入房间
        await c.send(MsgId.C2S_JoinRoom, roomId="test_room_001")
        msg_id, msg = await c.recv(timeout=3.0)

        if msg_id == MsgId.S2C_JoinResult:
            if msg.code == 0:
                ok(f"加入房间成功: roomId={msg.roomId}")
            else:
                log("Room", f"加入房间返回 code={msg.code}")
        else:
            log("Room", f"收到意外响应: {MSGID_NAME.get(msg_id, msg_id)}")

    except asyncio.TimeoutError:
        log("Room", "等待 JoinResult 超时(可能模块未注册路由)")
    except Exception as e:
        fail(f"房间测试失败: {e}")
        traceback.print_exc()
    finally:
        await c.close()


async def test_authkey_demo(uri: str):
    """演示authkey生成和使用"""
    section("TEST: AuthKey Demo")
    
    timestamp = int(time.time())
    account = "player001"
    server_id = 1
    
    authkey = generate_authkey(timestamp, account, server_id)
    minute = timestamp // 60
    
    print(f"  AuthKey生成演示:")
    print(f"    timestamp  = {timestamp}")
    print(f"    minute     = {minute} (floor(timestamp/60))")
    print(f"    account    = {account}")
    print(f"    serverId   = {server_id}")
    print(f"    plain      = {minute}{account}{server_id}")
    print(f"    authkey    = {authkey}")
    ok("AuthKey生成示例完成")


# ── 测试编排 ──────────────────────────────────────────────────

TEST_REGISTRY = {
    "authkey":      [test_authkey_demo],
    "register":     [test_register, test_register_duplicate],
    "login":        [test_login, test_login_wrong_authkey, test_login_nonexistent],
    "heartbeat":    [test_heartbeat, test_heartbeat_before_login],
    "reconnect":    [test_reconnect],
    "room":         [test_join_room],
    "stress":       [test_stress],
}


async def run_tests(uri: str, test_name: str):
    print(f"\n🎮 Skynet Game Server Test — target: {uri}")
    print(f"   test suite: {test_name}")

    if test_name == "all":
        for group_name, tests in TEST_REGISTRY.items():
            for t in tests:
                await t(uri)
                await asyncio.sleep(0.3)
    elif test_name in TEST_REGISTRY:
        for t in TEST_REGISTRY[test_name]:
            await t(uri)
            await asyncio.sleep(0.3)
    else:
        print(f"❌ Unknown test: '{test_name}'")
        print(f"   Available: {', '.join(TEST_REGISTRY.keys())}, all")
        return

    section("DONE")
    print("  All tests completed.\n")


def main():
    parser = argparse.ArgumentParser(description="Skynet Game Server Test Client")
    parser.add_argument("--host", default="127.0.0.1", help="Server host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=9948, help="WebSocket port (default: 9948)")
    parser.add_argument("--test", default="all",
                        help="Test to run: register, login, heartbeat, reconnect, room, stress, all")
    args = parser.parse_args()

    uri = f"ws://{args.host}:{args.port}"
    asyncio.run(run_tests(uri, args.test))


if __name__ == "__main__":
    main()