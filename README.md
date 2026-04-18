# vibecoding-plus

`vibecoding-plus` 是一个面向中文语音编程场景的二次开发项目：
通过 ESP32 电子墨水设备进行按键语音输入（PTT），由主机桥接服务完成语音识别与指令分发，再将 AI 编程过程回显到设备屏幕。

## Fork 说明与致谢

- 本仓库基于上游项目 [`vibecoding-voice`](https://github.com/mac20777/vibecoding-voice) 进行二次开发。
- 感谢上游作者与社区提供的开源基础、架构思路与早期实现。
- 当前仓库仅维护 **一个分支**：`todo-vibe`。

## 这个项目解决什么问题

- 不抢占电脑麦克风工作流：用独立设备进行语音输入
- 不打断键盘操作：设备端按键录音，主机端自动注入/转发
- 支持多种目标：普通输入框、Codex CLI、Claude Code CLI
- 设备端可见：连接状态、编程摘要、日志片段、Todo 状态

## 项目架构

项目由两部分组成：

1. **主机桥接服务（本仓库）**
   - Node.js 服务，通过 WebSocket 接收设备上传音频
   - 调用 STT（语音识别）将语音转文本
   - 把文本发送到对应目标：
     - 文本注入（当前输入框）
     - Codex CLI 会话
     - Claude Code CLI 会话
   - 维护 Todo 数据、会话状态、设备同步

2. **ESP32 固件（`firmware/`）**
   - 支持电子墨水开发板（如 Zectrix / Waveshare）
   - 负责配网、按键录音、显示渲染、设备端交互
   - 支持页面切换（编程页 / Todo 页）和本地状态显示

## 功能总览

- 设备端 PTT 录音 + 主机端 WebSocket 音频接收
- 16kHz PCM 音频链路
- STT 提供方支持（以当前配置为准）：
  - Volcengine
  - OpenAI
  - whisper.cpp
  - qwen_asr
- 三种运行模式：注入 / Codex / Claude
- Todo 页面（本地持久化 + 语音 CRUD）
- 编程页面（原 Live 命名已统一为“编程”）
- 多段语音累积：BOOT 追加、UP 发送、DN 撤销
- LAN 自动发现 + HMAC 鉴权
- Windows 桌面壳（托盘、开机启动、设置页）

## 三种运行模式

- `vibe`：注入模式（默认推荐）
- `vibe codex`：Codex 会话模式
- `vibe claude`：Claude Code 会话模式

## 快速开始（主机端）

### 1）安装

```bash
npm install
```

### 2）初始化配置

```bash
vibe config
```

最小配置示例（Volcengine）：

```env
STT_PROVIDER=volcengine
VOLCENGINE_APP_KEY=your-app-key
VOLCENGINE_ACCESS_KEY=your-access-key
TRANSCRIPT_DELIVERY_MODE=confirm_on_device
LAN_SHARED_SECRET=replace-with-a-long-random-secret
```

### 3）启动服务

```bash
vibe claude
```

或：

```bash
vibe codex
```

或注入模式：

```bash
vibe
```

### 4）诊断

```bash
vibe doctor
```

## 设备页面与按键说明

### 页面语义

- **编程页（Programming）**：语音发送到当前目标（注入 / Codex / Claude）
- **Todo 页**：语音进入待办命令解析和增删改查

### 常用按键

- 按住 `BOOT`：录音
- 松开 `BOOT`：结束当前段
- `UP`：发送已累积文本
- `DN`：撤销上一段
- 长按 `UP`：打开当前页菜单
- 双击 `UP`：在编程页 / Todo 页间快速切换

## Todo 语音命令示例

- `查看计划`
- `添加计划 买牛奶`
- `删除计划 2`
- `修改计划 2 改成 发版本`
- `完成计划 2`
- `取消完成计划 2`

## 固件编译与烧录

建议 ESP-IDF v5.5：

```bash
cd firmware
idf.py build
```

烧录示例：

```bash
idf.py -p <串口> flash
```

主机与固件需要一致的关键配置：

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

## 常见问题（FAQ）

- **语音转写正常，但没有自动发送回车**  
  检查 `TEXT_INJECTION_MODE=type_and_enter`。

- **设备无法连回主机**  
  检查主机服务是否启动、局域网是否可达、`LAN_SHARED_SECRET` 是否一致。

- **Todo 语音没有进入待办逻辑**  
  确认当前在 Todo 页，而不是编程页。

- **改了配置不生效**  
  检查是否被本地 `.env` 覆盖，运行 `vibe doctor` 诊断。

## 安全说明

- 不要提交 `.env`、密钥或任何凭证
- 共享网络必须设置 `LAN_SHARED_SECRET`
- 使用第三方 STT 前请确认其数据与隐私策略

## 许可与致谢

- 本项目遵循上游开源精神，在上游基础上持续演进。
- 再次感谢上游作者与所有贡献者。
