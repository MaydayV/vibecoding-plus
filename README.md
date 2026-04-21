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

### 苹果提醒事项 → 待办同步配置

依赖：
- macOS 已安装并可运行 `remindctl`
- 已授予提醒事项访问权限（首次会有系统权限提示）

推荐在管理页 `/admin` 的“提醒事项同步”里配置：
- 启用提醒事项同步
- `remindctl` 路径（例如 `/opt/homebrew/bin/remindctl`）
- 提醒事项列表（留空表示同步全部列表）
- 轮询秒数（最小 5）

对应环境变量：
- `REMINDERS_SYNC_ENABLED=1`
- `REMINDCTL_PATH=/opt/homebrew/bin/remindctl`
- `REMINDERS_LIST=提醒`（可留空）
- `REMINDERS_POLL_SEC=60`

验证方法：
1. 管理页点击“立即同步一次”
2. 查看 `/api/admin/todo-sync` 中 `status.lastError` 是否为空
3. 查看 `/api/admin/todos` 的 `snapshot.items` 是否包含 `source="apple"` 且有 `appleId`

常见问题：
- 看不到条目：先确认同步的是“未完成提醒事项”（已完成不会进入活动待办）
- 页面不更新：`Cmd/Ctrl+Shift+R` 强制刷新管理页
- 显示样式设置：进入 `/admin` 的“显示”页，选择白底黑字/黑底白字后点击“设置显示模式”；如需读取当前生效配置，点击“读取当前显示设置”
- 仍不同步：检查 `remindctl all --json` 与 `remindctl all --list "<列表名>" --json` 是否有数据

---

## 设备交互要点

- 按住 `BOOT`：录音
- 松开 `BOOT`：结束本段
- `UP`：发送待处理文本（confirm 模式）
- `DN`：撤销
  - 有 pending 时：撤销待发送段
  - 编程模式摘要页（normal）且无 pending 时：撤销上一句已注入文本

---

## 编程模式：逐功能使用说明

> 适用页面：设备 `Summary/编程` 页；服务端 `voiceMode=normal`。

### 1) 语音输入（PTT）
- **触发**：在编程页长按 `BOOT`（约 200ms 起录音）。
- **操作**：按住说话，松开结束。
- **结果**：
  - `confirm_on_device`：文本进入待发送（pending），屏幕提示可发送/撤销。
  - `immediate`：自动发送到目标（注入 / Codex / Claude）。

### 2) pending 文本发送（confirm 模式）
- **触发**：已有 pending 文本。
- **操作**：单击 `UP`（显示底栏 `UP发送`）。
- **结果**：发送当前合并后的 pending 文本；状态变为 `typed`。

### 3) 撤销 pending / 撤销上一句注入
- **触发**：
  - 有 pending 文本；或
  - 无 pending，但在编程页且发送目标为 `text_injector`。
- **操作**：单击 `DN`。
- **结果**：
  - 有 pending：撤销最后一段 pending；清空后回 `transcript_cleared`。
  - 无 pending：回退上一句已注入文本（按字符数 + 可选回车）。

### 4) 方案选择与应用（Plan options）
- **触发**：CLI 返回可选方案列表时。
- **操作**：`UP/DN` 选择方案，单击 `BOOT` 应用。
- **结果**：设备发送 `plan_select` / `plan_apply`，主机将“应用所选方案”的提示词发给 CLI。

### 5) 短按 BOOT 发送回车（仅注入目标）
- **触发**：`send_target=text_injector` 且编程页空闲（非 pending）。
- **操作**：短按 `BOOT`。
- **结果**：设备发送 `enter`，用于终端换行提交。

### 6) 编程页菜单
- **触发**：编程页长按 `UP`。
- **操作**：`UP/DN` 选项，`BOOT` 确认。
- **菜单项**：切换到待办、重新连接主机、重启设备、设置、返回。

---

## 待办模式：逐功能使用说明

> 适用页面：设备 `Todo/待办` 页；服务端 `voiceMode=todo`。

### 1) 切换到待办模式
- **操作**：
  - 双击 `UP` 在编程/待办页间快速切换；或
  - 编程页长按 `UP` 打开菜单，选择“切换到待办”。
- **结果**：设备发送 `set_mode: todo`，后续语音按待办意图解释。

### 2) 待办语音输入（增删改查）
- **触发**：待办页长按 `BOOT`。
- **操作**：按住说话，松开结束。
- **结果**：服务端将语音按待办命令解析并执行，返回 `todo_result` 与 `todo_state`。

### 3) 选择当前待办项
- **操作**：待办页 `UP/DN`。
- **结果**：切换当前选中项；在线时同步 `select_prev/select_next`。

### 4) 单击 BOOT：完成/取消完成
- **操作**：待办页短按 `BOOT` 一次（在双击窗口后生效）。
- **结果**：切换当前项完成状态（`toggle`）；离线时先本地缓存，重连后自动同步。

### 5) 双击 BOOT：删除当前项
- **操作**：待办页短按 `BOOT` 两次（双击窗口内）。
- **结果**：删除当前项（`delete`）；离线时先本地缓存，重连后自动同步。

### 6) 待办页菜单
- **触发**：待办页长按 `UP`。
- **操作**：`UP/DN` 选项，`BOOT` 确认。
- **菜单项**：标记完成/未完成、删除当前项、切换到编程、重新连接主机、重启设备、返回。

### 7) 离线待办模式
- **进入**：连接异常时可在“重连卡住”菜单选“进入离线待办”，或自动进入。
- **能力**：可继续选择、完成/删除待办，操作记为 pending。
- **恢复**：重连成功后自动 flush pending 操作并同步到主机。

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
