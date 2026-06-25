import CryptoKit
import Foundation
import Network

// MARK: - CLI View State

/// Maintains rolling log lines and summary state for the device e-paper display.
/// Replaces `cli-projector.mjs`.
struct CLIViewState {
    var phase: String = "idle"
    var statusLine: String = "Idle"
    var latestUserText: String = ""
    var latestAssistantText: String = ""
    var logLines: [String] = []
    var threadId: String = ""
    var repoName: String = ""
    var cwd: String = ""
    var maxLogLines: Int = 8

    mutating func pushLogLine(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines { logLines.removeFirst() }
    }
}

// MARK: - Client State

/// Per-connection state for an authenticated ESP32 / desktop client.
struct ClientState {
    var deviceId: String = "unknown"
    var boardType: String = "unknown"
    var authenticated: Bool = false
    var voiceMode: String = "normal"
    var connectedAt: Date = Date()
    var segmentActive: Bool = false
    var segmentSource: String = ""
    var segmentTranscriptDeliveryMode: String? = nil
    var segmentTextInjectionMode: String? = nil
    var chunks: [Data] = []
    var audioBytes: Int = 0
    var pendingSegments: [String] = []
    var pendingTranscript: String = ""
    var injectedSegments: [String] = []
    var planOptions: [String] = []
    var planSelectedIndex: Int = -1
    var missedPings: Int = 0
}

// MARK: - Constants

private let keepaliveIntervalMs: UInt64 = 30_000
private let keepaliveMissLimit = 2
private let minPlausibleEpochMs: Double = 1_577_836_800_000  // 2020-01-01 UTC

// MARK: - NativeServer

/// Main orchestrator that replaces the 2 462-line Node.js `server.mjs`.
///
/// Coordinates WebSocket serving, UDP discovery, STT, text injection, CLI
/// sessions (Codex / Claude Code), and todo management.  Individual service
/// implementations live in separate files; this actor wires them together.
actor NativeServer {

    // MARK: Sub-services

    private let wsServer = WebSocketServer()
    private let discoveryServer = DiscoveryServer()
    private let sttService: STTService
    private let remindersSync = RemindersSync()
    private let todoAssistant: TodoAssistant
    private var todoService: TodoService!
    private let textInjector = TextInjector.self
    private let codexSession: CodexSessionManager
    private let claudeSession: ClaudeSessionManager
    private var config: ServerConfig

    // Retain CLI event bridges so their weak delegate references stay alive
    private var codexEventBridge: CLIEventBridge?
    private var claudeEventBridge: CLIEventBridge?

    // MARK: State

    private var usedNonces = Set<String>()
    private var recentHelloNonces: [String: Date] = [:]
    private var clientStates: [UUID: ClientState] = [:]
    private var cliView = CLIViewState()
    private var serviceLogLines: [String] = []
    private let maxServiceLogLines = 200
    private var isRunning = false
    private var keepaliveTask: Task<Void, Never>?

    // MARK: Callbacks to UI layer (nonisolated for external wiring)

    nonisolated(unsafe) var onStatusChange: ((ServiceStatus, String) -> Void)?
    nonisolated(unsafe) var onDeviceEvent: ((String, String, String) -> Void)?
    nonisolated(unsafe) var onTodoStateChange: (([String: Any]) -> Void)?
    nonisolated(unsafe) var onCliStateChange: (([String: Any]) -> Void)?
    nonisolated(unsafe) var onCliSummary: ((String, String) -> Void)?
    nonisolated(unsafe) var onCliLogTail: (([String]) -> Void)?
    nonisolated(unsafe) var onServiceLog: (([String]) -> Void)?
    nonisolated(unsafe) var onTranscript: ((String) -> Void)?

    // MARK: Init

    init(config: ServerConfig) {
        self.config = config
        self.sttService = STTService(config: config)
        self.todoAssistant = TodoAssistant(config: config)
        self.codexSession = CodexSessionManager()
        self.claudeSession = ClaudeSessionManager()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        todoService = await .create(storagePath: config.todoListPath)
        try await wsServer.start(port: UInt16(config.port))
        wireWebSocketCallbacks()

        // Wire discovery log
        discoveryServer.onLog = { [weak self] msg in
            Task { await self?.appendServiceLog(msg) }
        }

        startKeepalive()

        // Start UDP discovery server. Treat failure as fatal: the e-paper
        // device relies on this listener to replace stale .local/cache targets.
        try await discoveryServer.start(config: config)

        // Start reminders sync if enabled
        if config.remindersSyncEnabled {
            await remindersSync.startPeriodicSync(todoService: todoService, config: config)
        }

        onStatusChange?(.running, "服务运行中 (port \(config.port))")
        appendServiceLog("服务启动 — port \(config.port), STT: \(config.resolvedSttProvider)")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        stopKeepalive()
        await discoveryServer.stop()
        await remindersSync.stopPeriodicSync()
        await wsServer.stop()
        clientStates.removeAll()
        usedNonces.removeAll()
        recentHelloNonces.removeAll()

        onStatusChange?(.stopped, "服务已停止")
        appendServiceLog("服务停止")
    }

    func restart(with newConfig: ServerConfig) async throws {
        await stop()
        config = newConfig
        try await start()
    }

    // MARK: - Direct Function Calls (replaces HTTP admin API)

    func getDevices() async -> [[String: Any]] {
        var devices: [[String: Any]] = []
        for (connId, state) in clientStates {
            var dict: [String: Any] = [
                "deviceId": state.deviceId,
                "boardType": state.boardType,
                "voiceMode": state.voiceMode,
                "connectedAt": state.connectedAt.timeIntervalSince1970 * 1000
            ]
            if let conn = await wsServer.connection(id: connId) {
                dict["remoteAddress"] = conn.remoteAddress
            }
            devices.append(dict)
        }
        return devices
    }

    func getServiceStatus() -> [String: Any] {
        return [
            "ok": isRunning,
            "clientCount": clientStates.count,
            "sendTarget": config.sendTarget,
            "sttProvider": config.resolvedSttProvider,
            "port": config.port,
            "discoveryEnabled": config.discoveryEnabled
        ]
    }

    func getTodoSnapshot() async -> TodoSnapshot {
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func createTodo(title: String, dueAt: String?) async -> TodoSnapshot {
        _ = await todoService.create(title: title, dueAt: dueAt)
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func updateTodo(id: String?, index: Int?, title: String?, dueAt: String?, completed: Bool?) async -> TodoSnapshot {
        if let completed {
            await todoService.toggle(id: id, index: index, completed: completed)
        }
        if title != nil || dueAt != nil {
            await todoService.update(id: id, index: index, title: title, dueAt: dueAt)
        }
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func deleteTodo(id: String?, index: Int?) async -> TodoSnapshot {
        _ = await todoService.delete(id: id, index: index)
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    private func convertSnapshot(_ snap: TodoServiceSnapshot) -> TodoSnapshot {
        TodoSnapshot(
            items: snap.items.map { TodoItem(id: $0.id, title: $0.title, completed: $0.completed, dueAt: $0.dueAt, appleId: $0.appleId) },
            archiveItems: snap.archiveItems.map { TodoItem(id: $0.id, title: $0.title, completed: $0.completed, dueAt: $0.dueAt, appleId: $0.appleId) },
            selectedIndex: snap.selectedIndex,
            lastActionText: snap.lastActionText
        )
    }

    func getDisplayConfig() -> DisplayConfig {
        return DisplayConfig(
            todoRefreshMs: config.displayTodoRefreshMs,
            codingRefreshMs: config.displayCodingRefreshMs,
            style: config.displayStyle
        )
    }

    func updateDisplayConfig(_ dc: DisplayConfig) {
        config.displayTodoRefreshMs = dc.todoRefreshMs
        config.displayCodingRefreshMs = dc.codingRefreshMs
        config.displayStyle = dc.style
        broadcastDisplayConfig()
    }

    func getSyncStatus() async -> [String: Any] {
        let status = await remindersSync.getStatus(config: config)
        return [
            "enabled": config.remindersSyncEnabled,
            "lastSyncAt": status.lastSyncAt,
            "syncCount": status.syncCount,
            "lastError": status.lastError,
            "list": config.remindersListName,
            "pollSec": config.remindersPollSec
        ]
    }

    func runSyncNow() async {
        await remindersSync.sync(todoService: todoService, config: config)
    }

    func getReminderLists() async -> [ReminderListInfo] {
        await remindersSync.getReminderLists()
    }

    nonisolated func triggerDiscovery(config: ServerConfig) {
        Task { await discoveryServer.sendBroadcast(config: config) }
    }

    // MARK: - WebSocket Message Handling

    /// Main message router — direct port of the `switch(message.type)` block
    /// in `server.mjs` (line 2126).
    private func handleMessage(_ message: [String: Any], from connId: UUID) async {
        guard let type = message["type"] as? String else { return }
        guard let conn = await wsServer.connection(id: connId) else { return }
        let deviceId = clientStates[connId]?.deviceId ?? "unknown"

        // Log all message types except high-frequency ones
        if type != "ping" && type != "ptt_start" {
            appendServiceLog("消息: \(deviceId) → \(type)")
        }

        switch type {
        case "hello":
            await handleHello(message, from: conn, connId: connId)

        case "ptt_start":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStart(message, connId: connId)

        case "ptt_stop":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStop(connId: connId)

        case "action_send":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleActionSend(connId: connId)

        case "action_undo":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleActionUndo(connId: connId)

        case "todo_command":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleTodoCommand(message, connId: connId)

        case "prompt":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePrompt(message, connId: connId)

        case "action_enter":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            try? await textInjector.inject("", mode: .typeAndEnter, dryRun: config.dryRunTextInjection)
            sendJson(to: conn, ["type": "status", "status": "typed", "text": ""])

        case "set_target":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetTarget(message, connId: connId)

        case "set_mode":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetMode(message, connId: connId)

        case "set_cli_cwd":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetCliCwd(message, connId: connId)

        case "ping":
            sendJson(to: conn, ["type": "pong", "nowMs": Int(Date().timeIntervalSince1970 * 1000)])

        case "plan_select":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePlanSelect(message, connId: connId)

        case "plan_apply":
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePlanApply(connId: connId)

        default:
            sendJson(to: conn, ["type": "warning", "warning": "unknown_message_type:\(type)"])
        }
    }

    // MARK: - Hello / Auth

    private func handleHello(_ message: [String: Any], from conn: WSConnection, connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        state.deviceId = (message["deviceId"] as? String) ?? "unknown"
        state.boardType = (message["boardType"] as? String) ?? "unknown"

        // Validate auth if shared secret is configured
        if !config.lanSharedSecret.isEmpty {
            let deviceId = state.deviceId
            let nonce = (message["authNonce"] as? String) ?? ""
            // authTs may arrive as JSON number (from firmware) or string
            let ts: String
            if let tsNum = message["authTs"] as? NSNumber {
                ts = tsNum.stringValue
            } else {
                ts = (message["authTs"] as? String) ?? ""
            }
            let sig = (message["authSig"] as? String) ?? ""

            guard !nonce.isEmpty, !sig.isEmpty else {
                closeWithAuthError(conn, connId: connId, error: "auth_missing")
                return
            }

            // Check timestamp freshness
            if let tsInt = Int(ts), tsInt >= Int(minPlausibleEpochMs) {
                guard LANAuth.isFreshTimestamp(tsInt, windowSec: 300) else {
                    closeWithAuthError(conn, connId: connId, error: "auth_stale")
                    return
                }
            }

            // Check nonce replay
            let cacheKey = "\(deviceId):\(nonce)"
            guard !recentHelloNonces.keys.contains(cacheKey) else {
                closeWithAuthError(conn, connId: connId, error: "auth_replayed")
                return
            }
            pruneRecentHelloNonces()
            recentHelloNonces[cacheKey] = Date()

            // Verify signature
            let secret = config.lanSharedSecret
            let expected = LANAuth.signHelloPayload(
                secret: secret,
                deviceId: deviceId,
                boardType: state.boardType,
                nonce: nonce,
                timestamp: ts
            )
            guard LANAuth.signaturesMatch(expected, sig) else {
                closeWithAuthError(conn, connId: connId, error: "auth_invalid")
                return
            }
        }

        state.authenticated = true
        clientStates[connId] = state

        sendJson(to: conn, ["type": "hello_ack", "deviceId": state.deviceId])
        emitServerReady(to: conn)
        broadcastDisplayConfig(to: conn)
        emitCliSnapshot(to: conn)

        // Broadcast device_event to all other connected clients
        broadcastJson([
            "type": "device_event",
            "event": "connected",
            "deviceId": state.deviceId,
            "boardType": state.boardType
        ], excluding: connId)

        onDeviceEvent?("connected", state.deviceId, state.boardType)
        appendServiceLog("设备连接: \(state.deviceId) (\(state.boardType))")
    }

    // MARK: - PTT Audio Pipeline

    private func handlePttStart(_ message: [String: Any], connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()

        let source = (message["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appendServiceLog("PTT开始: \(state.deviceId), source=\(source.isEmpty ? "firmware" : source)")
        if source == "desktop_mic" {
            state.segmentTranscriptDeliveryMode = "immediate"
            state.segmentTextInjectionMode = "type_only"
        } else {
            state.segmentTranscriptDeliveryMode = nil
            state.segmentTextInjectionMode = nil
        }
        state.segmentSource = source
        state.segmentActive = true
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state

        if let conn = await wsServer.connection(id: connId) {
            sendJson(to: conn, ["type": "status", "status": "recording"])
        }
    }

    private func handlePttStop(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        let pcmBuffer = Data(state.chunks.flatMap { $0 })
        state.segmentActive = false
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state
        appendServiceLog("PTT停止: \(state.deviceId), bytes=\(pcmBuffer.count)")

        if pcmBuffer.isEmpty {
            sendJson(to: conn, ["type": "status", "status": "empty_segment"])
            return
        }

        sendJson(to: conn, ["type": "status", "status": "transcribing", "bytes": pcmBuffer.count])
        let startedAt = Date()

        // Transcribe via STT service
        let transcript: String
        if !config.mockTranscript.isEmpty {
            transcript = config.mockTranscript
        } else {
            do {
                transcript = try await sttService.transcribe(pcm16Data: pcmBuffer)
            } catch {
                appendServiceLog("STT错误: \(error.localizedDescription)")
                transcript = ""
            }
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        appendServiceLog("STT [\("\(latencyMs)ms")]: \(trimmed.prefix(60))")

        guard !trimmed.isEmpty else {
            let hadPending = !state.pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sendJson(to: conn, [
                "type": "status",
                "status": hadPending ? "empty_segment" : "transcript_empty",
                "text": state.pendingTranscript
            ])
            return
        }

        let voiceMode = resolveVoiceMode(state)

        // Todo mode: dispatch to todo assistant
        if voiceMode == "todo" {
            sendJson(to: conn, [
                "type": "transcript_final",
                "text": trimmed,
                "latencyMs": latencyMs,
                "requiresAction": false
            ])
            state.pendingTranscript = ""
            state.pendingSegments = []
            clientStates[connId] = state
            await dispatchTodoPrompt(trimmed, connId: connId)
            return
        }

        let deliveryMode = state.segmentTranscriptDeliveryMode ?? config.transcriptDeliveryMode

        // Confirm-on-device: hold text, wait for action_send
        if deliveryMode == "confirm_on_device" {
            state.pendingSegments.append(trimmed)
            let pendingTranscript = joinPendingSegments(state.pendingSegments)
            state.pendingTranscript = pendingTranscript
            clientStates[connId] = state
            sendJson(to: conn, [
                "type": "transcript_final",
                "text": pendingTranscript,
                "latencyMs": latencyMs,
                "requiresAction": true
            ])
            sendJson(to: conn, ["type": "status", "status": "awaiting_action", "text": pendingTranscript])
            return
        }

        // Immediate mode: dispatch right away
        sendJson(to: conn, [
            "type": "transcript_final",
            "text": trimmed,
            "latencyMs": latencyMs,
            "requiresAction": false
        ])

        let injectionMode = state.segmentTextInjectionMode ?? config.textInjectionMode
        await dispatchTranscript(trimmed, injectionMode: injectionMode, connId: connId)

        state.injectedSegments.append(trimmed)
        state.pendingSegments = []
        clientStates[connId] = state
        sendJson(to: conn, ["type": "status", "status": "typed", "text": trimmed])
    }

    // MARK: - Action Handlers

    private func handleActionSend(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        let transcript = state.pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceMode = resolveVoiceMode(state)

        guard !transcript.isEmpty else {
            sendJson(to: conn, ["type": "status", "status": "no_pending"])
            return
        }

        if voiceMode == "todo" {
            clearPendingAndInjected(state: &state)
            clientStates[connId] = state
            await dispatchTodoPrompt(transcript, connId: connId)
            return
        }

        do {
            let injectionMode = state.segmentTextInjectionMode ?? config.textInjectionMode
            try await dispatchPrompt(transcript, injectionMode: injectionMode, connId: connId)
        } catch {
            if error.localizedDescription.lowercased().contains("busy") {
                sendJson(to: conn, ["type": "status", "status": "cli_busy"])
                return
            }
            print("[NativeServer] dispatchPrompt error: \(error.localizedDescription)")
        }

        if voiceMode == "normal" && config.sendTarget == "text_injector" {
            state.injectedSegments.append(transcript)
        }
        state.pendingTranscript = ""
        state.pendingSegments = []
        clientStates[connId] = state
        sendJson(to: conn, ["type": "status", "status": "typed", "text": transcript])
    }

    private func handleActionUndo(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        // If there are pending (unconfirmed) segments, pop the last one
        if !state.pendingSegments.isEmpty {
            state.pendingSegments.removeLast()
            let transcript = joinPendingSegments(state.pendingSegments)
            state.pendingTranscript = transcript
            clientStates[connId] = state

            if !transcript.isEmpty {
                sendJson(to: conn, ["type": "status", "status": "awaiting_action", "text": transcript])
            } else {
                sendJson(to: conn, ["type": "transcript_cleared"])
                sendJson(to: conn, ["type": "status", "status": "undo_ok"])
            }
            return
        }

        // Otherwise, undo last injected text (text_injector mode only)
        let voiceMode = resolveVoiceMode(state)
        guard voiceMode == "normal", config.sendTarget == "text_injector", !state.injectedSegments.isEmpty else {
            sendJson(to: conn, ["type": "status", "status": "no_pending"])
            return
        }

        let previousTranscript = joinInjectedSegments(state.injectedSegments)
        let removedSegment = state.injectedSegments.popLast()
        let nextTranscript = joinInjectedSegments(state.injectedSegments)
        let injectionMode = state.segmentTextInjectionMode ?? config.textInjectionMode
        let prevLength = previousTranscript.count
        let nextLength = nextTranscript.count
        let charsToUndo = max(0, prevLength - nextLength) + (injectionMode == "type_and_enter" ? 1 : 0)

        guard charsToUndo > 0 else {
            if let removed = removedSegment {
                state.injectedSegments.append(removed)
            }
            clientStates[connId] = state
            sendJson(to: conn, ["type": "status", "status": "no_pending"])
            return
        }

        do {
            try await textInjector.undoLastInput(length: charsToUndo)
        } catch {
            if let removed = removedSegment {
                state.injectedSegments.append(removed)
            }
            clientStates[connId] = state
            print("[NativeServer] dispatchPrompt error: \(error.localizedDescription)")
        }

        clientStates[connId] = state

        if nextTranscript.isEmpty {
            sendJson(to: conn, ["type": "transcript_cleared"])
        }
        sendJson(to: conn, ["type": "status", "status": "undo_ok", "text": nextTranscript])
    }

    // MARK: - Todo Command

    private func handleTodoCommand(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        guard let action = (message["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !action.isEmpty else {
            sendTodoResult(to: conn, ok: false, action: "unknown", message: "缺少待办操作")
            return
        }

        _ = await todoService.getSnapshot()
        var ok = true
        var resultMsg = ""

        switch action {
        case "create", "add":
            let title = (message["text"] as? String) ?? ""
            guard !title.isEmpty else { ok = false; resultMsg = "请输入待办内容"; break }
            _ = await todoService.create(title: title, dueAt: message["dueAt"] as? String)
            resultMsg = "待办已添加"
        case "toggle", "complete":
            await todoService.toggle(id: message["id"] as? String, index: message["index"] as? Int, completed: message["completed"] as? Bool ?? true)
            resultMsg = "待办已更新"
        case "delete", "remove":
            _ = await todoService.delete(id: message["id"] as? String, index: message["index"] as? Int)
            resultMsg = "待办已删除"
        case "update":
            await todoService.update(id: message["id"] as? String, index: message["index"] as? Int, title: message["text"] as? String, dueAt: message["dueAt"] as? String)
            resultMsg = "待办已更新"
        case "select_next":
            await todoService.selectNext()
            resultMsg = "已选择下一个"
        case "select_prev":
            await todoService.selectPrev()
            resultMsg = "已选择上一个"
        case "clear":
            await todoService.clearCompleted()
            resultMsg = "已清空已完成"
        default:
            ok = false
            resultMsg = "未知操作: \(action)"
        }

        await broadcastTodoState()
        sendTodoResult(to: conn, ok: ok, action: action, message: resultMsg)
    }

    // MARK: - Prompt

    private func handlePrompt(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let state = clientStates[connId] ?? ClientState()
        let text = ((message["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sendJson(to: conn, ["type": "warning", "warning": "prompt_empty"])
            return
        }

        let voiceMode = resolveVoiceMode(state)

        // Check CLI busy
        if voiceMode == "normal" {
            if config.sendTarget == "claude_code" && claudeSession.isRunning {
                sendJson(to: conn, ["type": "status", "status": "cli_busy"])
                return
            }
            if config.sendTarget == "codex_exec" && codexSession.isRunning {
                sendJson(to: conn, ["type": "status", "status": "cli_busy"])
                return
            }
        }

        if voiceMode == "todo" {
            await dispatchTodoPrompt(text, connId: connId)
        } else {
            do {
                try await dispatchPrompt(text, connId: connId)
                sendJson(to: conn, ["type": "status", "status": "typed", "text": text])
            } catch {
                let msg = error.localizedDescription
                appendCliLog("error: \(msg)")
                setCliState(phase: "error", statusLine: msg)
            }
        }
    }

    // MARK: - Settings Handlers

    private func handleSetTarget(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let nextTarget = ((message["sendTarget"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let validTargets: Set<String> = ["text_injector", "codex_exec", "claude_code"]
        guard validTargets.contains(nextTarget) else {
            sendJson(to: conn, ["type": "warning", "warning": "invalid_send_target"])
            return
        }
        guard !codexSession.isRunning && !claudeSession.isRunning else {
            sendJson(to: conn, ["type": "status", "status": "cli_busy"])
            return
        }
        if config.sendTarget != nextTarget {
            config.sendTarget = nextTarget
            broadcastCliState()
            broadcastServerReady()
        } else {
            emitServerReady(to: conn)
        }
    }

    private func handleSetMode(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()
        let nextMode = ((message["mode"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validModes: Set<String> = ["normal", "todo"]
        guard validModes.contains(nextMode) else {
            sendJson(to: conn, ["type": "warning", "warning": "invalid_voice_mode"])
            return
        }
        if state.voiceMode != nextMode {
            state.voiceMode = nextMode
            clientStates[connId] = state
        }
        sendJson(to: conn, ["type": "mode_state", "mode": resolveVoiceMode(state)])
    }

    private func handleSetCliCwd(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let target = ((message["sendTarget"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nextCwd = ((message["cwd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard target == "codex_exec" || target == "claude_code" else {
            sendJson(to: conn, ["type": "warning", "warning": "invalid_cli_cwd_target"])
            return
        }
        guard !nextCwd.isEmpty else {
            sendJson(to: conn, ["type": "warning", "warning": "cli_cwd_empty"])
            return
        }
        let resolved = NSString(string: nextCwd).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolved) else {
            sendJson(to: conn, ["type": "warning", "warning": "invalid_cli_cwd:\(nextCwd)"])
            return
        }
        if target == "claude_code" {
            config.claudeCwd = resolved
        } else {
            config.codexCwd = resolved
        }
        sendJson(to: conn, [
            "type": "cli_cwd_updated",
            "sendTarget": target,
            "cwd": resolved
        ])
    }

    // MARK: - Plan Selection

    private func handlePlanSelect(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()
        let direction = ((message["direction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard direction == "prev" || direction == "next" else {
            sendJson(to: conn, ["type": "warning", "warning": "invalid_plan_select_direction"])
            return
        }
        guard !state.planOptions.isEmpty else {
            sendJson(to: conn, ["type": "status", "status": "no_plan_options"])
            return
        }
        let delta = direction == "prev" ? -1 : 1
        let current = state.planSelectedIndex >= 0 ? state.planSelectedIndex : 0
        let next = (current + delta + state.planOptions.count) % state.planOptions.count
        state.planSelectedIndex = next
        clientStates[connId] = state
        emitPlanOptions(to: conn, state: state)
    }

    private func handlePlanApply(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let state = clientStates[connId] ?? ClientState()

        guard config.sendTarget == "claude_code" ? !claudeSession.isRunning : !codexSession.isRunning else {
            sendJson(to: conn, ["type": "status", "status": "cli_busy"])
            return
        }

        guard state.planOptions.count > 0,
              state.planSelectedIndex >= 0,
              state.planSelectedIndex < state.planOptions.count else {
            sendJson(to: conn, ["type": "status", "status": "no_plan_options"])
            return
        }

        let selectedOption = state.planOptions[state.planSelectedIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = buildPlanApplyPrompt(selectedOption)

        sendJson(to: conn, ["type": "status", "status": "typed", "text": prompt])
        do {
            try await dispatchPrompt(prompt, connId: connId)
        } catch {
            appendCliLog("error: \(error.localizedDescription)")
            setCliState(phase: "error", statusLine: error.localizedDescription)
        }
    }

    // MARK: - Binary Audio Handling

    func handleBinary(_ data: Data, connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        guard state.authenticated, state.segmentActive else { return }

        let nextBytes = state.audioBytes + data.count
        if nextBytes > config.lanAudioMaxBytes {
            state.segmentActive = false
            state.chunks = []
            state.audioBytes = 0
            clientStates[connId] = state
            if let conn = await wsServer.connection(id: connId) {
                sendJson(to: conn, ["type": "warning", "warning": "audio_too_large"])
                sendJson(to: conn, ["type": "status", "status": "audio_too_large"])
            }
            return
        }

        state.audioBytes = nextBytes
        state.chunks.append(data)
        clientStates[connId] = state
    }

    // MARK: - Transcript Dispatch

    /// Dispatches text to the appropriate target (injector / codex / claude).
    private func dispatchTranscript(_ text: String, injectionMode: String, connId: UUID) async {
        switch config.sendTarget {
        case "codex_exec":
            guard !codexSession.isRunning else {
                appendCliLog("CLI busy — Codex session already running")
                return
            }
            launchCodexPrompt(text)
        case "claude_code":
            guard !claudeSession.isRunning else {
                appendCliLog("CLI busy — Claude session already running")
                return
            }
            launchClaudePrompt(text)
        default:
            try? await textInjector.inject(text, mode: injectionMode == "type_only" ? .typeOnly : .typeAndEnter,
                                            dryRun: config.dryRunTextInjection)
        }
    }

    /// Full prompt dispatch with queue serialization.
    private func dispatchPrompt(_ text: String, injectionMode: String? = nil, connId: UUID) async throws {
        let mode = injectionMode ?? config.textInjectionMode

        switch config.sendTarget {
        case "codex_exec":
            guard !codexSession.isRunning else { throw NativeServerError.cliBusy }
            await runCodexPrompt(text)
        case "claude_code":
            guard !claudeSession.isRunning else { throw NativeServerError.cliBusy }
            await runClaudePrompt(text)
        default:
            cliView.latestUserText = text
            cliView.statusLine = "Typed to terminal"
            broadcastCliState()
            broadcastCliSummary()
            try await textInjector.inject(text,
                                          mode: mode == "type_only" ? .typeOnly : .typeAndEnter,
                                          dryRun: config.dryRunTextInjection)
        }
    }

    // MARK: - CLI Session Launchers

    private func runCodexPrompt(_ text: String) async {
        cliView.latestUserText = text
        cliView.latestAssistantText = ""
        setCliState(phase: "running", statusLine: "Running Codex...", threadId: codexSession.threadId)
        broadcastCliSummary()
        appendCliLog("user: \(text.prefix(80))")

        do {
            let bridge = CLIEventBridge { [weak self] event in
                Task { await self?.handleCLIEvent(event, source: "codex") }
            }
            codexEventBridge = bridge
            codexSession.delegate = bridge
            try codexSession.start(prompt: text, config: config)
        } catch {
            setCliState(phase: "error", statusLine: "Codex error: \(error.localizedDescription)")
            appendCliLog("error: \(error.localizedDescription)")
        }
    }

    private func runClaudePrompt(_ text: String) async {
        cliView.latestUserText = text
        cliView.latestAssistantText = ""
        setCliState(phase: "running", statusLine: "Running Claude...", threadId: claudeSession.sessionId ?? "")
        broadcastCliSummary()
        appendCliLog("user: \(text.prefix(80))")

        do {
            let bridge = CLIEventBridge { [weak self] event in
                Task { await self?.handleCLIEvent(event, source: "claude") }
            }
            claudeEventBridge = bridge
            claudeSession.delegate = bridge
            try claudeSession.start(prompt: text, config: config)
        } catch {
            setCliState(phase: "error", statusLine: "Claude error: \(error.localizedDescription)")
            appendCliLog("error: \(error.localizedDescription)")
        }
    }

    private func handleCLIEvent(_ event: CLIEvent, source: String) {
        switch event {
        case .text(let text, let role):
            if role == "assistant" {
                cliView.latestAssistantText = text
                broadcastCliSummary()
            }
            appendCliLog("\(role): \(text.prefix(80))")
        case .status(let status):
            setCliState(phase: "running", statusLine: status)
        case .completed(let result):
            cliView.threadId = result.sessionId ?? ""
            setCliState(phase: result.success ? "idle" : "error",
                       statusLine: result.success ? "\(source.capitalized) idle" : "Error: exit \(result.exitCode ?? -1)",
                       threadId: cliView.threadId)
            broadcastCliSummary()
        case .error(let message):
            setCliState(phase: "error", statusLine: "\(source.capitalized) error: \(message)")
            appendCliLog("error: \(message)")
        }
    }

    private func launchCodexPrompt(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.runCodexPrompt(text)
        }
    }

    private func launchClaudePrompt(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.runClaudePrompt(text)
        }
    }

    // MARK: - Todo Prompt Dispatch

    private func dispatchTodoPrompt(_ text: String, connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }

        // Parse via TodoAssistant (rule-based + LLM fallback)
        let deviceId = clientStates[connId]?.deviceId ?? "unknown"
        let result = await todoAssistant.interpret(text, deviceId: deviceId)
        if result.ok, let command = result.command {
            var resultMsg = ""
            var ok = true

            switch command.action {
            case "create":
                guard let title = command.text, !title.isEmpty else { ok = false; resultMsg = "请输入待办内容"; break }
                _ = await todoService.create(title: title, dueAt: command.dueAt)
                resultMsg = "待办已添加"
            case "toggle":
                await todoService.toggle(id: command.id, index: command.index, completed: command.completed ?? true)
                resultMsg = command.completed == true ? "待办已完成" : "待办已恢复"
            case "delete":
                _ = await todoService.delete(id: command.id, index: command.index)
                resultMsg = "待办已删除"
            case "update":
                await todoService.update(id: command.id, index: command.index, title: command.text, dueAt: command.dueAt)
                resultMsg = "待办已更新"
            case "select_next":
                await todoService.selectNext()
                resultMsg = "已选择下一个"
            case "select_prev":
                await todoService.selectPrev()
                resultMsg = "已选择上一个"
            case "clear":
                await todoService.clearCompleted()
                resultMsg = "已清空已完成"
            default:
                ok = false
                resultMsg = "未识别的操作"
            }

            await broadcastTodoState()
            sendTodoResult(to: conn, ok: ok, action: command.action, message: resultMsg)
        } else {
            // Fallback: treat as create
            _ = await todoService.create(title: text)
            await broadcastTodoState()
            sendTodoResult(to: conn, ok: true, action: "add", message: "待办已添加")
        }
    }

    // MARK: - Broadcasting

    func broadcastServerReady(to conn: WSConnection) {
        sendJson(to: conn, [
            "type": "server_ready",
            "textInjectionMode": config.textInjectionMode,
            "transcriptDeliveryMode": config.transcriptDeliveryMode,
            "sendTarget": config.sendTarget,
            "mode": "normal",
            "authRequired": !config.lanSharedSecret.isEmpty,
            "displayTodoRefreshMs": config.displayTodoRefreshMs,
            "displayCodingRefreshMs": config.displayCodingRefreshMs,
            "displayStyle": config.displayStyle
        ])
    }

    func broadcastServerReady() {
        Task { [weak self] in
            guard let self else { return }
            await self.wsServer.broadcast(json: [
                "type": "server_ready",
                "textInjectionMode": self.config.textInjectionMode,
                "transcriptDeliveryMode": self.config.transcriptDeliveryMode,
                "sendTarget": self.config.sendTarget,
                "mode": "normal",
                "authRequired": !self.config.lanSharedSecret.isEmpty,
                "displayTodoRefreshMs": self.config.displayTodoRefreshMs,
                "displayCodingRefreshMs": self.config.displayCodingRefreshMs,
                "displayStyle": self.config.displayStyle
            ])
        }
    }

    func broadcastCliState() {
        let payload: [String: Any] = [
            "type": "cli_session_state",
            "phase": cliView.phase,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": cliView.repoName,
            "cwd": cliView.cwd
        ]
        broadcastJson(payload)
        onCliStateChange?(payload)
    }

    func broadcastCliSummary() {
        broadcastJson([
            "type": "cli_summary",
            "latestUserText": cliView.latestUserText,
            "latestAssistantText": cliView.latestAssistantText,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": cliView.repoName
        ])
        onCliSummary?(cliView.latestUserText, cliView.latestAssistantText)
    }

    func broadcastTodoState() async {
        let snapshot = await getTodoSnapshot()
        let payload: [String: Any] = [
            "type": "todo_state",
            "items": snapshot.items.map { itemToDict($0) },
            "archiveItems": snapshot.archiveItems.map { itemToDict($0) },
            "selectedIndex": snapshot.selectedIndex,
            "lastActionText": snapshot.lastActionText
        ]
        broadcastJson(payload)
        onTodoStateChange?(payload)
    }

    func broadcastDisplayConfig(to conn: WSConnection? = nil) {
        let payload: [String: Any] = [
            "type": "display_config",
            "todoRefreshMs": config.displayTodoRefreshMs,
            "codingRefreshMs": config.displayCodingRefreshMs,
            "style": config.displayStyle
        ]
        if let conn {
            sendJson(to: conn, payload)
        } else {
            broadcastJson(payload)
        }
    }

    func broadcastJson(_ json: [String: Any], excluding excludedId: UUID? = nil) {
        Task { await wsServer.broadcastAuthenticated(json: json, excludeId: excludedId) }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: keepaliveIntervalMs * 1_000_000)
                guard let self else { break }
                let running = await self.isRunning
                guard running else { break }
                await self.runKeepalive()
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func runKeepalive() async {
        var toRemove: [UUID] = []
        for (connId, conn) in await wsServer.allConnections().map({ ($0.id, $0) }) {
            var state = clientStates[connId]
            let missed = (state?.missedPings ?? 0) + 1
            if missed >= keepaliveMissLimit {
                toRemove.append(connId)
                appendServiceLog("心跳超时: \(state?.deviceId ?? "unknown")")
                continue
            }
            state?.missedPings = missed
            if let state { clientStates[connId] = state }
            conn.sendPing()
        }
        for connId in toRemove {
            if let conn = await wsServer.connection(id: connId) {
                conn.close()
            }
            clientStates.removeValue(forKey: connId)
        }
    }

    // MARK: - WebSocket Wiring

    private func wireWebSocketCallbacks() {
        wsServer.onConnection = { [weak self] conn in
            Task { await self?.handleConnection(conn) }
        }
        wsServer.onDisconnect = { [weak self] conn in
            Task { await self?.handleDisconnect(conn.id) }
        }
    }

    // Called externally by the WebSocket layer when a new connection arrives
    func handleConnection(_ conn: WSConnection) {
        var state = ClientState()
        state.authenticated = config.lanSharedSecret.isEmpty
        clientStates[conn.id] = state
        appendServiceLog("WS连接: \(conn.remoteAddress)")

        // Wire message handler
        conn.onMessage = { [weak self] message in
            Task { await self?.handleWSMessage(message, connId: conn.id) }
        }
    }

    // Called externally by the WebSocket layer when a connection drops
    func handleDisconnect(_ connId: UUID) {
        let state = clientStates.removeValue(forKey: connId)
        let deviceId = state?.deviceId ?? "unknown"
        let boardType = state?.boardType ?? "unknown"
        onDeviceEvent?("disconnected", deviceId, boardType)
        appendServiceLog("设备断开: \(deviceId)")
        broadcastJson([
            "type": "device_event",
            "event": "disconnected",
            "deviceId": deviceId,
            "boardType": boardType
        ])
    }

    // Called externally when a text message arrives on a connection
    func handleTextMessage(_ text: String, connId: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Task { await handleMessage(json, from: connId) }
    }

    // Route incoming WSMessage to appropriate handler
    private func handleWSMessage(_ message: WSMessage, connId: UUID) async {
        switch message {
        case .text(let text):
            handleTextMessage(text, connId: connId)
        case .binary(let data):
            await handleBinary(data, connId: connId)
        }
    }

    // MARK: - Private Helpers

    private func sendJson(to conn: WSConnection, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        conn.send(text: str)
    }

    private func sendTodoResult(to conn: WSConnection, ok: Bool, action: String, message: String) {
        sendJson(to: conn, [
            "type": "todo_result",
            "ok": ok,
            "action": action,
            "message": message
        ])
    }

    private func emitServerReady(to conn: WSConnection) {
        broadcastServerReady(to: conn)
    }

    private func emitCliSnapshot(to conn: WSConnection) {
        sendJson(to: conn, [
            "type": "cli_session_state",
            "phase": cliView.phase,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": cliView.repoName,
            "cwd": cliView.cwd
        ])
        sendJson(to: conn, [
            "type": "cli_summary",
            "latestUserText": cliView.latestUserText,
            "latestAssistantText": cliView.latestAssistantText,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": cliView.repoName
        ])
        sendJson(to: conn, [
            "type": "cli_log_tail",
            "lines": cliView.logLines
        ])
    }

    private func emitPlanOptions(to conn: WSConnection, state: ClientState) {
        sendJson(to: conn, [
            "type": "plan_options",
            "options": state.planOptions,
            "selectedIndex": state.planSelectedIndex >= 0 ? state.planSelectedIndex : (state.planOptions.isEmpty ? -1 : 0)
        ])
    }

    private func ensureAuthenticated(_ connId: UUID, conn: WSConnection) -> Bool {
        let state = clientStates[connId]
        if state?.authenticated == true { return true }
        closeWithAuthError(conn, connId: connId, error: "auth_required")
        return false
    }

    private func closeWithAuthError(_ conn: WSConnection, connId: UUID, error: String) {
        appendServiceLog("认证失败: \(error), addr=\(conn.remoteAddress)")
        sendJson(to: conn, ["type": "error", "error": error])
        conn.close()
        clientStates.removeValue(forKey: connId)
    }

    private func resolveVoiceMode(_ state: ClientState) -> String {
        let mode = state.voiceMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (mode == "todo") ? "todo" : "normal"
    }

    private func pruneRecentHelloNonces() {
        let cutoff = Date().addingTimeInterval(-300)
        recentHelloNonces = recentHelloNonces.filter { $0.value > cutoff }
    }

    private func setCliState(phase: String, statusLine: String, threadId: String? = nil) {
        cliView.phase = phase
        cliView.statusLine = statusLine
        if let threadId { cliView.threadId = threadId }
        broadcastCliState()
    }

    private func appendCliLog(_ line: String) {
        cliView.pushLogLine(line)
        broadcastJson(["type": "cli_log_tail", "lines": cliView.logLines])
        onCliLogTail?(cliView.logLines)
    }

    private func appendServiceLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        serviceLogLines.append("[\(ts)] \(line)")
        if serviceLogLines.count > maxServiceLogLines { serviceLogLines.removeFirst() }
        onServiceLog?(serviceLogLines)
    }

    private func clearPendingAndInjected(state: inout ClientState) {
        state.pendingTranscript = ""
        state.pendingSegments = []
        state.injectedSegments = []
    }

    private func buildPlanApplyPrompt(_ selectedOption: String) -> String {
        let planLine = selectedOption.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        请按下面选中的方案执行。
        不要输出思考过程，只输出两个部分：
        ## Plan
        - [ ] ...
        ## Result
        - ...

        选中方案：\(planLine)
        """
    }

    private func itemToDict(_ item: TodoItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id,
            "title": item.title,
            "completed": item.completed
        ]
        if let dueAt = item.dueAt { dict["dueAt"] = dueAt }
        if let appleId = item.appleId { dict["appleId"] = appleId }
        return dict
    }
}

// MARK: - Segment Joining

/// Joins segments with intelligent spacing around CJK/Latin punctuation.
/// Mirrors `joinPendingSegments` from server.mjs.
private func joinPendingSegments(_ segments: [String]) -> String {
    let normalized = segments
        .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return normalized.reduce("") { combined, segment in
        guard !combined.isEmpty else { return segment }
        let punctuation = CharacterSet(charactersIn: "。！？!?；;：:，,、.")
        let endsPunctuation = combined.unicodeScalars.last.map { punctuation.contains($0) } ?? false
        let startsPunctuation = segment.unicodeScalars.first.map { punctuation.contains($0) } ?? false
        if endsPunctuation || startsPunctuation {
            return combined + segment
        }
        return combined + " " + segment
    }
}

/// Joins injected segments (same logic as pending).
private func joinInjectedSegments(_ segments: [String]) -> String {
    joinPendingSegments(segments)
}

// MARK: - Errors

enum NativeServerError: LocalizedError {
    case cliBusy
    case notRunning

    var errorDescription: String? {
        switch self {
        case .cliBusy: "CLI session is busy"
        case .notRunning: "Server is not running"
        }
    }
}

// MARK: - CLI Event Bridge

enum CLIEvent {
    case text(String, role: String)
    case status(String)
    case completed(CLIResult)
    case error(String)
}

final class CLIEventBridge: CLISessionDelegate {
    private let handler: (CLIEvent) -> Void

    init(handler: @escaping (CLIEvent) -> Void) {
        self.handler = handler
    }

    func cliSession(_ session: CLISession, didReceiveText text: String, role: String) {
        handler(.text(text, role: role))
    }

    func cliSession(_ session: CLISession, didUpdateStatus status: String) {
        handler(.status(status))
    }

    func cliSession(_ session: CLISession, didComplete result: CLIResult) {
        handler(.completed(result))
    }

    func cliSession(_ session: CLISession, didEncounterError error: String) {
        handler(.error(error))
    }
}
