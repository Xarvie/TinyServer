# Skynet Game Framework — 完整文件清单 (M1+M2+M3)

## 目录结构

```
skynet-game/
├── config/
│   ├── config.game                 # Skynet 启动配置
│   ├── game_config.lua             # 游戏配置 (端口/DB/模块路径等)
│   └── module_registry.lua         # 模块编号注册表
│
├── service/                        # 框架层服务 (人类维护)
│   ├── main.lua                    # 引导服务 (启动顺序)
│   ├── gate_service.lua            # Gate 中心路由 + 跨服授权
│   ├── agent_service.lua           # Agent 玩家容器
│   ├── db_service.lua              # DB 持久化服务
│   ├── inter_service.lua           # Inter 单服协调服务
│   ├── cross_manager.lua           # CrossManager 跨服管理
│   └── logger_service.lua          # Logger 日志服务
│
├── framework/                      # 框架公共模块
│   ├── protocol.lua                # 协议 ID 解析/构建
│   ├── codec.lua                   # JSON 编解码 + 帧封装
│   ├── player.lua                  # Player 对象模型
│   └── module_loader.lua           # 模块自动发现/加载/热更新
│
├── sdk/                            # SDK 封装 (业务模块调用)
│   ├── send.lua                    # SendToClient, SendToGate
│   ├── asset.lua                   # AddItem, RemoveItem, HasItem
│   ├── log.lua                     # 统一日志
│   └── ticket.lua                  # 跨服凭证生成/验证
│
├── module/                         # 业务模块 (AI 开发区)
│   ├── login/
│   │   ├── login_db.lua            # 001 登录数据层
│   │   └── login_agent.lua         # 001 登录业务层
│   ├── echo/
│   │   └── echo_agent.lua          # 099 回显测试
│   ├── bag/
│   │   ├── bag_db.lua              # 002 背包数据层
│   │   └── bag_agent.lua           # 002 背包业务层
│   ├── rank/
│   │   ├── rank_db.lua             # 006 排行榜数据层
│   │   ├── rank_agent.lua          # 006 排行榜业务层
│   │   └── rank_inter.lua          # 206 排行榜协调层
│   └── pvp/
│       ├── pvp_db.lua              # 003 PVP 数据层
│       ├── pvp_agent.lua           # 003 PVP 业务层
│       └── pvp_cross.lua           # 103 PVP 跨服匹配
│
├── test/
│   ├── test_client.lua             # M1+M2 测试套件
│   ├── test_hotreload.lua          # 热更新验证
│   └── test_full_flow.lua          # M1+M2+M3 全架构测试
│
└── doc/
    ├── MODULE_DEV_GUIDE.md         # AI 模块开发指南
    ├── SDK_API.md                  # SDK 接口文档
    └── MODULE_REGISTRY.md          # 模块编号注册表文档
```

## 里程碑交付物对照

### M1: 框架骨架 + 单机闭环 ✅
- [x] Gate ↔ Agent ↔ DB 全链路
- [x] 协议 ID 解析路由 (protocol.lua)
- [x] 模块自动发现加载 (module_loader.lua)
- [x] Player 对象 + Dirty 标记 (player.lua)
- [x] DB 加载/保存/迁移 (db_service.lua)
- [x] echo_agent 回显测试
- [x] login 登录模块完整流程

### M2: 多人协调 + 模块化验证 ✅
- [x] Inter 服务接入 (inter_service.lua)
- [x] Inter → Gate → Agent 反向通知
- [x] 批量广播 + 防推送风暴
- [x] bag 背包模块 (资产增删改查)
- [x] rank 排行榜模块 (Agent + Inter 协调)
- [x] 热更新机制 (agent/inter 可热更, db 禁止)
- [x] 多模块并存互不干扰

### M3: 跨服架构 + 生产化收尾 ✅
- [x] CrossManager 服务 (cross_manager.lua)
- [x] Cross 模块加载机制
- [x] 跨服授权 + 凭证机制 (ticket.lua, Gate cross_auth)
- [x] pvp 跨服匹配业务 (pvp_agent + pvp_cross)
- [x] Logger 日志服务 (logger_service.lua)
- [x] 统一日志 SDK (log.lua)
- [x] 资产 SDK (asset.lua)
- [x] 消息发送 SDK (send.lua)
- [x] 全架构集成测试 (test_full_flow.lua)
- [x] AI 模块开发指南
- [x] SDK 接口文档
- [x] 模块编号注册表

## 服务启动顺序

```
Logger → DB → Inter → CrossManager → Gate
              ↓                        ↓
         Gate.init(db, inter, cross_mgr, logger)
              ↓                        ↓
         Inter.init(gate)         CrossMgr.init(gate)
```

## 架构拓扑

```
                    Client
                      │
                      ▼
               ┌──── Gate ────┐
               │   (中心路由)   │
        ┌──────┼──────┬───────┼──────┐
        ▼      ▼      ▼       ▼      ▼
     Agent   Agent    DB    Inter  CrossMgr
     (N个)   (N个)  (1个)  (1个)    (1个)
                                      │
                                   Cross模块
                                  (pvp_cross等)
```

所有服务仅与 Gate 通信，禁止点对点连接。


# 模块编号注册表

## 已注册模块

| 编号 | 名称 | 类型 | 文件 | 说明 |
|------|------|------|------|------|
| 001 | login | Agent + DB | login_agent.lua, login_db.lua | 登录系统 |
| 002 | bag | Agent + DB | bag_agent.lua, bag_db.lua | 背包系统 |
| 003 | pvp | Agent + DB + Cross | pvp_agent.lua, pvp_db.lua, pvp_cross.lua | PVP 匹配与战斗 |
| 006 | rank | Agent + DB + Inter | rank_agent.lua, rank_db.lua, rank_inter.lua | 排行榜系统 |
| 099 | echo | Agent | echo_agent.lua | 回显测试 (无持久化) |
| 103 | pvp_cross | Cross | pvp_cross.lua | PVP 跨服匹配 (003 的跨服部分) |
| 206 | rank_inter | Inter | rank_inter.lua | 排行榜协调 (006 的 Inter 部分) |

## 编号范围

| 范围 | 用途 | 状态 |
|------|------|------|
| 001-099 | 基础系统模块 | 已用: 1, 2, 3, 6, 99 |
| 100-199 | 跨服系统模块 (Cross) | 已用: 103 |
| 200-299 | Inter 协调模块 | 已用: 206 |
| 300-999 | 业务玩法模块 | 全部可用 |

## 可用编号 (推荐)

**基础系统 (001-099)**:
- 004 — 任务系统
- 005 — 公会系统
- 007 — 签到系统
- 008 — 邮件系统
- 009 — 好友系统
- 010 — 聊天系统
- 011-098 — 可用

**跨服 (100-199)**:
- 104-199 — 可用

**Inter (200-299)**:
- 200-205, 207-299 — 可用

**业务玩法 (300-999)**:
- 300 — 抽卡系统
- 301 — 养成系统
- 302 — 副本系统
- 303-999 — 可用

## 协议 ID 速查

每个模块的协议 ID 格式: `TXXXYYY`

以模块 007 (签到) 为例:
- `1007001` — C2S_GetCheckinInfo
- `1007002` — C2S_DoCheckin
- `5007001` — S2C_CheckinInfo
- `5007002` — S2C_CheckinResult
- `8007001` — PUSH_CheckinReminder (如需主动推送)

每个模块最多 999 个协议 (001-999)。