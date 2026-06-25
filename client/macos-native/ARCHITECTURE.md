# macOS 原生客户端技术文档

## 概述

纯 SwiftUI 原生应用，内嵌完整服务端运行时，无需单独启动 Node.js 服务。目标平台 macOS 15.0+，Bundle ID `com.mac20777.vibecodingplus`，通过 `xcodegen` 生成 Xcode 项目。

## 目录结构

```
client/macos-native/
  project.yml                            — xcodegen 项目配置
  VibeCodingPlusNative.xcodeproj/        — 生成的 Xcode 工程
  Resources/
    Info.plist                           — 权限描述（辅助功能/麦克风/日历提醒）
    Assets.xcassets/                     — App 图标
  Sources/VibeCodingPlusNative/
    VibeCodingPlusNativeApp.swift        — @main 入口，全局快捷键 Cmd+Shift+V
    AppDelegate.swift                    — NSApplicationDelegate，系统托盘菜单
    AppState.swift                       — 中央 ObservableObject，生命周期管理
    Models.swift                         — 数据模型（ServiceStatus, SendTarget, TodoItem 等）
    Views.swift                          — 完整 SwiftUI 界面（~1200 行，墨水屏风格）
    SettingsStore.swift                  — 持久化到 ~/Library/Application Support/
    EnvironmentChecker.swift             — 工具检测 + 安装脚本
    Shell.swift                          — 子进程运行工具
    Server/
      NativeServer.swift                 — 核心服务端 actor（~1400 行，替代 Node.js server.mjs）
      WebSocketServer.swift              — Network.framework 自实现 WS 服务器（RFC 6455）
      DiscoveryServer.swift              — UDP 广播发现（BSD socket + DispatchSource）
      LANAuth.swift                      — CryptoKit HMAC-SHA256 认证
      ServerConfig.swift                 — .env 配置加载
    Services/
      STTService.swift                   — 语音转文字（OpenAI Whisper / Volcengine / whisper.cpp / Qwen ASR）
      TextInjector.swift                 — 剪贴板 + CGEvent 文本注入
      CLISessionManager.swift            — Codex CLI + Claude CLI 子进程管理
      TodoService.swift                  — 待办 CRUD + 持久化 + Apple Reminders 桥接
      TodoAssistant.swift                — 语音意图解析（规则 + DeepSeek LLM）
      RemindersSync.swift                — Apple Reminders EventKit 双向同步
```

## 启动流程

1. **App 启动** — `VibeCodingPlusNativeApp.swift` 创建 `AppState`，通过 `@NSApplicationDelegateAdaptor` 挂载 `AppDelegate`，`.task` modifier 调用 `bootstrap()` 做环境检测
2. **用户点击 Start**（或 `Cmd+Shift+V`）— `AppState.startService()` 执行：
   - `makeServerConfig()` 加载 `~/Library/Application Support/vibecoding-plus/config.env`
   - 创建 `NativeServer(config:)` 实例
   - 绑定回调（onStatusChange / onTranscript / onCliSummary / onTodoStateChange 等）
   - `server.start()` 依次启动：TodoService → WebSocketServer(:8765) → DiscoveryServer(:8766) → keepalive 心跳

## ESP32 墨水屏连接流程

### 阶段 ① — UDP 发现（端口 8766）

- ESP32 向局域网广播地址发送 `discover_host` JSON 包
- 客户端通过 `getifaddrs` 找到与发送方同子网的本地 IP，回复：
  ```json
  {
    "type": "discover_reply",
    "hostId": "VibeServer",
    "wsUrl": "ws://<局域网IP>:8765",
    "wsPort": 8765,
    "authSig": "<可选 HMAC>"
  }
  ```

### 阶段 ② — WebSocket 握手（TCP 8765）

- 基于 Apple `Network.framework`（`NWListener` / `NWConnection`）自实现
- 自定义 HTTP Upgrade 握手（解析 `Sec-WebSocket-Key`，计算 `Sec-WebSocket-Accept`）
- `WSFrameParser` 处理 opcode 解析、掩码、多帧消息
- 每个连接有独立串行写队列保证线程安全

### 阶段 ③ — 认证与 Hello

- 若 `LAN_SHARED_SECRET` 为空 → 直接通过
- 否则设备发送 `hello` 消息（含 `deviceId`, `boardType`, `authNonce`, `authTs`, `authSig`）
- 服务端验证：
  - 时间戳新鲜度（300 秒窗口）
  - Nonce 防重放（内存缓存）
  - HMAC-SHA256 签名：消息格式 `"hello|{deviceId}|{boardType}|{ts}|{nonce}"`
  - 时间安全比较（防时序攻击）
- 成功后依次发送：`hello_ack` → `server_ready` → `display_config` → CLI 快照

### 阶段 ④ — 数据通信

- JSON 文本帧：PTT 会话、CLI 状态广播、Todo 状态、显示配置
- 二进制帧：PCM16 音频（16kHz 单声道）
- Keepalive：每 30 秒 WebSocket ping，连续 2 次未响应断开

## 消息协议

| 方向 | 消息 | 说明 |
|------|------|------|
| 设备→服务 | `ptt_start` | 开始推按说话 |
| 设备→服务 | 二进制帧 | PCM16 音频数据 |
| 设备→服务 | `ptt_stop` | 结束录音，触发 STT |
| 服务→设备 | `transcript_final` | 转写结果 |
| 设备→服务 | `action_send` / `action_undo` | 确认模式下的发送/撤回 |
| 服务→设备 | `cli_session_state` | CLI 阶段状态 |
| 服务→设备 | `cli_summary` | 用户文本 + AI 响应 |
| 服务→设备 | `cli_log_tail` | 日志滚动 |
| 双向 | `todo_command` / `todo_state` | 待办操作与同步 |

## 构建与运行

```bash
npm run native:open          # 打开 Xcode 项目
npm run native:build         # xcodegen + xcodebuild 调试构建
npm run native:dist:mac      # 发布构建（codesign ad-hoc + zip → dist-native/）
```

## 配置

配置文件路径：`~/Library/Application Support/vibecoding-plus/config.env`

关键变量与服务端一致（见项目根目录 CLAUDE.md 的 Configuration 部分）。

## 权限需求

- **辅助功能** — 文本注入（CGEvent 模拟 Cmd+V）
- **麦克风** — 本地录音（如果使用设备外的本机麦克风）
- **日历/提醒事项** — Apple Reminders 双向同步
