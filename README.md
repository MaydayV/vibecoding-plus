# vibecoding-plus

`vibecoding-plus` 是一个面向中文语音编程场景的主机桥接服务 + ESP32 固件项目。设备端负责 PTT 录音与显示，主机端负责语音识别、指令分发、CLI 会话与文本注入。

## 平台支持（当前状态）

| 能力 | Windows | macOS | Linux |
|---|---:|---:|---:|
| 主机桥接服务（Node.js） | ✅ | ✅ | ✅ |
| 文本注入（`text_injector`） | ✅（PowerShell） | ✅（AppleScript） | ❌ |
| 已注入文本句级撤销 | ✅ | ✅ | ❌ |
| Codex / Claude CLI 转发 | ✅ | ✅ | ✅（取决于本机 CLI 可用性） |
| 桌面壳（Electron 托盘） | ✅（仅打包 Win） | ⚠️ 开发可跑，未提供打包目标 | ⚠️ 开发可跑，未提供打包目标 |

结论：**现在不是只支持 macOS，Windows 可以部署并正常使用**。如果你使用的是注入模式（`text_injector`），目前仅支持 Windows / macOS。

---

## 核心功能

- ESP32 设备端 PTT 录音（16kHz PCM16）
- WebSocket 音频上行 + 实时状态同步
- STT 提供方支持：
  - `qwen_asr`（实时 WS）
  - `openai`（Whisper API）
  - `volcengine`
  - `whisper_cpp`
- 三种发送目标：
  - `text_injector`
  - `codex_exec`
  - `claude_code`
- 两种转写交付模式：
  - `confirm_on_device`（设备确认发送）
  - `immediate`（转写后立即发送）
- 编程模式撤销：
  - 待发送状态可撤销 pending 段
  - `immediate + text_injector` 下支持“撤销上一句已注入文本”
- Todo 语音操作（增删改查、完成/取消）
- LAN 自动发现 + 可选 HMAC 鉴权
- 固件 NFC：
  - Wi‑Fi 配网模式写入配网页 URI
  - 连上服务后写入管理页 `/admin` URI

---

## 快速开始（主机服务）

### 1) 环境要求

- Node.js >= 20
- npm
- （可选）`@anthropic-ai/claude-code`
- （可选）`@openai/codex`

安装依赖：

```bash
npm install
```

### 2) 初始化配置

```bash
vibe config
```

> 会写入用户配置文件（`~/.vibecoding-plus/config.env` 或 Windows 对应目录）。

### 3) 启动

```bash
# 注入模式
vibe inject

# Codex 模式
vibe codex

# Claude 模式
vibe claude
```

也可以直接：

```bash
npm start
```

### 4) 诊断

```bash
npm run doctor
# 或
node src/server.mjs --doctor
```

---

## Windows 部署建议

1. 安装 Node.js 20+
2. `npm install`
3. `vibe config` 配置 STT 与密钥
4. `vibe inject`（或 `vibe codex` / `vibe claude`）
5. 确保 PowerShell 可用（注入模式依赖）

如需桌面壳：

```bash
npm run desktop:dev
npm run desktop:dist
```

---

## macOS 部署建议

1. 安装 Node.js 20+
2. `npm install`
3. `vibe config`
4. `vibe inject` / `vibe codex` / `vibe claude`
5. 首次注入需授予系统辅助功能权限（AppleScript/System Events）

---

## 关键配置项（与当前代码一致）

- `SEND_TARGET`：`text_injector` / `codex_exec` / `claude_code`
- `TRANSCRIPT_DELIVERY_MODE`：`confirm_on_device`（默认）/ `immediate`
- `TEXT_INJECTION_MODE`：`type_and_enter`（默认）/ `type_only`
- `LAN_SHARED_SECRET`：启用 HMAC 鉴权
- `LAN_TRUST_LOCALHOST=1`：本机回环地址可跳过鉴权（测试用）
- `DRY_RUN_TEXT_INJECTION=1`：只打印注入日志，不真正输入
- `CLI_TIMEOUT_SEC`：CLI 调用超时（默认 300）

STT 相关（四选一）
- `QWEN_ASR_MODEL` + `QWEN_ASR_API_KEY` + `QWEN_ASR_REALTIME_BASE_URL`
- `OPENAI_API_KEY`
- `VOLCENGINE_APP_KEY` + `VOLCENGINE_ACCESS_KEY`
- `WHISPER_CPP_MODEL_PATH`

---

## 设备交互要点

- 按住 `BOOT`：录音
- 松开 `BOOT`：结束本段
- `UP`：发送待处理文本（confirm 模式）
- `DN`：撤销
  - 有 pending 时：撤销待发送段
  - 编程模式摘要页（normal）且无 pending 时：撤销上一句已注入文本

---

## 固件构建与烧录

建议 ESP-IDF v5.5：

```bash
cd firmware
idf.py build
idf.py -p <串口> flash
```

主机与固件若都开启鉴权，需保持共享密钥一致：

```text
LAN_SHARED_SECRET / CONFIG_LAN_SHARED_SECRET
```

---

## 测试

```bash
npm test
```

---

## 安全建议

- 不要提交 `.env`、API Key、私钥等敏感信息
- 共享网络请务必设置 `LAN_SHARED_SECRET`
- 在生产环境关闭 `DRY_RUN_TEXT_INJECTION`

---

## 致谢

本仓库基于上游项目 [`vibecoding-voice`](https://github.com/mac20777/vibecoding-voice) 进行二次开发，感谢上游作者与社区贡献。
