# vibecoding-plus

`vibecoding-plus` 是一个“设备端按键语音 + 主机端 AI 编码桥接”的二次开发项目：
用 ESP32 电子墨水设备说话，把语音转成文本后发送到编程环境，并把 AI 执行状态回显到设备屏幕。

## Fork 说明与致谢

- 本仓库基于上游项目 `vibecoding-voice` 进行二次开发。
- 感谢原作者与社区提供的开源基础与早期架构。
- 当前仅维护 **一个分支**：`feature/todo-list-mode`。

## 项目结构

项目由两部分组成：

1. **主机桥接服务（本仓库）**
   - Node.js 服务，接收 ESP32 设备上传的按键语音（WebSocket）
   - 进行 STT 语音识别
   - 将文本发送到：
     - 当前输入框（注入模式）
     - Codex CLI
     - Claude Code CLI

2. **ESP32 固件（`firmware/`）**
   - 运行在电子墨水屏开发板（如 Zectrix S3 / Waveshare S3）
   - 负责配网、录音、设备端确认交互、屏幕显示
   - 显示连接状态、编程摘要、日志片段、Todo 等

## 当前能力概览

- 设备按键语音输入（PTT）
- WebSocket 音频上传（16kHz PCM）
- STT 支持：Volcengine / OpenAI / whisper.cpp / qwen_asr（以当前配置为准）
- 注入模式（文本输入 + 可选回车发送）
- Codex 模式、Claude 模式
- Todo 列表页面（本地持久化、语音 CRUD）
- 编程页面（原 Live 页面命名统一为“编程”）
- 设备端多段语音累积：BOOT 追加、UP 发送、DN 撤销
- LAN 自动发现 + 鉴权（HMAC）
- Windows 桌面壳（托盘、开机启动、本地设置）

## 三种运行模式

- `vibe`：注入模式（默认推荐）
- `vibe codex`：Codex 会话模式
- `vibe claude`：Claude Code 会话模式

## 快速开始（主机端）

### 1）安装依赖

```bash
npm install
```

### 2）配置

```bash
vibe config
```

常见最小配置示例：

```env
STT_PROVIDER=volcengine
VOLCENGINE_APP_KEY=your-app-key
VOLCENGINE_ACCESS_KEY=your-access-key
TRANSCRIPT_DELIVERY_MODE=confirm_on_device
LAN_SHARED_SECRET=replace-with-a-long-random-secret
```

### 3）启动

```bash
vibe claude
```

或：

```bash
vibe codex
```

诊断命令：

```bash
vibe doctor
```

## 设备页面与操作

### 页面

- **编程页（Programming）**：语音发送到当前目标（注入 / Codex / Claude）
- **Todo 页**：语音进入待办解析与增删改查

### 常用按键逻辑

- 按住 `BOOT`：录音
- 松开 `BOOT`：结束当前段
- `UP`：发送累积文本
- `DN`：撤销上一段
- 长按 `UP`：打开当前页菜单
- 双击 `UP`：在编程页 / Todo 页快速切换

## Todo 语音示例

- `查看计划`
- `添加计划 买牛奶`
- `删除计划 2`
- `修改计划 2 改成 发版本`
- `完成计划 2`
- `取消完成计划 2`

## 固件编译与烧录

需要 ESP-IDF（建议 v5.5）。

```bash
cd firmware
idf.py build
```

烧录（示例）：

```bash
idf.py -p <串口> flash
```

关键配置（主机与固件需一致）：

```text
CONFIG_LAN_SHARED_SECRET="your-secret"
```

## 常用配置项

- `SEND_TARGET`：`text_injector` / `codex_exec` / `claude_code`
- `TRANSCRIPT_DELIVERY_MODE`：`immediate` / `confirm_on_device`
- `TEXT_INJECTION_MODE`：`type_only` / `type_and_enter`
- `LAN_SHARED_SECRET`：局域网鉴权密钥
- `TODO_INTENT_PROVIDER`：`rules` / `deepseek`

## 开发与测试

```bash
npm test
node --test test/lan-auth.test.mjs
node scripts/mock-client.mjs
```

## 安全说明

- 不要提交 `.env`、密钥或任何凭证
- 共享网络必须设置 `LAN_SHARED_SECRET`
- 使用第三方 STT 前请确认数据与隐私策略

## 许可与致谢

- 本项目延续并基于上游开源成果进行二次开发。
- 再次感谢原作者与所有贡献者。
