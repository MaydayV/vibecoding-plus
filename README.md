# vibecoding-plus

> 语音驱动的 AI 编程助手 — ESP32 墨水屏设备 + macOS 桌面客户端

## 项目简介

vibecoding-plus 是一个局域网语音编程系统，让开发者通过实体按键说话来控制 AI 编码工具。系统由三部分组成：

- **ESP32 固件** — 运行在 S3 e-paper 4.2 寸墨水屏设备上，负责按键检测、PCM 录音、音频上行、状态显示
- **主机桥接服务** — Node.js 服务，负责语音转写（STT）、指令分发、CLI 会话管理、文本注入
- **macOS 桌面客户端** — Electron 应用，提供设备管理、待办管理、服务监控的图形界面

整个链路：**按住设备 BOOT 键说话 → 音频通过 WebSocket 上行 → 主机转写为文字 → 注入到当前活跃窗口（或发给 Codex/Claude CLI）→ 设备墨水屏显示实时状态**。

### 为什么做这个项目

日常编程时，用键盘输入中英混杂的技术描述效率很低。通过语音输入，说一句话就能把意图传达给 AI 编程工具。墨水屏设备作为专用终端，低功耗常亮，不用切换窗口。

---

## 项目结构

```
vibecoding-plus/
├── firmware/                    ESP32 固件
│   ├── main/                    固件源码（C++）
│   │   ├── lan_mic_app.cc       主应用逻辑（重连/录音/状态机）
│   │   ├── lan_mic_app.h        主应用头文件
│   │   ├── boards/              硬件抽象层（Zectrix S3）
│   │   ├── components/          自定义组件（WiFi/WebSocket/音频）
│   │   └── display/             墨水屏显示驱动
│   ├── releases/                预编译固件包（.zip）
│   ├── scripts/                 固件工具脚本
│   └── partitions/              分区表配置
│
├── client/
│   ├── server/                  主机桥接服务
│   │   ├── src/
│   │   │   ├── server.mjs       入口 — HTTP + WebSocket 服务器
│   │   │   ├── config.mjs       配置加载（.env 分层读取 + 运行时持久化）
│   │   │   ├── stt.mjs          语音转写（OpenAI / Volcengine / whisper.cpp）
│   │   │   ├── text-injector.mjs 文本注入（macOS AppleScript / Windows PowerShell）
│   │   │   ├── claude-session.mjs Claude Code CLI 会话管理
│   │   │   ├── codex-session.mjs  Codex CLI 会话管理
│   │   │   ├── todo-service.mjs   待办数据管理（CRUD + 离线缓存）
│   │   │   ├── todo-assistant.mjs 待办语音意图解析
│   │   │   ├── discovery-server.mjs LAN UDP 发现服务
│   │   │   ├── lan-auth.mjs       HMAC-SHA256 鉴权
│   │   │   ├── runtime-log.mjs    运行时日志（console + 文件双写）
│   │   │   └── admin-routes.mjs   管理 API（供桌面客户端调用）
│   │   ├── test/                测试（41 个用例）
│   │   └── scripts/             工具脚本（mock 客户端、诊断等）
│   │
│   └── desktop/                 macOS Electron 客户端
│       ├── main.mjs             主进程（窗口管理、IPC、tray）
│       ├── renderer.js          渲染进程（UI 交互）
│       ├── preload.cjs          预加载脚本（安全桥接）
│       ├── index.html           页面结构
│       ├── styles.css           样式
│       └── assets/              图标等资源
│
├── doc/                         文档
├── archive/                     归档（历史代码、上游文档）
├── package.json                 Node.js 项目配置
├── vibe-service.command         macOS 服务管理脚本（tmux）
└── .env.example                 配置模板
```

---

## 核心功能

### 语音输入与转写

- 16kHz 单声道 PCM16 音频采集
- 多 STT 引擎支持：OpenAI Whisper API、Volcengine ASR、whisper.cpp（本地）
- 转写延迟实时反馈到设备屏幕

### 发送目标

| 目标 | 说明 |
|------|------|
| `text_injector` | 转写文字通过剪贴板 + Cmd+V 注入当前活跃窗口 |
| `codex_exec` | 转写文字发送给 Codex CLI，解析 JSON 事件流 |
| `claude_code` | 转写文字发送给 Claude Code CLI，支持方案选择交互 |

### 交付模式

- **confirm_on_device**（默认）— 转写后暂存 pending，用户在设备端确认后发送。支持多段拼接和逐段撤销。
- **immediate** — 转写后立即发送到目标，适合快速连续输入。

### 待办管理

- 语音增删改查（"买牛奶"、"第二项改成开会"、"删除第三项"）
- 设备端物理按键选择、完成、删除
- 离线待办模式 — 断网时操作缓存本地，重连后自动同步
- 苹果提醒事项双向同步（通过 remindctl）

### 编程模式

- CLI 多方案返回时，设备端 UP/DN 选择方案，BOOT 应用
- 句级撤销 — pending 文本可逐段撤销，已注入文本可回退
- 墨水屏实时显示 CLI 状态（空闲/运行中/完成/错误）
- 滚动日志查看（8 行缓冲，UP/DN 翻页）

### 网络与安全

- LAN UDP 自动发现（设备广播 → 主机回复 WS 地址）
- 可选 HMAC-SHA256 鉴权（nonce 重放保护 + 时间窗口校验）
- 固件支持 Wi-Fi 配网（AP 模式 + 扫码/手动输入）

### 固件可靠性

- 非阻塞 UDP 发现（O_NONBLOCK + select()，避免 lwIP 阻塞卡死）
- 指数退避重连（2s → 15s 上限）
- 连续 3 次失败自动 WiFi 恢复（断开 → 清缓存 → 重连）
- 连接看门狗（20s 超时，先自动 WiFi 恢复，仍失败则提示用户）
- 深度睡眠省电 — 断线 5 分钟后自动休眠，BOOT 按钮或 15 分钟定时器唤醒

---

## 快速开始

### 环境要求

- Node.js >= 20
- macOS（文本注入需要授予辅助功能权限）
- ESP-IDF v5.5（仅编译固件时需要）

### 安装

```bash
git clone https://github.com/MaydayV/vibecoding-plus.git
cd vibecoding-plus
npm install
```

### 配置

```bash
cp .env.example .env
```

编辑 `.env`，至少配置一个 STT 密钥：

```bash
# OpenAI Whisper
OPENAI_API_KEY=sk-xxx

# 或 Volcengine ASR
# VOLCENGINE_APP_KEY=xxx
# VOLCENGINE_ACCESS_KEY=xxx

# 或 whisper.cpp 本地模型
# WHISPER_CPP_MODEL_PATH=/path/to/ggml-model.bin
```

### 启动桥接服务

```bash
npm start
```

启动后终端显示：

```
vibecoding-plus v0.2.11
  target     text_injector [auto]
  stt        openai · whisper-1
  todo       DeepSeek
  auth       off (set LAN_SHARED_SECRET to enable)
  ws         ws://0.0.0.0:8765
  discovery  udp://0.0.0.0:8766
  log        /path/to/logs/server-current.log
  cwd        /path/to/vibecoding-plus
```

### 桌面客户端

```bash
npm run desktop:dev          # 开发模式启动
npm run desktop:dist:mac     # 打包 DMG + ZIP
```

桌面客户端提供：
- 设备状态监控（连接状态、电量、信号）
- 待办管理面板（增删改查、苹果提醒同步）
- 服务指标（转写延迟、连接数）
- 深色/浅色主题切换
- 全局快捷键

### 诊断

```bash
npm run doctor
```

检查 STT 密钥、CLI 可用性、端口占用等。

---

## 配置参考

### 核心配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SEND_TARGET` | 自动检测 | `text_injector` / `codex_exec` / `claude_code` |
| `TRANSCRIPT_DELIVERY_MODE` | `confirm_on_device` | `confirm_on_device` / `immediate` |
| `TEXT_INJECTION_MODE` | `type_and_enter` | `type_and_enter` / `type_only` |
| `LAN_SHARED_SECRET` | 空（关闭） | 设置后启用 HMAC 鉴权 |
| `LAN_VOICE_PORT` | 8765 | WebSocket 端口 |
| `LAN_DISCOVERY_PORT` | 8766 | UDP 发现端口 |
| `CLI_TIMEOUT_SEC` | 300 | CLI 子进程超时 |
| `VIBE_LOG_DIR` | `./logs` | 运行时日志目录 |

### STT 配置（四选一）

| 引擎 | 变量 |
|------|------|
| OpenAI Whisper | `OPENAI_API_KEY` |
| Volcengine ASR | `VOLCENGINE_APP_KEY` + `VOLCENGINE_ACCESS_KEY` |
| whisper.cpp | `WHISPER_CPP_MODEL_PATH` |

### Claude Code 配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CLAUDE_COMMAND` | 自动检测 | claude 二进制路径 |
| `CLAUDE_CWD` | 项目根目录 | 工作目录 |
| `CLAUDE_ALLOWED_TOOLS` | `Read,Edit,Write,Bash,Glob,Grep` | 预批准工具列表 |
| `CLAUDE_MAX_TURNS` | 10 | 最大 agentic 轮次 |

### 苹果提醒事项同步

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REMINDERS_SYNC_ENABLED` | 0 | 设为 1 启用 |
| `REMINDCTL_PATH` | `remindctl` | remindctl 二进制路径 |
| `REMINDERS_LIST` | 空（全部） | 同步的提醒事项列表名 |
| `REMINDERS_POLL_SEC` | 15 | 轮询间隔（秒） |

### 调试标志

| 变量 | 说明 |
|------|------|
| `MOCK_TRANSCRIPT` | 跳过 STT，使用固定文本 |
| `DRY_RUN_TEXT_INJECTION` | 只打印日志，不真正输入 |
| `SAVE_DEBUG_WAV` | 保存音频到 tmp/ |

---

## 设备操作指南

### 编程模式

| 操作 | 说明 |
|------|------|
| 长按 BOOT | PTT 录音（按住说话，松开结束） |
| 单击 UP | 发送 pending 文本（confirm 模式） |
| 单击 DN | 撤销（pending 段或已注入文本） |
| 短按 BOOT | 发送回车（注入模式下） |
| 长按 UP | 打开菜单（切换模式/重连/重启/设置） |
| 双击 UP | 快速切换编程/待办模式 |

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

## 固件构建与烧录

### 环境准备

安装 [ESP-IDF v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/) 并激活环境。

### 编译

```bash
cd firmware
idf.py build
```

首次构建会自动下载 `managed_components/`（约 500MB），后续构建增量编译。

### 烧录

```bash
idf.py -p /dev/cu.usbmodem* flash
```

### 预编译固件

`firmware/releases/` 目录包含预编译的固件包，可直接烧录：

```bash
esptool.py --chip esp32s3 -p /dev/cu.usbmodem* write_flash 0x0 firmware/releases/v2.2.7_xxx.bin
```

### 鉴权同步

主机与固件若都开启鉴权，需保持共享密钥一致：

- 主机：`LAN_SHARED_SECRET`（.env）
- 固件：`CONFIG_LAN_SHARED_SECRET`（sdkconfig）

---

## 协议流程

```
设备                          主机
  │                            │
  │  ── UDP discover_host ──►  │  1. 设备发现
  │  ◄── discover_reply ────  │     （回复 WS 地址）
  │                            │
  │  ── WS connect ─────────►  │  2. 建立连接
  │  ── hello (HMAC) ───────►  │     鉴权握手
  │  ◄── hello_ack ─────────  │
  │  ◄── server_ready ──────  │     发送初始状态
  │                            │
  │  ── ptt_start ──────────►  │  3. 语音录入
  │  ── [binary PCM16] ─────►  │     音频流
  │  ── ptt_stop ───────────►  │
  │                            │
  │  ◄── transcript_final ───  │  4. 转写结果
  │                            │
  │  ── action_send ────────►  │  5. 确认发送
  │  ◄── status (typed) ────  │     （confirm 模式）
  │                            │
  │  ◄── cli_state ─────────  │  6. CLI 状态
  │  ◄── todo_state ────────  │     实时推送
```

### 音频格式

- 采样率：16kHz
- 位深：16-bit signed little-endian
- 声道：单声道

---

## 测试

```bash
npm test                       # 运行全部 41 个用例
node --test client/server/test/lan-auth.test.mjs  # 单个测试
```

测试覆盖：
- 鉴权签名校验、nonce 重放保护
- 待办 CRUD、语音意图解析
- 文本注入（macOS AppleScript）
- 服务端语音模式路由
- 配置加载与持久化
- CLI 投影格式化

---

## macOS 服务管理

`vibe-service.command` 提供 tmux 服务管理界面：

```bash
./vibe-service.command
# 1) 启动服务
# 2) 重启服务
# 3) 停止服务
# 4) 查看状态
# 5) 查看日志
# 6) 进入 tmux 会话
```

---

## 安全建议

- 不要提交 `.env`、API Key 等敏感信息到版本库
- 共享网络务必设置 `LAN_SHARED_SECRET` 启用鉴权
- 生产环境关闭 `DRY_RUN_TEXT_INJECTION` 和 `MOCK_TRANSCRIPT`
- 桌面客户端首次运行需授予辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）

---

## 致谢

基于上游项目 [vibecoding-voice](https://github.com/mac20777/vibecoding-voice) 二次开发，感谢上游作者与社区贡献。
