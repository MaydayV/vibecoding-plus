# vibecoding-plus

> 语音驱动的 AI 编程助手 — ESP32 墨水屏设备 + macOS 原生客户端

## 项目简介

vibecoding-plus 是一个局域网语音编程系统，让开发者通过实体按键说话来控制 AI 编码工具。系统由三部分组成：

- **ESP32 固件** — 运行在 S3 e-paper 4.2 寸墨水屏设备上，负责按键检测、PCM 录音、音频上行、状态显示
- **macOS 原生客户端** — Swift/SwiftUI 应用，内置 Swift 桥接服务端，提供设备管理、待办管理、墨水屏显示配置、菜单栏常驻
- **归档的 Node/Electron 实现** — 早期的 Node.js 桥接服务与 Electron 客户端已归档至 `archive/`，当前主力链路为原生客户端

整个链路：**长按设备 BOOT 键说话 → 音频通过 WebSocket 上行 → 客户端转写为文字 → 注入到当前光标所在输入框（或发给 Codex/Claude CLI）→ 设备墨水屏显示实时状态**。

### 为什么做这个项目

日常编程时，用键盘输入中英混杂的技术描述效率很低。通过语音输入，说一句话就能把意图传达给 AI 编程工具。墨水屏设备作为专用终端，低功耗常亮，不用切换窗口。

---

## 项目结构

```
vibecoding-plus/
├── firmware/                    ESP32 固件
│   ├── main/
│   │   ├── lan_mic_app.cc       主应用逻辑（重连/录音/状态机/按键交互）
│   │   ├── lan_mic_app.h        主应用头文件
│   │   ├── boards/              硬件抽象层（Zectrix S3）
│   │   ├── components/          自定义组件（WiFi/WebSocket/音频）
│   │   └── display/             墨水屏显示驱动
│   ├── releases/                预编译固件包（.zip）
│   ├── scripts/                 固件工具脚本
│   └── partitions/              分区表配置
│
├── client/
│   └── macos-native/            macOS 原生客户端（Swift/SwiftUI）
│       ├── Sources/VibeCodingPlusNative/
│       │   ├── VibeCodingPlusNativeApp.swift  App 入口（WindowGroup + 菜单栏 accessory）
│       │   ├── AppDelegate.swift              状态栏图标 / 窗口管理 / 服务菜单
│       │   ├── AppState.swift                 ObservableObject 中央状态
│       │   ├── Views/                       SwiftUI 界面（按页面拆分）
│       │   │   ├── RootView.swift           导航壳 + 侧栏
│       │   │   ├── OverviewView.swift         概览
│       │   │   ├── SettingsView.swift         设置
│       │   │   ├── InkComponents.swift        共享 UI 组件
│       │   │   └── …
│       │   ├── Models.swift                   数据模型
│       │   ├── SettingsStore.swift            配置持久化（config.env）
│       │   ├── EnvironmentChecker.swift       macOS 权限与依赖检测
│       │   ├── Server/
│       │   │   ├── NativeServer.swift         原生桥接服务端（WebSocket/STT/CLI/待办）
│       │   │   ├── ServerConfig.swift         服务端配置
│       │   │   └── WebSocketServer.swift      WebSocket 传输
│       │   └── Services/
│       │       ├── STTService.swift           语音转写（OpenAI 兼容 / Volcengine / Qwen）
│       │       ├── TextInjector.swift         CGEvent 文本注入 + 清空
│       │       ├── RemindersSync.swift        苹果提醒事项同步（EventKit）
│       │       └── TodoService.swift          本地待办管理
│       └── Resources/Info.plist
│
├── archive/                     归档（早期 Node 桥接 / Electron 客户端 / 上游文档）
├── scripts/                     仓库工具脚本（构建辅助等）
├── package.json                 历史脚本入口（Node 桥接已归档）
└── .env.example                 配置模板
```

---

## 核心功能

### 语音输入与转写

- 16kHz 单声道 PCM16 音频采集
- 多 STT 引擎支持：OpenAI Whisper API（**支持自定义 base URL，兼容任意 OpenAI 兼容第三方接口**）、Volcengine ASR、Qwen ASR、whisper.cpp（本地）
- 转写延迟实时反馈到设备屏幕

### 发送目标

| 目标 | 说明 |
|------|------|
| `text_injector` | 转写文字通过 CGEvent 注入当前光标所在输入框（默认，识别完直接输入） |
| `codex_exec` | 转写文字发送给 Codex CLI，解析 JSON 事件流 |
| `claude_code` | 转写文字发送给 Claude Code CLI，支持方案选择交互 |

### 交付模式

- **immediate**（文本注入默认）— 转写后立即输入到光标，连续长按可追加。
- **confirm_on_device** — 转写后暂存 pending，用户在设备端确认后发送（用于 Codex/Claude 流程）。文本注入目标会强制走 immediate，不受此设置影响。

### 待办管理

- 语音增删改查（"买牛奶"、"第二项改成开会"、"删除第三项"）
- 设备端物理按键选择、完成、删除
- 新增待办时可选择提醒事项分组
- 离线待办模式 — 断网时操作缓存本地，重连后自动同步
- 苹果提醒事项双向同步（EventKit，无需 remindctl）

### 编程模式

- CLI 多方案返回时，设备端 UP/DN 选择方案，BOOT 应用
- 墨水屏实时显示 CLI 状态（空闲/运行中/完成/错误）
- 滚动日志查看（日志页查看，概览页不再显示近期日志）

### 网络与安全

- LAN UDP 自动发现（设备广播 → 主机回复 WS 地址）
- 可选 HMAC-SHA256 鉴权（nonce 重放保护 + 时间窗口校验）
- 固件支持 Wi-Fi 配网（AP 模式 + 扫码/手动输入）

### 固件可靠性

- 心跳保活 + 超时重连
- 指数退避重连
- 连续失败自动 WiFi 恢复
- 深度睡眠省电 — 断线后自动休眠，BOOT 按钮或定时器唤醒

### macOS 客户端特性

- 菜单栏常驻应用（`LSUIElement`，无 Dock 图标，关闭窗口后保留在菜单栏，点击图标重新显示窗口）
- 墨水屏风格界面（白底黑字、像素水墨纹理、低饱和度）
- macOS 权限状态实时反映（辅助功能 / 麦克风 / 提醒事项），授权后自动刷新
- 显示配置即时推送到设备（亮/暗色、刷新间隔、强制刷新屏幕）
- 全局快捷键 ⌘⇧V 切换服务

---

## 设备操作指南（文本注入模式 · 唯一用法）

所有操作基于 **BOOT 键**，上/下键仅用于翻页与切换模式。

| 操作 | 结果 |
|------|------|
| 长按 BOOT | 开始录音，松开后自动识别并**输入到光标处** |
| 继续长按 BOOT | 在输入框现有内容后**追加**新识别的文字 |
| 短按 BOOT | 发送**回车**（提交当前输入框） |
| 连按两次 BOOT | **清空**输入框中已输入的内容 |
| 上 / 下 键 | 翻页 / 切换模式（不参与发送） |

> 仅当发送目标为「文本注入」时适用；识别完成后自动输入，无需在设备上确认。客户端「设置 → 使用说明」中也有完整说明。

### 待办模式

| 操作 | 说明 |
|------|------|
| 长按 BOOT | 语音输入待办（"买牛奶"、"删除第二项"） |
| UP / DN | 选择待办项 |
| 单击 BOOT | 切换当前项完成状态 |
| 双击 BOOT | 删除当前项 |
| 长按 UP | 打开菜单 |

### 方案选择（CLI 返回多方案时）

| 操作 | 说明 |
|------|------|
| UP / DN | 浏览方案 |
| 单击 BOOT | 应用所选方案 |

---

## 快速开始

### 环境要求

- macOS 13+（文本注入需授予辅助功能权限）
- Xcode（编译原生客户端）
- ESP-IDF v5.5（仅编译固件时需要）

### 配置

原生客户端首次启动会在 `~/Library/Application Support/vibecoding-plus/config.env` 生成配置，也可在客户端「设置」页直接编辑。至少配置一个 STT 密钥：

```bash
# OpenAI Whisper（或任意 OpenAI 兼容第三方接口）
OPENAI_API_KEY=sk-xxx
OPENAI_BASE_URL=https://api.openai.com/v1   # 留空使用官方；可填第三方兼容地址

# 或 Volcengine ASR
# VOLCENGINE_APP_KEY=xxx
# VOLCENGINE_ACCESS_KEY=xxx

# 或 whisper.cpp 本地模型
# WHISPER_CPP_MODEL_PATH=/path/to/ggml-model.bin
```

### 构建并运行原生客户端

```bash
cd client/macos-native
xcodebuild -project VibeCodingPlusNative.xcodeproj \
  -scheme VibeCodingPlusNative -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/VibeCodingPlusNative-*/Build/Products/Debug/VibeCoding\ Plus.app
```

启动后菜单栏出现波形图标，点击打开主窗口。首次使用需在「系统设置 → 隐私与安全」授予：

- 辅助功能（文本注入必需）
- 麦克风（语音录入）
- 提醒事项（待办同步，可选）

客户端「设置 → macOS 授权状态」可查看并一键跳转授权，授权后点「重新检查」刷新。

---

## 配置参考

### 核心配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SEND_TARGET` | `text_injector` | `text_injector` / `codex_exec` / `claude_code` |
| `TRANSCRIPT_DELIVERY_MODE` | `immediate` | 文本注入强制 immediate；仅 Codex/Claude 用 `confirm_on_device` |
| `TEXT_INJECTION_MODE` | `type_and_enter` | `type_and_enter` / `type_only` |
| `OPENAI_BASE_URL` | 官方地址 | 任意 OpenAI 兼容第三方接口地址 |
| `LAN_SHARED_SECRET` | 空（关闭） | 设置后启用 HMAC 鉴权 |
| `LAN_VOICE_PORT` | 8765 | WebSocket 端口 |
| `LAN_DISCOVERY_PORT` | 8766 | UDP 发现端口 |

### STT 配置（多选一）

| 引擎 | 变量 |
|------|------|
| OpenAI 兼容 | `OPENAI_API_KEY` + `OPENAI_BASE_URL`（可选） |
| Volcengine ASR | `VOLCENGINE_APP_KEY` + `VOLCENGINE_ACCESS_KEY` |
| whisper.cpp | `WHISPER_CPP_MODEL_PATH` |

### Claude Code 配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CLAUDE_COMMAND` | 自动检测 | claude 二进制路径 |
| `CLAUDE_CWD` | 项目根目录 | 工作目录 |
| `CLAUDE_ALLOWED_TOOLS` | `Read,Edit,Write,Bash,Glob,Grep` | 预批准工具列表 |
| `CLAUDE_MAX_TURNS` | 10 | 最大 agentic 轮次 |
| `CLI_TIMEOUT_SEC` | 300 | CLI 子进程超时 |

### 苹果提醒事项同步

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REMINDERS_SYNC_ENABLED` | 0 | 设为 1 启用 |
| `REMINDERS_LIST` | 空（全部） | 同步的提醒事项列表名 |
| `REMINDERS_POLL_SEC` | 15 | 轮询间隔（秒） |

### 调试标志

| 变量 | 说明 |
|------|------|
| `MOCK_TRANSCRIPT` | 跳过 STT，使用固定文本 |
| `DRY_RUN_TEXT_INJECTION` | 只打印日志，不真正输入 |
| `SAVE_DEBUG_WAV` | 保存音频到 tmp/ |

---

## 固件构建与烧录

### 环境准备

安装 [ESP-IDF v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/) 并激活环境。

### 编译

```bash
cd firmware
idf.py build
```

### 烧录

```bash
idf.py -p /dev/cu.usbmodem* flash
```

### 鉴权同步

主机与固件若都开启鉴权，需保持共享密钥一致：

- 客户端：`LAN_SHARED_SECRET`（config.env，设置页可编辑）
- 固件：`CONFIG_LAN_SHARED_SECRET`（sdkconfig）

---

## 协议流程

```
设备                          客户端(原生服务端)
  │                            │
  │  ── UDP discover_host ──►  │  1. 设备发现
  │  ◄── discover_reply ────  │     （回复 WS 地址）
  │                            │
  │  ── WS connect ─────────►  │  2. 建立连接
  │  ── hello (HMAC) ───────►  │     鉴权握手
  │  ◄── hello_ack ─────────  │
  │  ◄── server_ready ──────  │     发送初始状态 / 待办 / 显示配置
  │                            │
  │  ── ptt_start ──────────►  │  3. 语音录入
  │  ── [binary PCM16] ─────►  │     音频流
  │  ── ptt_stop ───────────►  │
  │                            │
  │  ◄── transcript_final ───  │  4. 转写结果（文本注入模式直接输入）
  │                            │
  │  ── action_enter ───────►  │  5. 短按 BOOT 回车
  │  ── action_clear_input ─►  │  6. 双击 BOOT 清空输入框
  │                            │
  │  ◄── cli_state ─────────  │  7. CLI/待办/显示状态实时推送
  │  ◄── todo_state ────────  │
  │  ◄── display_config ────  │
```

### 音频格式

- 采样率：16kHz
- 位深：16-bit signed little-endian
- 声道：单声道

---

## 隐私说明

### 语音与 STT

- 录音仅在按住设备 BOOT 键期间采集，经局域网 WebSocket 发送到**本机** macOS 客户端转写。
- 若配置 OpenAI / Volcengine / Qwen 等云端 STT，音频或转写请求会发往对应服务商；使用 `whisper.cpp` 可完全本地转写。
- 调试时可设 `SAVE_DEBUG_WAV=1` 将片段保存到系统临时目录。

### 文本注入（剪贴板）

- `text_injector` 模式通过 **剪贴板 + ⌘V** 将转写文本粘贴到当前前台应用的输入框（与 macOS 原生听写类似）。
- 注入前会**备份**系统剪贴板内容，粘贴后**恢复**；若注入过程中你手动复制了其他内容，可能被覆盖——建议在注入完成前避免复制敏感数据。
- 注入与撤回在专用串行队列执行，降低与并发剪贴板操作的竞态；仍无法消除所有第三方 App 的剪贴板监听行为。
- **撤回（undo）** 对上一段注入发送若干次 Backspace（按 Unicode 字素簇计数）；复杂组合字符、部分富文本编辑器可能与预期步数不一致。
- 诊断日志：`~/Library/Application Support/vibecoding-plus/inject.log`（不含剪贴板全文，仅有长度与结果）。

### 本地数据

- 待办、配置保存在 `~/Library/Application Support/vibecoding-plus/`。
- Codex / Claude 会话状态只读观测时，仅读取 `~/.codex/sessions`、`~/.claude/projects` 等**本机已有**文件，不上传。

---

## 安全建议

- 不要提交 `.env`、API Key 等敏感信息到版本库
- 共享网络务必设置 `LAN_SHARED_SECRET` 启用鉴权
- 生产环境关闭 `DRY_RUN_TEXT_INJECTION` 和 `MOCK_TRANSCRIPT`
- 原生客户端首次运行需授予辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）

---

## 致谢

基于上游项目 [vibecoding-voice](https://github.com/mac20777/vibecoding-voice) 二次开发，感谢上游作者与社区贡献。
