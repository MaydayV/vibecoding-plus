# vibecoding-plus 系统评估与修复优化报告

> 评估日期：2026-07-03 · 分支：`todo-vibe`（基于 `4ab4c06`）
> **修复执行：2026-07-03** — 阶段 0 止血项 + P1-1/2/3 已完成；固件已于 `/dev/cu.usbmodem1101` 刷写验证（`idf.py build` + `flash` 通过）
> 范围：macOS 原生客户端（`client/macos-native/`，约 10,200 行 Swift）+ ESP32 设备固件（`firmware/main/`，核心 `lan_mic_app.cc` 4,039 行）
> 参考：[open-vibe-island](https://github.com/Octane0411/open-vibe-island) Agent 观测方法对比见 **§8**
> 方法：全量通读活跃代码路径 + 对可疑点逐一交叉验证（grep 确认生产者/消费者是否成对存在）

---

## 0. 总体判断

**架构方向正确，功能面铺得广，但可靠性根基薄。**

- Swift 原生内嵌服务端替代 Node 的重构方向正确、模块划分清晰；固件的离线待办与重连状态机有产品级打磨痕迹。
- 但存在两类系统性问题（**2026-07-03 阶段 0 已修复**，待真机长期 soak）：
  1. ~~Node → Swift 移植遗留 4 个"静默失效"回归~~ → P0-1～P0-4 ✅；
  2. ~~固件跨任务无锁~~ → P0-5 ✅，已 USB 刷写验证。
- 两类问题的共同根源：**活跃代码库测试覆盖为零**。`archive/server/test/` 的 16 个测试随 Node 端退役，Swift 无测试 target，固件无 host 测试。移植回归就是没有测试网的直接证据。

**建议的行动顺序**：先做 §5 阶段 0 止血（约 1-2 周，包含固件并发重构），再建测试网，然后进入产品化。

---

## 1. 第一性原理：核心回路与公理

剥掉所有功能，产品是一条链路和一面镜子：

```
按下 BOOT → 说话 → (WiFi/WS) → Mac 转写 → 注入文本 / 驱动 AI CLI / 操作待办
                                     ↓
                     e-paper = 系统状态的"镜子" + 离线待办便签
```

由此推出四条"必须成立"的公理：

| 公理 | 含义 | 现状（2026-07-03 后） |
|---|---|---|
| A. 按下必有回应 | PTT 回路端到端可靠，失败可解释 | ★★★★ STT 路由/CLI 连续性已修；待真机端到端回归 |
| B. 屏幕永远说真话 | 设备显示与实际状态一致 | ★★★★ 固件队列化后主循环单线程改状态；待长期 soak |
| C. 数据不丢 | 待办离线可用、重连后收敛 | ★★★★ 未动，仍是最稳部分 |
| D. 装上就能用 | 配对、权限、分发无摩擦 | ★★ OTA/NFC 配对/公证仍缺，见 §5.2 |
| **E. 只镜像、不代管** | 客户端/设备**不**审批权限、**不**改 Claude/Codex 交互模式；权限与 plan/permission 模式以各软件自身配置为准 | ★★★ 产品边界（2026-07-03 确认）；见 §6.1 |

---

## 2. macOS 客户端评估

### 2.1 做得好的地方

- **模块边界清晰**：`NativeServer.swift` 作为 actor 编排器，STT / 注入 / CLI / Todo / Reminders 各自独立，替代了 Node 时代 2,400 行的 `server.mjs`。
- **自实现 WS 服务器干净**：基于 Network.framework，握手/帧解析/每连接串行写队列设计合理，实现真正零依赖单 .app。
- **权限工程化**：辅助功能引导、麦克风申请、EnvironmentChecker 一键安装等"脏活"已经做完。

### 2.2 问题清单

#### P0-1 · UI 选择的 STT 提供商不生效 ✅ 已修复

**位置**：`Services/STTService.swift`

**完成状态（2026-07-03）**：`resolveProvider()` 优先读 `config.sttProvider`；转写前写服务日志。见 §7。

`resolveProvider()` 只读**进程环境变量** `STT_PROVIDER`（GUI 应用从 Finder 启动几乎不可能有），然后按 key 存在性推断，优先级固定 qwen > openai > volcengine。UI 设置的 `config.sttProvider` 只参与状态**展示**（`resolvedSttProvider`），不参与实际路由。

**后果**：同时配置多个 key 的用户，UI 选 OpenAI，实际走 Qwen，且界面显示的还是 OpenAI。

**修复**（一行核心改动）：

```swift
private func resolveProvider() -> STTProvider {
    // 1. UI/config.env 显式配置最优先
    let configured = config.sttProvider.trimmingCharacters(in: .whitespaces).lowercased()
    if let provider = STTProvider(rawValue: configured) { return provider }
    // 2. 环境变量（调试用）
    if let explicit = ProcessInfo.processInfo.environment["STT_PROVIDER"],
       let provider = STTProvider(rawValue: explicit.lowercased()) { return provider }
    // 3. 按 key 推断（保持原逻辑）
    ...
}
```

同时建议把推断结果回写日志（`appendServiceLog("STT 实际提供商: \(provider)")`），让展示与实际永远一致。

#### P0-2 · Claude 会话连续性完全失效 ✅ 已修复

**位置**：`Services/CLISessionManager.swift`

**完成状态（2026-07-03）**：`lastCwd` 比较 + `--resume <sessionId>`。见 §7。

```swift
// Reset session if CWD changed (mirrors Node.js behavior)
if let existing = sessionId, !existing.isEmpty, !config.claudeCwd.isEmpty {
    sessionId = nil
}
```

注释说"CWD 变了才重置"，但代码没存旧 CWD、没做比较——只要 `claudeCwd` 非空（典型配置），**每次启动都清空 sessionId**，`--continue` 永远不会被加上，每条语音指令都是全新的、无上下文记忆的 Claude 会话。对"对着设备连续对话改代码"的核心场景是致命的。

**修复**：补上 CWD 比较，并改用语义更精确的 `--resume <id>`（`--continue` 是"该目录最近会话"，若用户同时在终端用 claude 会串台；Codex 侧的 `exec resume <threadId>` 就是正确示范）：

```swift
private var lastCwd: String?

// start() 内：
if let existing = sessionId, !existing.isEmpty,
   let last = lastCwd, last != config.claudeCwd {
    sessionId = nil          // 仅在 CWD 真的变化时重置
}
lastCwd = config.claudeCwd

// 参数拼装：
if let sid = sessionId, !sid.isEmpty {
    arguments += ["--resume", sid]
}
```

#### P0-3 · 方案选择（plan_options）无生产者 ✅ 已修复（方案 B）

**位置**：`NativeServer.swift` ↔ `lan_mic_app.cc` plan UI

**完成状态（2026-07-03）**：采用方案 B，`PlanOptionsExtractor.swift` 在 CLI 完成后填充 `planOptions` 并 `emitPlanOptions`。固件 UI 无需改动。

**产品边界（2026-07-03）**：设备端**不做**权限/方案审批，也不通过客户端改写 Claude/Codex 交互模式（公理 E）。`plan_*` 为历史实现，**不在路线图上扩展**；后续可考虑方案 A 删除固件 plan UI 与 `plan_apply` handler，避免与「只读镜像」定位冲突。

#### P0-4 · 配额显示（5H/7d）无生产者 ✅ 已修复

**位置**：固件 quota 渲染 ↔ Swift `broadcastCliState`

**完成状态（2026-07-03）**：`CLIRateLimits.swift` 移植 Node 逻辑，`cli_session_state` 带 `quota5hRemainingPct` / `quotaWeekRemainingPct`。与 [open-vibe-island](https://github.com/Octane0411/open-vibe-island) 同源（Codex rollout `token_count` + Claude statusline 缓存）；Claude 侧由用户自行配置 statusline，见 **§8.5 方案 D3**、公理 E。

**修复**：把 archive 的两个 rate-limits 模块逻辑移植为 Swift（读取 `~/.codex/sessions/*.jsonl` 与 Claude 对应数据源），在 `broadcastCliState()` payload 中带上两个字段；或与 P0-3 方案 A 一样先删固件 UI。移植工作量约半天。

#### P1-1 · WS 帧解析器遇分片帧永久卡死连接 + 无载荷上限 ✅ 已修复

**位置**：`Server/WebSocketServer.swift`

**完成状态（2026-07-03）**：`protocolError` fail-fast 关连接；帧 ≤4MB；upgrade header ≤16KB。

- text/binary 帧要求 FIN=1，否则 `return nil`——但 `nil` 同时是"数据不够"的信号，解析循环 break 后**这些字节永远留在缓冲区头部**，连接假活。任何标准 WS 客户端发一个分片消息就会踩中。
- `payloadLen` 无上限；HTTP upgrade 阶段 header 累积也无上限（`:323-356`）——均发生在认证前，LAN 内任意设备可让服务端无限缓冲。

**修复**：把"数据不够"与"协议错误"区分开，协议错误立即关连接；加上限：

```swift
enum ParseOutcome { case needMoreData; case message(WSFrameMessage); case protocolError(String) }

private let maxFramePayload = 4 * 1024 * 1024      // > lanAudioMaxBytes 即可
private let maxUpgradeHeaderBytes = 16 * 1024

// parseOne 内：
guard payloadLen <= maxFramePayload else { return .protocolError("frame_too_large") }
if opcode == 0x00 || ((opcode == 0x01 || opcode == 0x02) && (byte0 & 0x80) == 0) {
    return .protocolError("fragmentation_unsupported")   // 或实现分片重组
}
// feed() 收到 .protocolError → conn.close()
```

（完整做法是实现 RFC 6455 分片重组，工作量约半天；fail-fast 关闭是可接受的中间态，因为唯一一方客户端是固件且不分片。）

#### P1-2 · hello 时间戳新鲜度被绕过，5 分钟后可重放 ✅ 已修复

**位置**：固件 `SendHello` ↔ `NativeServer.handleHello`

**完成状态（2026-07-03）**：挑战-响应 `auth_challenge` / `authServerNonce`；签名 `hello|deviceId|boardType|serverNonce|deviceNonce`。无 secret 时仍可无 auth 连接。

防重放只剩 nonce 缓存，而 `pruneRecentHelloNonces()` 300 秒清理——LAN 嗅探者拿到一条 hello，**等 5 分钟重放即可通过认证**。威胁模型是家庭局域网、严重性低，但 HMAC 体系因此名存实亡。

**修复（推荐挑战-响应，一次改对）**：

1. 设备 WS 连上后，服务端先发 `auth_challenge {serverNonce}`；
2. 设备回 hello，签名改为 `HMAC(secret, "hello|deviceId|boardType|serverNonce|deviceNonce")`；
3. 服务端校验自己刚发的 serverNonce → 重放天然不可能，且不再依赖设备时钟。

替代（改动更小）：设备侧改用 PCF8563 RTC 的真实 epoch（板上有 RTC 且已用于待办时钟显示），服务端保持现有校验。缺点是依赖 RTC 已被正确设置。

#### P1-3 · CLI `isRunning` 跨线程读写 ✅ 已修复

**完成状态（2026-07-03）**：`NSLock` 保护 `isRunning`（`@MainActor` 与 `NativeServer` actor 初始化冲突，改用锁）。

**修复**：两个 Manager 标注 `@MainActor`（其状态本来就全在 main queue 变更），NativeServer 侧调用点改 `await`；或引入内部锁。前者更符合当前代码走向。

#### P2（维护性/体验，择机处理）✅ 客户端项已完成

| 问题 | 位置 | 建议 | 状态 |
|---|---|---|---|
| undo 错误被吞 + 错误日志标签 | `NativeServer.swift` | 改为 `appendServiceLog("undo 注入失败: …")` 并向设备回 `input_error` | ✅ |
| undo 按 `String.count` 逐字符退格 | `NativeServer.swift` / `TextInjector.swift` | 按**上一段**字素簇计数 + README 局限说明 | ✅ |
| 剪贴板注入竞态与隐私 | `TextInjector.swift` / `README.md` | README §隐私说明；串行队列已有 | ✅ |
| `Data(chunks.flatMap)` 双重拷贝 | `NativeServer.swift` | `reduce(into:)` | ✅ |
| `Views.swift` 2,407 行单文件 | `Views/` | 拆为 13 个文件 | ✅ |
| 全栈 `[String: Any]` 弱类型协议 | — | 见 §4 / §5.2 方案 C | ⏳部分（`doc/protocol.yaml` + 代码生成 ✅；NativeServer 仍用手写 key） |

---

## 3. ESP32 固件评估

### 3.1 做得好的地方

- **重连状态机是产品级的**：指数退避（2s→15s）、连续失败后 WiFi 栈级恢复（DHCP 重启）、20s 连接看门狗、卡死人工菜单、断连深睡节电（BOOT/15 分钟定时唤醒）。
- **离线待办是正确的本地优先设计**：NVS 快照 + pending ops 队列（toggle/delete 去重合并，`lan_mic_app.cc:2026-2086`）+ 重连 flush。
- **900ms 预滚动缓冲**解决"按下瞬间已开口"的吞字问题。

### 3.2 问题清单

#### P0-5 · 跨任务共享状态完全无锁 ✅ 已修复

**位置**：`lan_mic_app.cc`（`HandleServerMessage` / WiFi 回调 / `UpdateDisplay`）

**完成状态（2026-07-03）**：`server_msg_queue_` + `net_event_queue_` + `DrainPendingEvents()`；2026-07-03 USB 刷写 `idf.py build` + `flash` 通过。

std::string/vector 并发写是未定义行为——症状恰是**偶发花屏、显示错乱、随机崩溃**，难以复现。

**修复（推荐"单一状态所有者"重构，约 1-2 天）**：

WS/WiFi 回调只做投递，所有状态变更与 `UpdateDisplay()` 只发生在主循环任务：

```cpp
// lan_mic_app.h
struct PendingServerMessage { char* data; size_t len; };
QueueHandle_t server_msg_queue_;   // xQueueCreate(16, sizeof(PendingServerMessage))

// OnData（WS 任务）—— 只拷贝 + 投递：
ws_->OnData([this](const char* data, size_t len, bool binary) {
    if (binary || data == nullptr || len == 0) return;
    auto* copy = static_cast<char*>(malloc(len));
    if (copy == nullptr) return;
    memcpy(copy, data, len);
    PendingServerMessage item{copy, len};
    if (xQueueSend(server_msg_queue_, &item, 0) != pdPASS) {
        free(copy);  // 队列满：丢弃（服务端会重发状态快照）
        ESP_LOGW(kTag, "server msg queue full, dropped");
    }
});

// Run() 主循环每 tick 开头统一消费：
PendingServerMessage item;
while (xQueueReceive(server_msg_queue_, &item, 0) == pdPASS) {
    HandleServerMessage(item.data, item.len);   // 现在跑在主循环任务上
    free(item.data);
}
```

WiFi 事件回调同理改为投递 `enum NetworkEventMsg + std::string`（或复用同一队列的变体类型）。改造后：`UpdateDisplay()` 全部调用点收敛到主循环，一整类 heisenbug 连根拔掉。`OnDisconnected` 已有的 `ws_disconnected_pending_` 原子标志就是这个模式的雏形——把它推广到所有回调即可。

#### P0-6 · `vTaskDelete` 强杀连接任务 ✅ 已修复

**位置**：`lan_mic_app.cc` `RequestReconnect`

**完成状态（2026-07-03）**：移除 `vTaskDelete`；`connect_cancel_requested_` + WS 3s 握手超时；`connect_task_handle_` 改 `std::atomic`。

被杀任务此刻可能持有 lwIP / mbedTLS / heap 分配器内部锁 → 后续网络操作死锁、内存泄漏；紧接着 `ws_.reset()` 还可能释放被杀任务半构造中的对象（UAF）。

**修复**：彻底移除 `vTaskDelete` 路径。`connect_cancel_requested_` 协作取消机制已存在，补齐它的最后一公里——让 `EnsureWebSocketConnected()` 内部的阻塞点带超时：

- `DiscoverServerUri()` 已用 select + 600ms 超时 ✔
- `ws_->Connect()`：给 esp-ml307/esp WebSocket 的 connect 配置 socket 级 connect/handshake 超时（lwIP `SO_RCVTIMEO`/`SO_SNDTIMEO` 或组件自带 timeout 参数），确保单次 Connect 有界（例如 8s）；
- 循环间隙检查 `connect_cancel_requested_` 提前返回。

Connect 有界后，20s 看门狗只需等任务自然退出，无需强杀。

#### P1-4 · 用户正在使用的设备会突然黑屏深睡 ✅ 已修复

**位置**：`lan_mic_app.cc` 深睡条件

**完成状态（2026-07-03）**：`last_user_input_ms_` + `TouchUserInput`；`idle_anchor = max(disconnected_since, last_user_input)`。

**修复**（几行）：

```cpp
int64_t last_user_input_ms = now_ms;   // Run() 局部，随 disconnected_since_ms 维护
// 任一按键事件处（up/down click、BOOT press/release）：
last_user_input_ms = now_ms;
// 深睡条件改为：
const int64_t idle_anchor_ms = std::max(disconnected_since_ms, last_user_input_ms);
if (... && (now_ms - idle_anchor_ms) >= kNoConnectionSleepMs) { EnterOfflineDeepSleep(); }
```

#### P1-5 · 持续预滚动采集是续航杀手 ✅ 已修复

**位置**：`lan_mic_app.cc` 主循环预滚动

**完成状态（2026-07-03）**：空闲预滚动仅 `battery_charging_ || !battery_known_`；按下 BOOT 仍立即采集。

**修复（按性价比排序）**：

1. **充电时才开预滚动**（一行条件，`battery_charging_` 现成可用）：`const bool preroll_allowed = battery_charging_;` 电池模式下按下 BOOT 沿立即启动采集（损失 ~1s 预滚动，换数倍待机）；
2. 或设置页加"省电模式"开关让用户选；
3. 或降档：空闲时 codec 挂起，GPIO 按下中断唤醒 codec（启动延迟实测通常 <100ms，配合服务端已有的容错足够）。

#### P1-6 · 其余并发/阻塞点 ✅ 已完成

| 问题 | 位置 | 修复 | 状态 |
|---|---|---|---|
| `connect_task_handle_` 非原子跨任务读写 | `lan_mic_app.cc` | 改 `std::atomic<TaskHandle_t>` | ✅ |
| `PlayBeep` 在 WS 任务上同步播放 | `lan_mic_app.cc` | P0-5 后主循环执行 | ✅ |
| 每条 `todo_state` 都同步写 NVS | `lan_mic_app.cc` | 500ms 去抖 / 内容变化才写 | ✅ |

#### P2（维护性）✅ 拆分、outbound JSON、按键驱动已完成

- ~~`lan_mic_app.cc` 单文件巨石~~ ✅ 拆为 6 模块（见上）。
- ~~**三套按键机制并存**~~ ✅ `GpioInputDriver`（UP/DOWN 单击/双击/长按）+ `DeferredTapTracker`（BOOT 短按/双击延迟判定）；移除 `Button` 长按回调与手工 GPIO FSM 重复路径。
- ~~`snprintf` 手拼 JSON~~ ✅ outbound 改 cJSON。

---

## 4. 协议层：缺一个"宪法" ⏳ 部分完成

协议本身（hello/ptt/transcript/todo/cli_state）简洁合理，问题在治理：

- **无版本号**：固件与客户端分别升级后，没有机制发现"对面说的是旧方言"。plan/quota 死功能本质就是版本漂移未被察觉。
- **无单一事实来源**：每个字段名在固件（C 字符串）、NativeServer（字典 key）、AppState（再解一遍）手写三次。

**修复建议**：

1. ~~新建 `doc/protocol.md`~~ ✅ **2026-07-03** 已撰写。
2. ~~`hello` / `server_ready` 加 `protocolVersion: 1`~~ ✅ Swift `LANProtocol.version` + 固件 `kProtocolVersion` 校验。
3. 中期：一份 YAML 定义 → 脚本生成 Swift 常量 enum + C++ header，消灭手写字符串（一天，可放阶段 2）。

---

## 5. 修复路线图

### 阶段 0 · 止血（1-2 周）— **2026-07-03 已完成**

| # | 事项 | 工作量 | 对应问题 | 状态 |
|---|---|---|---|---|
| 1 | STT provider 路由读 config | 0.5h | P0-1 | ✅ |
| 2 | Claude 会话 `--resume` + CWD 比较 | 0.5d | P0-2 | ✅ |
| 3 | plan/quota 补齐 | 0.5-1d | P0-3/4 | ✅ |
| 4 | **固件消息队列化重构（单一状态所有者）** | 1-2d | P0-5 | ✅ |
| 5 | 移除 `vTaskDelete`，Connect 带超时 + 协作取消 | 1d | P0-6 | ✅ |
| 6 | 深睡计时按键重置 | 0.5h | P1-4 | ✅ |
| 7 | 预滚动仅充电时开启 | 1h | P1-5 | ✅ |

### 阶段 1 · 建立验证能力（2-4 周）⏳ 部分完成

- **Swift XCTest target** ✅：`VibeCodingPlusNativeTests` — WS 帧解析、HMAC、STT provider、`CodexRolloutParser`、`ClaudeTranscriptParser`（10 tests，`npm run native:test`）。
- **固件 host 测试** ⏳：协议解析、待办缓存合并、UTF-8 折行（P0-5 队列化已解耦，便于抽取）。
- **协议冒烟** ✅：`scripts/mock-client.mjs`（`npm run protocol:smoke`，需 NativeServer 运行 + `MOCK_TRANSCRIPT`）。
- ~~P1-1 / P1-2 / P1-3~~：已在阶段 0 提前完成（见各标题 ✅）。
- **D1/D2 旁路观测** ✅：`CodexRolloutParser` + `ClaudeTranscriptParser` + `NativeServer` 2s 轮询（仅 CLI 空闲时）。

### 阶段 2 · 产品化（1-2 月）⏳ 大部分完成（待真机 E2E）

1. **签名与公证** ⏳：Developer ID + notarization + Sparkle（需 Apple 开发者账号）。
2. **固件 OTA** ✅代码：`firmware_check` → `firmware_offer` → 进度 UI；待 USB 刷机 E2E。
3. **NFC 碰一碰配对** ✅代码：`pairCode` + `pairToken` + `provision_secret` + UI；待真机验证。
4. **协议 v1 定版** ✅：`doc/protocol.yaml` 代码生成 + `transcript_partial` / `firmware_check_result`。
5. **仓库卫生** ⏳：`dist-native/`、`archive/`、`firmware/releases/` 移出主干。

### 5.2 阶段 2 补全方案（原先仅列标题）

#### 方案 A · macOS 设置页推送固件 OTA

**前提（已满足）**：`partitions/v2/16m.csv` 含 `ota_0` / `ota_1` / `otadata`（各 0x3f0000）。

**协议（WS，建议 v1）**：

| 消息 | 方向 | 字段 | 语义 |
|---|---|---|---|
| `firmware_check` | Mac→设备 | `version`, `sha256`, `size` | 询问是否需要升级 |
| `firmware_offer` | Mac→设备 | `url`, `version`, `sha256`, `size` | 提供 LAN HTTP URL 或后续分片升级 |
| `firmware_progress` | 设备→Mac | `phase`, `pct`, `error` | `download` / `verify` / `flash` / `reboot` |
| `firmware_result` | 设备→Mac | `ok`, `version`, `message` | 终态 |

**Mac 端（设置页新面板「设备固件」）**：

1. 读取 `firmware/build/xiaozhi.bin` 或用户选的 `.bin`；计算 SHA256 + 读取 `PROJECT_VER`。
2. 启动临时 HTTP（`127.0.0.1:8767/firmware.bin`，仅 LAN 可访问）或使用已有 discovery 端口旁路。
3. 对已连接设备发 `firmware_offer`；UI 显示进度条（订阅 `firmware_progress`）。

**固件端**：

1. 新建 `app_ota.cc`：`esp_https_ota` 或 `esp_ota_ops` + 自定义 HTTP 客户端拉取 URL。
2. 在 `HandleServerMessage` 处理 `firmware_offer`；下载到非运行分区 → 校验 SHA256 → `esp_ota_set_boot_partition` → 重启。
3. 升级期间拒绝 PTT（`phase_ = Upgrading`），屏幕显示进度。

**工作量**：约 3–5 天（含真机断点续传与失败回滚测试）。

#### 方案 B · NFC 碰一碰配对

**B.0 现状（2026-07-03）**：NFC **未被 P0-5 破坏**。`WriteNfcUriIfNeeded` 未改；触发点改为 `HandleWsConnected` / `HandleNetEvent`，仍在主循环执行。刷写后待验证：连上 Mac 后 NFC 标签应写入 admin URL。

**B.1 配对流程（待做）**：

1. Mac 设置页显示 6 位 `pairingCode` + `discoveryHostId`；UDP discovery 回复带 `pairToken`（HMAC 短时有效）。
2. 设备 NFC 写入 `https://<host>/pair?code=XXXXXX` 或自定义 URI scheme `vibe://pair?...`。
3. 手机/另一台设备碰 NFC 打开 Mac 上的配对页（或设备读 Mac 写入的反向 URI）→ 用户确认 → Mac 将 `LAN_SHARED_SECRET` 写入设备 NVS（新 WS 消息 `provision_secret`）。
4. 去掉 `LoadPersistedNetworkState` 里强制覆写 `VibeServer` 的逻辑，改为尊重 NVS 已配对 hostId。

**工作量**：约 2–3 天（含 Mac 迷你 Web 配对页或纯 WS Provisioning）。

#### 方案 C · 协议宪法（与阶段 2 第 4 项合并）

1. 撰写 `doc/protocol.md`（半天）：逐条列出 hello / ptt / todo / cli / auth_challenge / plan_options / firmware_*。
2. `hello` / `server_ready` 增加 `protocolVersion: 1`；未知 type 打 `unknown_message_type` 日志（固件已有雏形）。
3. 中期：YAML → 生成 Swift `enum MessageType` + C `MSG_*` 常量（一天）。

### 阶段 3 · 方向性升级 ⏳ 部分完成

- **流式 STT** ✅（Qwen）：PTT 期间实时 append + `transcript_partial`；OpenAI/Volcengine 仍批量。
- **CLI 子进程 → Agent SDK 常驻会话** ⏳部分：CLI 忙时**自动排队**（`cliPromptQueue`）；完整 D5 常驻进程仍待 Agent SDK。
- **终端会话镜像** ✅：D1/D2 已在阶段 1 完成。

**明确不做**：设备端权限/工具审批、`PreToolUse` 阻塞、通过客户端安装或改写 Claude/Codex hooks / permission / plan 模式——**以用户在 Claude Code、Codex 等软件里的设置为准**（公理 E）。

---

## 6. 产品化分析

### 6.1 产品定位（第一性原理视角）

**边界原则（公理 E）**：vibecoding-plus 是**语音输入 + 状态镜子**，不是 agent 的控制平面。客户端启动后：

- **做**：转写、文本注入、按 `SEND_TARGET` 把语音发给已配置的 CLI、把 CLI 状态推到 e-paper。
- **不做**：在设备或客户端上审批写文件/跑命令；安装或修改 Claude/Codex 的 hooks、`permissionMode`、plan 模式等交互配置；替用户决定 agent 行为。

权限与交互模式一律以 **Claude Code / Codex 等软件自身设置** 为准；用户改设置在终端或各 App 里完成。

设备实际是三个能力的叠加，差异化程度不同：

| 能力 | 竞争环境 | 判断 |
|---|---|---|
| 语音→文本注入 | 红海（macOS 原生听写、Wispr Flow 等） | 差异化仅剩实体按键 + 不占 Mac 前台 |
| **AI CLI 遥控器**（语音驱动 Claude/Codex + e-paper 状态镜像） | 几乎无人做 | **最有独特价值的主线** |
| e-ink 离线待办 + Reminders 双向同步 | 小众但成立 | 优秀的"待机态价值"，不用时也值得摆在桌上 |

建议产品主线压在「**AI CLI 伴侣（只读镜像 + 语音遥控）**」上，路标为阶段 3 的流式 STT + 常驻会话 + 终端会话旁路观测（§8.5 D1/D2），**不含**设备端审批。

### 6.2 Ready-to-ship 差距清单

| 项 | 现状 | 目标 |
|---|---|---|
| 客户端分发 | ad-hoc codesign + zip | Developer ID + 公证 + 自动更新 |
| 固件升级 | USB 刷机 | 客户端一键 OTA |
| 配对 | 硬编码 hostId + 手填 secret | NFC 碰一碰 / 屏幕配对码 |
| 隐私说明 | 无 | 剪贴板注入、音频上云（STT provider）明示 |
| 崩溃/诊断 | 本地日志 | 客户端崩溃采集 + 设备 coredump 上报（esp coredump 分区） |
| 测试/CI | 无 | 阶段 1 建网 + GitHub Actions（Swift build+test、idf.py build） |

---

## 7. 修复执行记录（2026-07-03）

> 原则：每项修复对应上文编号；✅ 已完成 / ⏳ 未做。方法笔记供维护与测试参考。

| 编号 | 状态 | 方法笔记 |
|---|---|---|
| **P0-1** STT provider 路由 | ✅ | `STTService.resolveProvider()` 优先级：`config.sttProvider` → 环境变量 → key 推断；转写前写服务日志，与 UI 展示对齐。 |
| **P0-2** Claude 会话连续性 | ✅ | `lastCwd` 比较后才重置 session；CLI 参数 `--resume <id>` 替代 `--continue`。 |
| **P0-3** plan_options 生产者 | ✅ | `PlanOptionsExtractor.swift` + `handleCLIEvent(.completed)` → `emitPlanOptions`。 |
| **P0-4** quota 字段生产者 | ✅ | `CLIRateLimits.swift` 读 rollout / Claude 缓存；与 open-vibe-island 同源，见 **§8**。 |
| **P0-5** 固件跨任务无锁 | ✅ | WS/WiFi 回调只入队；`DrainPendingEvents()` 在主循环统一改状态与刷屏。 |
| **P0-6** vTaskDelete 强杀 | ✅ | 移除强杀；`connect_cancel_requested_` 协作取消 + WS 握手超时。 |
| **P1-1** WS 帧解析 | ✅ | `protocolError` fail-fast；帧载荷 ≤4MB；upgrade header ≤16KB。 |
| **P1-2** hello 重放 | ✅ | `auth_challenge` / `authServerNonce` 挑战-响应，签名不再依赖设备时钟。 |
| **P1-3** CLI isRunning | ✅ | `NSLock` 保护 `isRunning` 读写。 |
| **P1-4** 使用中深睡 | ✅ | `last_user_input_ms_` + `TouchUserInput`；深睡看 `max(断连, 最后按键)`。 |
| **P1-5** 预滚动耗电 | ✅ | 仅充电（或电量未知）时空闲预滚动。 |
| P1-6 | ✅ | `SaveCachedTodoState` 去抖 500ms + 内容去重；深睡前 `FlushCachedTodoStateIfNeeded(force)`。 |
| P2 undo | ✅ | `undo 注入失败` 日志 + `input_error`；失败不再误发 `undo_ok`。 |
| 阶段1 XCTest | ✅ | 10 tests；`npm run native:test`。 |
| D1/D2 旁路观测 | ✅ | `CodexRolloutParser` / `ClaudeTranscriptParser` + 2s 轮询。 |
| 协议 v1 | ✅部分 | `doc/protocol.md` + `doc/protocol.yaml` + `npm run protocol:generate` → Swift/C header；运行时 `protocolVersion` ✅。 |
| P2 / 固件 host 测试 | ✅部分 | `idf.py build` ✅；`npm run firmware:host-test`（UTF-8 折行 + todo 日期）✅；USB flash ❌ 设备无响应（需 BOOT+RESET 进下载模式）。 |
| P2 固件拆分 | ✅ | 6 模块 + `lan_mic_app_internal.h`；outbound cJSON ✅。 |
| NFC URI 写入 | ✅ 未破坏 | P0-5 后仍在 `HandleWsConnected` / `HandleNetEvent` 调用；碰一碰配对 ⏳ 见 §5.2 B.1。 |
| 固件 OTA | ✅ 代码 | `firmware_check` + HTTP OTA + 进度 UI；待真机 E2E。 |
| NFC 配对 | ✅ 代码 | `pairToken` + `provision_secret` + Devices UI；待真机 E2E。 |
| 流式 STT | ✅ Qwen | `QwenStreamingSTTSession` + `transcript_partial`。 |
| CLI 排队 | ✅ | `cliPromptQueue` 忙时自动出队。 |
| CI | ✅ | `.github/workflows/ci.yml`（native test / firmware build / host test）。 |
| 测试 | ✅ | 10/10，`TEST_HOST` 路径修复，bootstrap 跳过 XCTest。 |

---

## 8. 参考：open-vibe-island 的 Agent 观测方法

> 来源：[Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island)（开源 Vibe Island 替代，Swift/macOS，~1.5k stars）  
> 文档：`docs/architecture.md`、`docs/hooks.md`  
> 与本项目关系：**观测思路可借，UI/刘海形态不照搬**——我们把状态镜像到 ESP32 e-paper，而非 Mac 刘海 overlay。

### 8.1 核心结论：四条观测通道，而非只靠子进程 stdout

Open Island **从不假设**「只有自己启动的 CLI 子进程」才有状态。它并行使用四条通道：

| 通道 | 机制 | Claude Code | Codex CLI | 对本项目的价值 |
|---|---|---|---|---|
| **A. Agent Hooks → IPC** | 各 agent 的 hook 配置调用 `OpenIslandHooks` CLI（读 stdin JSON）→ Unix socket → `BridgeServer` | `~/.claude/settings.json`：`SessionStart` / `UserPromptSubmit` / `PreToolUse` / `Stop` 等 | `~/.codex/config.toml` 受管 hooks | ❌ **不借鉴**（含审批与受管改配置）；我们不做 hooks 安装 |
| **B. JSONL 转录文件扫描** | 启动时 + 定时扫描本地 transcript，**流式逐行解析**（64KB chunk，避免整文件读入 OOM） | `~/.claude/projects/**/*.jsonl`（跳过 `subagents/`） | `~/.codex/sessions/**/rollout-*.jsonl` | ⭐⭐⭐ 可观测**用户在终端里直接跑的** Claude/Codex，而不只是设备语音触发的子进程 |
| **C. Codex app-server JSON-RPC** | 自建子进程 `codex app-server --listen stdio://`，收 `thread/started`、`turn/completed` 等通知 | — | Codex **桌面 App** 会话 | ⭐ 若用户用 Codex.app 而非 CLI，可补盲区；e-paper 场景优先级低 |
| **D. Status line 缓存** | Claude 受管 `statusLine.command` 把 `rate_limits` 写入 `/tmp/open-island-rl.json` | 5h / 7d 用量窗口 | Codex 用量仍走 rollout jsonl 的 `token_count` 事件 | ⭐ 只**读**缓存；**不由客户端**写入 `~/.claude/settings.json`（用户自行配置，见 archive 脚本） |

**架构数据流（Hooks 通道）**：

```
Agent（Claude / Codex / …）
  │ hook 事件 JSON on stdin
  ▼
OpenIslandHooks（轻量 CLI）
  │ Unix socket，换行分隔 JSON envelope
  ▼
BridgeServer → SessionState.apply（纯 reducer）→ UI
```

### 8.2 Claude Code：怎么读「消息和内容」

**文件发现**（`ClaudeTranscriptDiscovery.swift`）：

- 根目录：`~/.claude/projects/`
- 过滤：`.jsonl`、24h 内修改、最多 40 个文件、排除 `subagents/`
- **流式读**：`FileHandle.read(upToCount: 64KB)` + 按行切分，峰值内存 ≈ 一块 buffer + 累积状态（大 transcript 可达数百 MB，整文件 `String(contentsOf:)` 会 OOM）

**每行 JSON 提取字段**：

| JSON 路径 | 用途 |
|---|---|
| `sessionId`, `cwd`, `timestamp` | 会话标识、工作区、更新时间 |
| `message.role == "user"` + `content` | `initialUserPrompt` / `lastUserPrompt`（支持 string 或 text block 数组） |
| `message.role == "assistant"` + `content` | `lastAssistantMessage`；`tool_use` 块 → `currentTool` + input preview |
| `type == "summary"` | 会话摘要行 |

**实时通道（Hooks）**（Open Island 用法）：`SessionStart`、`UserPromptSubmit`、`PreToolUse`（可阻塞审批）、`PostToolUse`、`Stop` 等。  
→ **本项目不采用**：审批与 hooks 安装违背公理 E；若需实时性，优先 D1/D2 只读 JSONL tail。

**用量（Quota）**：不解析 transcript，而是读 statusline hook 写入的 `/tmp/open-island-rl.json`（`five_hour` / `seven_day` 的 `used_percentage`、`resets_at`）。  
→ 本项目 archive 已有同款脚本 `archive/server/scripts/claude-statusline.mjs`，写入 `/tmp/vibecoding-plus-claude-rate-limits.json`，`CLIRateLimits.swift` 已读取。

### 8.3 Codex CLI：怎么读「消息和内容」

**文件发现**（`CodexRolloutDiscovery` + `CodexRolloutReducer`）：

- 根目录：`~/.codex/sessions/`，文件匹配 `rollout-*.jsonl`
- 同样**流式逐行**；`CodexRolloutReducer` 对每行做增量状态机：

| `type` | 子类型 / 载荷 | 提取内容 |
|---|---|---|
| `event_msg` | `payload.type == "token_count"` | `rate_limits.primary/secondary`（**与 P0-4 `CLIRateLimits` 相同**） |
| `event_msg` | 其他 | phase、完成/中断、rate limit 触顶 |
| `response_item` | agent message / tool | `lastUserPrompt`、`lastAssistantMessage`、`currentTool`、command preview |

**实时增量**：`CodexRolloutWatcher` 对活跃 rollout 文件做 watch，新旧 snapshot diff → `AgentEvent`（`activityUpdated`、`sessionCompleted` 等）。

**Hooks 通道**：默认只装低噪声 hooks（`SessionStart`、`UserPromptSubmit`、`Stop`）；`PreToolUse` 可手动开启用于工具审批（Codex 文件编辑可能走内部 apply-patch，**不宜假设** PreToolUse 覆盖所有写文件场景）。

**Codex 桌面 App**：额外起 `codex app-server`，JSON-RPC 收 `thread/started`、`turn/started`、`turn/completed`；点击跳转 `codex://threads/<id>`。

### 8.4 与 vibecoding-plus 现状对比

| 能力 | open-vibe-island | vibecoding-plus（当前） | 差距 |
|---|---|---|---|
| CLI 触发方式 | 不触发 CLI；旁观用户已有会话 | 每次语音 `claude -p` / `codex exec --json` 冷启动子进程 | 无法镜像「终端里正在跑的」会话 |
| 状态来源 | Hooks + JSONL +（Codex）app-server | 仅子进程 **stdout** `stream-json` | 子进程退出后状态即丢失 |
| 会话连续性 | 读 transcript 恢复；jump-back 终端 | `--resume` / `exec resume`（P0-2 已修） | 仅覆盖本应用触发的会话 |
| 配额 5h/7d | Claude statusline 文件 + Codex rollout | `CLIRateLimits.swift`（同源数据） | Claude 需用户手动配 statusline |
| 工具/权限审批 | Hook `PreToolUse` → UI 批准/拒绝 | 无（**刻意不做**） | 符合公理 E；不在设备/客户端代管 |
| plan 选项 | 无 | `PlanOptionsExtractor`（P0-3，历史） | 不扩展；可考虑删除 `plan_*` UI |
| 状态出口 | Mac 刘海 UI | WS → ESP32 e-paper | 形态不同，**reducer → broadcast** 可照搬 |

### 8.5 可借鉴方案（补全 §5 / 阶段 3）

按性价比排序，**适配 e-paper 镜像**而非复制 Open Island UI：

#### 方案 D1 · Codex Rollout Watcher（推荐，阶段 1–2）

**目标**：即使用户在 Terminal 里直接跑 `codex`，墨水屏也能显示最新 assistant 摘要 / 工具名 / 配额。

**做法**：

1. 移植精简版 `CodexRolloutReducer` 为 Swift（或 host 测试用纯逻辑模块）。
2. `NativeServer` 后台每 2s 对「最近修改的 `rollout-*.jsonl`」流式 tail（`FileHandle` seek 或记录 offset）。
3. diff 后 `broadcastCliState` / `cli_summary` / quota 字段——**复用现有固件渲染**，无需新协议字段。

**工作量**：约 2–3 天。  
**依赖**：无 hook 安装；只读 `~/.codex/sessions`。

#### 方案 D2 · Claude Transcript Discovery（推荐，阶段 2）

**目标**：Claude Code 在终端运行时，设备显示 `lastAssistantMessage` / `currentTool`，而不只是本应用 `claude -p` 的输出。

**做法**：

1. 移植 `ClaudeTranscriptDiscovery` 流式解析逻辑。
2. 扫描 `~/.claude/projects/*.jsonl`，取最近 cwd 匹配 `claudeCwd` 的会话。
3. 与 D1 相同出口到 `cli_session_state`。

**工作量**：约 2 天。

#### 方案 D3 · Claude Statusline（仅文档，不由客户端安装）

**目标**：P0-4 Claude 配额在无 rollout 时也能更新。

**原则**：与公理 E 一致——**客户端不修改** `~/.claude/settings.json`。archive 提供 `claude-statusline.mjs` 供用户**自行**配置 `statusLine.command`；`CLIRateLimits.swift` 只读 `/tmp/vibecoding-plus-claude-rate-limits.json`。

**不做**：设置页「一键安装」、受管合并 settings（等同代管交互配置）。

#### ~~方案 D4 · Agent Hooks 设备端审批~~ **不做**

原设想：Hooks → `permission_request` → e-paper BOOT/DOWN 审批。  
**产品决定（2026-07-03）**：权限与交互模式以 Claude/Codex **软件设置为准**，设备与客户端均不介入。open-vibe-island 的 PreToolUse 审批仅作对照，不落地。

#### 方案 D5 · 常驻 CLI 会话（阶段 3，替代冷启动）

Open Island **不**替用户跑 agent；我们当前每条语音冷启动 `claude -p`。长期可改为：

- 保持单一 Claude/Codex 长驻进程（或 SDK 会话），语音只发 prompt；
- 状态仍由 D1/D2 旁路校验，避免子进程 stdout 丢事件。

与 §5 阶段 3「Agent SDK 常驻会话」合并规划。

### 8.6 明确不借鉴的部分

- Mac 刘海 / 菜单栏 overlay UI（形态不同）
- 终端 jump-back（Terminal/Ghostty/iTerm AppleScript）——我们是**物理设备**，不是 Mac 伴侣栏
- **设备/客户端审批与 hooks 代管**（`PreToolUse` 阻塞、`permission_request`、`plan_apply` 扩展）——公理 E
- **客户端自动改写** Claude/Codex `settings.json` / `config.toml`（含 statusline、hooks 一键安装）
- GPL v3 代码直接拷贝——仅借鉴**只读**数据路径与解析知识，实现保持本项目许可与代码独立

### 8.7 修订后的阶段路线图补充

| 阶段 | 新增项 | 参考 | 状态 |
|---|---|---|---|
| 阶段 1 | 抽离 `CodexRolloutReducer` / `ClaudeTranscriptParser` 为可测纯逻辑 | §8.3、§8.2 | ✅ |
| 阶段 1 | XCTest + `mock-client.mjs` | §5 阶段 1 | ✅ |
| 阶段 2 | D1 Rollout Watcher | §8.5 | ✅（合入阶段 1） |
| 阶段 2 | D2 Claude transcript 镜像 | §8.5 | ✅（合入阶段 1） |
| 阶段 3 | D5 常驻会话 | §8.5 | ⏳ |

---

## 附录 A · 问题总表（按严重度）

| 编号 | 端 | 问题 | 位置 | 修复工作量 | 状态 |
|---|---|---|---|---|---|
| P0-1 | 客户端 | STT provider UI 选择不生效 | STTService.swift:83 | 0.5h | ✅ |
| P0-2 | 客户端 | Claude 会话连续性失效 | CLISessionManager.swift:200 | 0.5d | ✅ |
| P0-3 | 双端 | plan_options 无生产者（死功能） | NativeServer.swift / lan_mic_app.cc:1694 | 0.5-1d | ✅ |
| P0-4 | 双端 | quota 字段从未发送（死功能） | lan_mic_app.cc:1848 | 0.5d | ✅ |
| P0-5 | 固件 | 跨任务共享状态无锁（不稳定根因嫌疑） | lan_mic_app.cc:1548 等 | 1-2d | ✅ |
| P0-6 | 固件 | vTaskDelete 强杀连接任务 | lan_mic_app.cc:2537 | 1d | ✅ |
| P1-1 | 客户端 | WS 分片帧卡死连接 + 无载荷上限 | WebSocketServer.swift:73 | 0.5d | ✅ |
| P1-2 | 双端 | hello 时间戳新鲜度被绕过、可重放 | lan_mic_app.cc:1325 / NativeServer.swift:427 | 1d | ✅ |
| P1-3 | 客户端 | CLI isRunning 数据竞争 | CLISessionManager.swift | 0.5d | ✅ |
| P1-4 | 固件 | 使用中被强制深睡 | lan_mic_app.cc:3652 | 0.5h | ✅ |
| P1-5 | 固件 | 持续预滚动采集耗电 | lan_mic_app.cc:4028 | 1h-0.5d | ✅ |
| P1-6 | 固件 | 句柄竞争 / Beep 阻塞 / NVS 写频 | 多处 | 随 P0-5 顺带 | ✅ |
| P2-* | 双端 | 单文件巨石 / 弱类型协议 / 按键三套机制 / 注入隐私 | 多处 | 按阶段消化 | ✅（客户端 + 固件拆分/cJSON/按键驱动 + 协议 YAML 生成） |

## 附录 B · 一句话总结

这个项目最稀缺的不是功能创意（已经过剩到出现死功能），而是**让"按下必有回应、屏幕永远说真话"成为可被证明的性质**——先做阶段 0 止血与固件并发重构，再建测试网，产品化的每一步才踩在实地上。
