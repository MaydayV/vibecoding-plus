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
    var quota5hRemainingPct: Int? = nil
    var quotaWeekRemainingPct: Int? = nil

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
    var authChallengeNonce: String? = nil
    var provisionCompleted: Bool = false
}

// MARK: - Constants

private let keepaliveIntervalMs: UInt64 = 30_000
private let externalWatchIntervalMs: UInt64 = 2_000
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
    private var externalWatchTask: Task<Void, Never>?
    private var lastExternalSnapshotSignature = ""
    private let firmwareOtaHost = FirmwareOtaHost()
    private let setupHttpHost = LanSetupHttpHost()
    private let setupPageSnapshot = SetupPageSnapshot()
    private var pairingCode: String = ""
    private var firmwareOtaProgress: [String: (phase: String, pct: Int)] = [:]
    private var streamingSttSessions: [UUID: QwenStreamingSTTSession] = [:]
    private var cliPromptQueue: [(text: String, connId: UUID, injectionMode: String?)] = []
    private var firmwareCheckContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

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
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        config.pairingCode = pairingCode
        refreshSetupPageSnapshot()

        todoService = await .create(storagePath: config.todoListPath)
        await todoService.setOnChange { [weak self] in
            Task { await self?.broadcastTodoState() }
        }
        try await wsServer.start(port: UInt16(config.port))
        wireWebSocketCallbacks()
        startSetupHttpHost()

        // Wire discovery log
        discoveryServer.onLog = { [weak self] msg in
            Task { await self?.appendServiceLog(msg) }
        }

        startKeepalive()
        startExternalCliWatcher()

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
        stopExternalCliWatcher()
        await discoveryServer.stop()
        await remindersSync.stopPeriodicSync()
        await wsServer.stop()
        setupHttpHost.stop()
        firmwareOtaHost.stop()
        clientStates.removeAll()
        usedNonces.removeAll()
        recentHelloNonces.removeAll()

        onStatusChange?(.stopped, "服务已停止")
        appendServiceLog("服务停止")
    }

    func restart(with newConfig: ServerConfig) async throws {
        await stop()
        config = newConfig
        refreshSetupPageSnapshot()
        try await start()
    }

    // MARK: - Direct Function Calls (replaces HTTP admin API)

    func getPairingCode() -> String { pairingCode }

    func getSetupPageURL(forRemoteIP remoteIP: String) async -> String? {
        guard let address = await discoveryServer.localAddress(forRemoteIP: remoteIP) else { return nil }
        return "http://\(address):\(config.setupPort)/pair"
    }

    private func startSetupHttpHost() {
        setupHttpHost.infoProvider = { [setupPageSnapshot] in
            setupPageSnapshot.asInfo()
        }
        do {
            try setupHttpHost.start(port: UInt16(config.setupPort))
            appendServiceLog("配对页 HTTP 服务: :\(config.setupPort)/pair")
        } catch {
            appendServiceLog("配对页 HTTP 启动失败: \(error.localizedDescription)")
        }
    }

    private func refreshSetupPageSnapshot() {
        setupPageSnapshot.hostId = config.discoveryHostId
        setupPageSnapshot.hostName = ProcessInfo.processInfo.hostName
        setupPageSnapshot.pairCode = pairingCode
        setupPageSnapshot.hasSharedSecret = !config.lanSharedSecret.isEmpty
    }

    func offerFirmware(to connId: UUID, binURL: URL) async throws {
        guard let conn = await wsServer.connection(id: connId) else {
            throw URLError(.cannotConnectToHost)
        }
        guard ensureAuthenticated(connId, conn: conn) else {
            throw URLError(.userAuthenticationRequired)
        }
        let state = clientStates[connId] ?? ClientState()
        let remoteIP = conn.remoteAddress.components(separatedBy: ":").first ?? "127.0.0.1"
        let localIP = await discoveryServer.localAddress(forRemoteIP: remoteIP) ?? "127.0.0.1"
        let (sha256, size) = try firmwareOtaHost.start(binURL: binURL)
        let version = resolveFirmwareVersion(binURL: binURL)
        firmwareOtaProgress[state.deviceId] = ("检查版本", 0)

        var checkPayload: [String: Any] = [
            "type": LANServerMessage.firmware_check,
            "sha256": sha256,
            "size": size,
        ]
        if let version, !version.isEmpty {
            checkPayload["version"] = version
        }
        sendJson(to: conn, checkPayload)

        let deviceId = state.deviceId
        let needUpgrade = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            firmwareCheckContinuations[deviceId] = cont
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let pending = firmwareCheckContinuations.removeValue(forKey: deviceId) {
                    pending.resume(returning: true)
                }
            }
        }

        guard needUpgrade else {
            firmwareOtaProgress[deviceId] = ("已是最新", 100)
            appendServiceLog("固件已是最新: \(deviceId) (\(version ?? binURL.lastPathComponent))")
            throw NativeServerError.firmwareUpToDate
        }

        var offerPayload: [String: Any] = [
            "type": LANServerMessage.firmware_offer,
            "url": "http://\(localIP):8767/firmware.bin",
            "sha256": sha256,
            "size": size,
        ]
        if let version, !version.isEmpty {
            offerPayload["version"] = version
        }
        sendJson(to: conn, offerPayload)
        appendServiceLog("固件 OTA 提供: \(binURL.lastPathComponent) → \(localIP):8767")
    }

    func provisionSecret(to connId: UUID) async -> Bool {
        guard let conn = await wsServer.connection(id: connId) else { return false }
        guard !config.lanSharedSecret.isEmpty else {
            appendServiceLog("配对失败: 未配置 LAN_SHARED_SECRET")
            return false
        }
        sendJson(to: conn, [
            "type": LANServerMessage.provision_secret,
            "secret": config.lanSharedSecret,
            "hostId": config.discoveryHostId,
            "hostName": ProcessInfo.processInfo.hostName,
        ])
        if var state = clientStates[connId] {
            state.provisionCompleted = true
            clientStates[connId] = state
        }
        broadcastServerReady(to: conn)
        appendServiceLog("已发送配对密钥 → \(clientStates[connId]?.deviceId ?? "unknown")")
        return true
    }

    func getFirmwareOtaProgress(for deviceId: String) -> (phase: String, pct: Int)? {
        firmwareOtaProgress[deviceId]
    }

    func getAllFirmwareOtaProgress() -> [String: (phase: String, pct: Int)] {
        firmwareOtaProgress
    }

    func connId(for deviceId: String) -> UUID? {
        clientStates.first(where: { $0.value.deviceId == deviceId })?.key
    }

    func offerFirmware(forDeviceId deviceId: String, binURL: URL) async throws {
        guard let connId = connId(for: deviceId) else { throw URLError(.cannotFindHost) }
        try await offerFirmware(to: connId, binURL: binURL)
    }

    func provisionSecret(forDeviceId deviceId: String) async -> Bool {
        guard let connId = connId(for: deviceId) else { return false }
        return await provisionSecret(to: connId)
    }

    func getDevices() async -> [[String: Any]] {
        var devices: [[String: Any]] = []
        for (connId, state) in clientStates {
            var dict: [String: Any] = [
                "connId": connId.uuidString,
                "deviceId": state.deviceId,
                "boardType": state.boardType,
                "voiceMode": state.voiceMode,
                "connectedAt": state.connectedAt.timeIntervalSince1970 * 1000
            ]
            if let conn = await wsServer.connection(id: connId) {
                dict["remoteAddress"] = conn.remoteAddress
            }
            dict["isProvisioned"] = !config.lanSharedSecret.isEmpty &&
                (state.authenticated || state.provisionCompleted)
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
            "setupPort": config.setupPort,
            "discoveryEnabled": config.discoveryEnabled
        ]
    }

    func getTodoSnapshot() async -> TodoSnapshot {
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func createTodo(title: String, dueAt: String?, reminderList: String? = nil) async -> TodoSnapshot {
        _ = await todoService.create(title: title, dueAt: dueAt, reminderList: reminderList)
        await syncTodosIfEnabled()
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
        await syncTodosIfEnabled()
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func deleteTodo(id: String?, index: Int?) async -> TodoSnapshot {
        let removed = await todoService.delete(id: id, index: index)
        for item in removed {
            if let appleId = item.appleId, !appleId.isEmpty {
                try? await remindersSync.deleteReminder(appleId: appleId)
            }
        }
        await syncTodosIfEnabled()
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

    func forceDisplayRefresh() {
        broadcastJson(["type": LANServerMessage.force_refresh])
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
        await broadcastTodoState()
    }

    private func syncTodosIfEnabled() async {
        guard config.remindersSyncEnabled else { return }
        let override = await todoService.consumePendingReminderList()
        await remindersSync.sync(todoService: todoService, config: config, overrideList: override)
        await broadcastTodoState()
    }

    func getReminderLists() async -> [ReminderListInfo] {
        _ = try? await remindersSync.requestAccess()
        return await remindersSync.getReminderListsWithCounts()
    }

    func updateReminderSyncConfig(enabled: Bool, list: String, pollSec: Int) async {
        config.remindersSyncEnabled = enabled
        config.remindersListName = list
        config.remindersPollSec = max(5, pollSec)
        if enabled {
            await remindersSync.startPeriodicSync(todoService: todoService, config: config)
        } else {
            await remindersSync.stopPeriodicSync()
        }
        await broadcastTodoState()
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
        if type != LANDeviceMessage.ping && type != LANDeviceMessage.ptt_start {
            appendServiceLog("消息: \(deviceId) → \(type)")
        }

        switch type {
        case LANDeviceMessage.hello:
            await handleHello(message, from: conn, connId: connId)

        case LANDeviceMessage.ptt_start:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStart(message, connId: connId)

        case LANDeviceMessage.ptt_stop:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStop(connId: connId)

        case LANDeviceMessage.action_send:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleActionSend(connId: connId)

        case LANDeviceMessage.action_undo:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleActionUndo(connId: connId)

        case LANDeviceMessage.todo_command:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleTodoCommand(message, connId: connId)

        case LANDeviceMessage.prompt:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePrompt(message, connId: connId)

        case LANDeviceMessage.action_enter:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            do {
                try await textInjector.pressReturn(dryRun: config.dryRunTextInjection)
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "typed", "text": ""])
            } catch {
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_error", "message": error.localizedDescription])
            }

        case LANDeviceMessage.action_clear_input:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            do {
                try await textInjector.clearInput(dryRun: config.dryRunTextInjection)
                var state = clientStates[connId] ?? ClientState()
                state.injectedSegments.removeAll()
                state.pendingTranscript = ""
                state.pendingSegments = []
                clientStates[connId] = state
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_cleared", "text": ""])
            } catch {
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_error", "message": error.localizedDescription])
                appendServiceLog("清空输入失败: \(error.localizedDescription)")
            }

        case LANDeviceMessage.set_target:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetTarget(message, connId: connId)

        case LANDeviceMessage.set_mode:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetMode(message, connId: connId)

        case LANDeviceMessage.set_cli_cwd:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleSetCliCwd(message, connId: connId)

        case LANDeviceMessage.ping:
            sendJson(to: conn, ["type": LANServerMessage.pong, "nowMs": Int(Date().timeIntervalSince1970 * 1000)])

        case LANDeviceMessage.plan_select:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePlanSelect(message, connId: connId)

        case LANDeviceMessage.plan_apply:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePlanApply(connId: connId)

        case LANDeviceMessage.firmware_progress:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let phase = (message["phase"] as? String) ?? ""
            let pct = (message["pct"] as? Int) ?? 0
            firmwareOtaProgress[deviceId] = (phase, pct)
            appendServiceLog("OTA \(deviceId): \(phase) \(pct)%")

        case LANDeviceMessage.firmware_result:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let ok = (message["ok"] as? Bool) ?? false
            let version = (message["version"] as? String) ?? ""
            let note = (message["message"] as? String) ?? ""
            let finalPct = ok ? 100 : (firmwareOtaProgress[deviceId]?.pct ?? 0)
            firmwareOtaProgress[deviceId] = (ok ? "完成" : "失败", finalPct)
            appendServiceLog("OTA 完成 \(deviceId): ok=\(ok) version=\(version) \(note)")

        case LANDeviceMessage.firmware_check_result:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let needUpgrade = (message["needUpgrade"] as? Bool) ?? true
            if let cont = firmwareCheckContinuations.removeValue(forKey: deviceId) {
                cont.resume(returning: needUpgrade)
            }

        default:
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "unknown_message_type:\(type)"])
        }
    }

    // MARK: - Hello / Auth

    private func handleHello(_ message: [String: Any], from conn: WSConnection, connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        state.deviceId = (message["deviceId"] as? String) ?? "unknown"
        state.boardType = (message["boardType"] as? String) ?? "unknown"

        // Validate auth when shared secret is configured; allow unauthenticated hello for first-time pairing.
        var authenticated = config.lanSharedSecret.isEmpty
        if !config.lanSharedSecret.isEmpty {
            let deviceId = state.deviceId
            let deviceNonce = (message["authNonce"] as? String) ?? ""
            let serverNonce = (message["authServerNonce"] as? String) ?? ""
            let sig = (message["authSig"] as? String) ?? ""
            let expectedServerNonce = clientStates[connId]?.authChallengeNonce ?? ""

            if deviceNonce.isEmpty || sig.isEmpty {
                appendServiceLog("待配对设备连接: \(deviceId)")
                authenticated = false
            } else {
                guard !expectedServerNonce.isEmpty, serverNonce == expectedServerNonce else {
                    closeWithAuthError(conn, connId: connId, error: "auth_challenge_mismatch")
                    return
                }

                let cacheKey = "\(deviceId):\(deviceNonce)"
                guard !recentHelloNonces.keys.contains(cacheKey) else {
                    closeWithAuthError(conn, connId: connId, error: "auth_replayed")
                    return
                }
                pruneRecentHelloNonces()
                recentHelloNonces[cacheKey] = Date()

                let secret = config.lanSharedSecret
                let expected = LANAuth.signHelloChallengePayload(
                    secret: secret,
                    deviceId: deviceId,
                    boardType: state.boardType,
                    serverNonce: serverNonce,
                    deviceNonce: deviceNonce
                )
                guard LANAuth.signaturesMatch(expected, sig) else {
                    closeWithAuthError(conn, connId: connId, error: "auth_invalid")
                    return
                }
                authenticated = true
            }
        }

        state.authenticated = authenticated
        clientStates[connId] = state
        var md = conn.metadata
        md["authenticated"] = authenticated
        conn.metadata = md

        sendJson(to: conn, ["type": LANServerMessage.hello_ack, "deviceId": state.deviceId, "protocolVersion": LANProtocol.version])
        emitServerReady(to: conn)
        broadcastDisplayConfig(to: conn)
        if authenticated {
            emitCliSnapshot(to: conn)
            await emitTodoState(to: conn)
        }

        // Broadcast device_event to all other connected clients
        broadcastJson([
            "type": LANServerMessage.device_event,
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

        if sttService.resolveProvider() == .qwenAsr && config.mockTranscript.isEmpty {
            do {
                let session = QwenStreamingSTTSession(config: config)
                try await session.start { [weak self] partial in
                    Task { await self?.sendTranscriptPartial(partial, connId: connId) }
                }
                streamingSttSessions[connId] = session
            } catch {
                appendServiceLog("流式 STT 启动失败: \(error.localizedDescription)")
            }
        }

        if let conn = await wsServer.connection(id: connId) {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "recording"])
        }
    }

    private func handlePttStop(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        if let session = streamingSttSessions.removeValue(forKey: connId) {
            state.segmentActive = false
            clientStates[connId] = state
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcribing"])
            let startedAt = Date()
            let transcript: String
            if !config.mockTranscript.isEmpty {
                transcript = config.mockTranscript
            } else {
                do {
                    transcript = try await session.finish()
                } catch {
                    appendServiceLog("流式 STT 错误: \(error.localizedDescription)")
                    session.cancel()
                    sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcript_empty"])
                    return
                }
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            appendServiceLog("STT(流式) [\("\(latencyMs)ms")]: \(trimmed.prefix(60))")
            await deliverTranscript(trimmed, latencyMs: latencyMs, connId: connId, conn: conn, state: state)
            return
        }

        let pcmBuffer = state.chunks.reduce(into: Data(capacity: state.audioBytes)) { buffer, chunk in
            buffer.append(chunk)
        }
        let provider = sttService.resolveProvider()
        appendServiceLog("STT 实际提供商: \(provider.rawValue)")
        state.segmentActive = false
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state
        appendServiceLog("PTT停止: \(state.deviceId), bytes=\(pcmBuffer.count)")

        if pcmBuffer.isEmpty {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "empty_segment"])
            return
        }

        sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcribing", "bytes": pcmBuffer.count])
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
        await deliverTranscript(trimmed, latencyMs: latencyMs, connId: connId, conn: conn, state: state)
    }

    private func sendTranscriptPartial(_ text: String, connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendJson(to: conn, [
            "type": LANServerMessage.transcript_partial,
            "text": trimmed,
        ])
    }

    private func deliverTranscript(
        _ trimmed: String,
        latencyMs: Int,
        connId: UUID,
        conn: WSConnection,
        state: ClientState
    ) async {
        var state = state
        state.segmentActive = false
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state

        guard !trimmed.isEmpty else {
            let hadPending = !state.pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sendJson(to: conn, [
                "type": LANServerMessage.status,
                "status": hadPending ? "empty_segment" : "transcript_empty",
                "text": state.pendingTranscript
            ])
            return
        }
        onTranscript?(trimmed)

        let voiceMode = resolveVoiceMode(state)

        // Todo mode: dispatch to todo assistant
        if voiceMode == "todo" {
            sendJson(to: conn, [
                "type": LANServerMessage.transcript_final,
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

        // text_injector always auto-injects on release (immediate). The
        // confirm_on_device delivery mode is only meaningful for codex/claude
        // targets, so force immediate here regardless of the config setting.
        let deliveryMode: String
        if config.sendTarget == "text_injector" {
            deliveryMode = "immediate"
        } else {
            deliveryMode = state.segmentTranscriptDeliveryMode ?? config.transcriptDeliveryMode
        }

        // Confirm-on-device: hold text, wait for action_send
        if deliveryMode == "confirm_on_device" {
            state.pendingSegments.append(trimmed)
            let pendingTranscript = joinPendingSegments(state.pendingSegments)
            state.pendingTranscript = pendingTranscript
            clientStates[connId] = state
            sendJson(to: conn, [
                "type": LANServerMessage.transcript_final,
                "text": pendingTranscript,
                "latencyMs": latencyMs,
                "requiresAction": true
            ])
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "awaiting_action", "text": pendingTranscript])
            return
        }

        // Immediate mode: dispatch right away
        sendJson(to: conn, [
            "type": LANServerMessage.transcript_final,
            "text": trimmed,
            "latencyMs": latencyMs,
            "requiresAction": false
        ])

        let injectionMode = state.segmentTextInjectionMode ?? config.textInjectionMode
        if config.sendTarget == "text_injector" {
            cliView.latestUserText = trimmed
            cliView.latestAssistantText = ""
            cliView.statusLine = "Typed to focused app"
            broadcastCliSummary()
            broadcastCliState()
        }
        do {
            try await dispatchTranscript(trimmed, injectionMode: injectionMode, connId: connId)
        } catch {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_error", "message": error.localizedDescription])
            appendServiceLog("输入失败: \(error.localizedDescription)")
            return
        }

        state.injectedSegments.append(trimmed)
        state.pendingSegments = []
        clientStates[connId] = state
        sendJson(to: conn, ["type": LANServerMessage.status, "status": "typed", "text": trimmed])
    }

    // MARK: - Action Handlers

    private func handleActionSend(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        let transcript = state.pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceMode = resolveVoiceMode(state)

        guard !transcript.isEmpty else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "no_pending"])
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
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "cli_busy"])
                return
            }
            appendServiceLog("输入失败: \(error.localizedDescription)")
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_error", "message": error.localizedDescription])
            return
        }

        if voiceMode == "normal" && config.sendTarget == "text_injector" {
            state.injectedSegments.append(transcript)
        }
        state.pendingTranscript = ""
        state.pendingSegments = []
        clientStates[connId] = state
        sendJson(to: conn, ["type": LANServerMessage.status, "status": "typed", "text": transcript])
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
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "awaiting_action", "text": transcript])
            } else {
                sendJson(to: conn, ["type": LANServerMessage.transcript_cleared])
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "undo_ok"])
            }
            return
        }

        // Otherwise, undo last injected text (text_injector mode only)
        let voiceMode = resolveVoiceMode(state)
        guard voiceMode == "normal", config.sendTarget == "text_injector", !state.injectedSegments.isEmpty else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "no_pending"])
            return
        }

        let removedSegment = state.injectedSegments.popLast()
        let nextTranscript = joinInjectedSegments(state.injectedSegments)
        let injectionMode = state.segmentTextInjectionMode ?? config.textInjectionMode
        let charsToUndo: Int
        if let removed = removedSegment {
            // Backspace count follows extended grapheme clusters (Swift String.count).
            // Limitation: rare combining-mark edge cases may differ from target app; see README §隐私.
            charsToUndo = TextInjector.backspaceSteps(for: removed)
                + (injectionMode == "type_and_enter" ? 1 : 0)
        } else {
            charsToUndo = 0
        }

        guard charsToUndo > 0 else {
            if let removed = removedSegment {
                state.injectedSegments.append(removed)
            }
            clientStates[connId] = state
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "no_pending"])
            return
        }

        do {
            try await textInjector.undoLastInput(length: charsToUndo)
        } catch {
            if let removed = removedSegment {
                state.injectedSegments.append(removed)
            }
            clientStates[connId] = state
            appendServiceLog("undo 注入失败: \(error.localizedDescription)")
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "input_error", "message": error.localizedDescription])
            return
        }

        clientStates[connId] = state

        if nextTranscript.isEmpty {
            sendJson(to: conn, ["type": LANServerMessage.transcript_cleared])
        }
        sendJson(to: conn, ["type": LANServerMessage.status, "status": "undo_ok", "text": nextTranscript])
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
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "prompt_empty"])
            return
        }

        let voiceMode = resolveVoiceMode(state)

        // Check CLI busy — queue instead of rejecting
        if voiceMode == "normal" {
            let claudeBusy = claudeSession.isRunning
            let codexBusy = codexSession.isRunning
            if config.sendTarget == "claude_code" && claudeBusy {
                enqueuePrompt(text, connId: connId, injectionMode: nil)
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "cli_busy"])
                return
            }
            if config.sendTarget == "codex_exec" && codexBusy {
                enqueuePrompt(text, connId: connId, injectionMode: nil)
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "cli_busy"])
                return
            }
        }

        if voiceMode == "todo" {
            await dispatchTodoPrompt(text, connId: connId)
        } else {
            do {
                try await dispatchPrompt(text, connId: connId)
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "typed", "text": text])
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
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "invalid_send_target"])
            return
        }
        guard !codexSession.isRunning && !claudeSession.isRunning else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "cli_busy"])
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

    /// Called from the macOS app when the user changes the send target in the settings UI.
    func updateSendTarget(_ newTarget: String) {
        guard config.sendTarget != newTarget else { return }
        appendServiceLog("发送目标切换: \(config.sendTarget) → \(newTarget)")
        config.sendTarget = newTarget
        broadcastServerReady()
    }

    /// Called from the macOS app when runtime input settings change without a full restart.
    func updateRuntimeInput(sendTarget: String, deliveryMode: String, injectionMode: String) {
        let validTargets: Set<String> = ["text_injector", "codex_exec", "claude_code"]
        let nextTarget = validTargets.contains(sendTarget) ? sendTarget : config.sendTarget
        let nextDelivery = deliveryMode == "immediate" ? "immediate" : "confirm_on_device"
        let nextInjection = injectionMode == "type_only" ? "type_only" : "type_and_enter"

        guard config.sendTarget != nextTarget ||
              config.transcriptDeliveryMode != nextDelivery ||
              config.textInjectionMode != nextInjection else { return }

        appendServiceLog("输入配置切换: target=\(nextTarget), delivery=\(nextDelivery), injection=\(nextInjection)")
        config.sendTarget = nextTarget
        config.transcriptDeliveryMode = nextDelivery
        config.textInjectionMode = nextInjection
        broadcastServerReady()
    }

    /// Allows the macOS client to switch a connected device between coding and todo voice modes.
    func setDeviceVoiceMode(deviceId: String, mode: String) async {
        let nextMode = mode == "todo" ? "todo" : "normal"
        var changed = false

        for (connId, var state) in clientStates where state.deviceId == deviceId {
            state.voiceMode = nextMode
            clientStates[connId] = state
            if let conn = await wsServer.connection(id: connId) {
                sendJson(to: conn, ["type": LANServerMessage.mode_state, "mode": nextMode])
            }
            changed = true
        }

        if changed {
            appendServiceLog("设备模式切换: \(deviceId) → \(nextMode)")
            onDeviceEvent?("mode_changed", deviceId, "")
        }
    }

    private func handleSetMode(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()
        let nextMode = ((message["mode"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validModes: Set<String> = ["normal", "todo"]
        guard validModes.contains(nextMode) else {
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "invalid_voice_mode"])
            return
        }
        if state.voiceMode != nextMode {
            state.voiceMode = nextMode
            clientStates[connId] = state
        }
        sendJson(to: conn, ["type": LANServerMessage.mode_state, "mode": resolveVoiceMode(state)])
    }

    private func handleSetCliCwd(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let target = ((message["sendTarget"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nextCwd = ((message["cwd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard target == "codex_exec" || target == "claude_code" else {
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "invalid_cli_cwd_target"])
            return
        }
        guard !nextCwd.isEmpty else {
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "cli_cwd_empty"])
            return
        }
        let resolved = NSString(string: nextCwd).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolved) else {
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "invalid_cli_cwd:\(nextCwd)"])
            return
        }
        if target == "claude_code" {
            config.claudeCwd = resolved
        } else {
            config.codexCwd = resolved
        }
        sendJson(to: conn, [
            "type": LANServerMessage.cli_cwd_updated,
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
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "invalid_plan_select_direction"])
            return
        }
        guard !state.planOptions.isEmpty else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "no_plan_options"])
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

        let cliBusy = config.sendTarget == "claude_code" ? claudeSession.isRunning : codexSession.isRunning
        guard !cliBusy else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "cli_busy"])
            return
        }

        guard state.planOptions.count > 0,
              state.planSelectedIndex >= 0,
              state.planSelectedIndex < state.planOptions.count else {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "no_plan_options"])
            return
        }

        let selectedOption = state.planOptions[state.planSelectedIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = buildPlanApplyPrompt(selectedOption)

        sendJson(to: conn, ["type": LANServerMessage.status, "status": "typed", "text": prompt])
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
            streamingSttSessions.removeValue(forKey: connId)?.cancel()
            if let conn = await wsServer.connection(id: connId) {
                sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "audio_too_large"])
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "audio_too_large"])
            }
            return
        }

        if let session = streamingSttSessions[connId] {
            session.append(pcm16: data)
            state.audioBytes = nextBytes
            clientStates[connId] = state
            return
        }

        state.audioBytes = nextBytes
        state.chunks.append(data)
        clientStates[connId] = state
    }

    // MARK: - Transcript Dispatch

    /// Dispatches text to the appropriate target (injector / codex / claude).
    private func dispatchTranscript(_ text: String, injectionMode: String, connId: UUID) async throws {
        switch config.sendTarget {
        case "codex_exec":
            if codexSession.isRunning {
                enqueuePrompt(text, connId: connId, injectionMode: injectionMode)
                return
            }
            launchCodexPrompt(text)
        case "claude_code":
            if claudeSession.isRunning {
                enqueuePrompt(text, connId: connId, injectionMode: injectionMode)
                return
            }
            launchClaudePrompt(text)
        default:
            try await textInjector.inject(text, mode: injectionMode == "type_only" ? .typeOnly : .typeAndEnter,
                                          dryRun: config.dryRunTextInjection)
        }
    }

    /// Full prompt dispatch with queue serialization.
    private func dispatchPrompt(_ text: String, injectionMode: String? = nil, connId: UUID) async throws {
        let mode = injectionMode ?? config.textInjectionMode

        switch config.sendTarget {
        case "codex_exec":
            if codexSession.isRunning {
                enqueuePrompt(text, connId: connId, injectionMode: mode)
                return
            }
            await runCodexPrompt(text)
        case "claude_code":
            if claudeSession.isRunning {
                enqueuePrompt(text, connId: connId, injectionMode: mode)
                return
            }
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
        let threadId = codexSession.threadId
        cliView.latestUserText = text
        cliView.latestAssistantText = ""
        setCliState(phase: "running", statusLine: "Running Codex...", threadId: threadId)
        broadcastCliSummary()
        appendCliLog("user: \(text.prefix(80))")

        do {
            let bridge = CLIEventBridge { [weak self] event in
                Task { await self?.handleCLIEvent(event, source: "codex", connId: nil) }
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
        let sessionId = claudeSession.sessionId ?? ""
        cliView.latestUserText = text
        cliView.latestAssistantText = ""
        setCliState(phase: "running", statusLine: "Running Claude...", threadId: sessionId)
        broadcastCliSummary()
        appendCliLog("user: \(text.prefix(80))")

        do {
            let bridge = CLIEventBridge { [weak self] event in
                Task { await self?.handleCLIEvent(event, source: "claude", connId: nil) }
            }
            claudeEventBridge = bridge
            claudeSession.delegate = bridge
            try claudeSession.start(prompt: text, config: config)
        } catch {
            setCliState(phase: "error", statusLine: "Claude error: \(error.localizedDescription)")
            appendCliLog("error: \(error.localizedDescription)")
        }
    }

    private func handleCLIEvent(_ event: CLIEvent, source: String, connId: UUID?) async {
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
            lastExternalSnapshotSignature = ""
            cliView.threadId = result.sessionId ?? ""
            setCliState(phase: result.success ? "idle" : "error",
                       statusLine: result.success ? "\(source.capitalized) idle" : "Error: exit \(result.exitCode ?? -1)",
                       threadId: cliView.threadId)
            broadcastCliSummary()
            refreshRateLimits()
            if result.success, !result.text.isEmpty {
                await applyPlanOptionsFromAssistantText(result.text, connId: connId)
            }
            await drainPromptQueue()
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

    private func enqueuePrompt(_ text: String, connId: UUID, injectionMode: String?) {
        cliPromptQueue.append((text, connId, injectionMode))
        appendServiceLog("CLI 排队 (\(cliPromptQueue.count)): \(text.prefix(40))")
    }

    private func drainPromptQueue() async {
        guard !codexSession.isRunning, !claudeSession.isRunning else { return }
        guard !cliPromptQueue.isEmpty else { return }
        let next = cliPromptQueue.removeFirst()
        appendServiceLog("CLI 出队: \(next.text.prefix(40))")
        do {
            try await dispatchPrompt(next.text, injectionMode: next.injectionMode, connId: next.connId)
        } catch {
            appendCliLog("error: \(error.localizedDescription)")
            setCliState(phase: "error", statusLine: error.localizedDescription)
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
        sendJson(to: conn, serverReadyPayload())
    }

    private func serverReadyPayload() -> [String: Any] {
        [
            "type": LANServerMessage.server_ready,
            "protocolVersion": LANProtocol.version,
            "textInjectionMode": config.textInjectionMode,
            "transcriptDeliveryMode": config.transcriptDeliveryMode,
            "sendTarget": config.sendTarget,
            "authRequired": !config.lanSharedSecret.isEmpty,
            "displayTodoRefreshMs": config.displayTodoRefreshMs,
            "displayCodingRefreshMs": config.displayCodingRefreshMs,
            "displayStyle": config.displayStyle
        ]
    }

    func broadcastServerReady() {
        Task { [weak self] in
            guard let self else { return }
            await self.wsServer.broadcast(json: self.serverReadyPayload())
        }
    }

    func broadcastCliState() {
        refreshRateLimits()
        var payload: [String: Any] = [
            "type": LANServerMessage.cli_session_state,
            "phase": cliView.phase,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": effectiveRepoLabel,
            "cwd": cliView.cwd
        ]
        if let q5 = cliView.quota5hRemainingPct { payload["quota5hRemainingPct"] = q5 }
        if let qw = cliView.quotaWeekRemainingPct { payload["quotaWeekRemainingPct"] = qw }
        broadcastJson(payload)
        onCliStateChange?(payload)
    }

    private func refreshRateLimits() {
        guard config.sendTarget == "codex_exec" || config.sendTarget == "claude_code" else { return }
        guard let snapshot = CLIRateLimits.readLatest(sendTarget: config.sendTarget, threadId: cliView.threadId) else {
            return
        }
        cliView.quota5hRemainingPct = snapshot.primaryRemainingPct
        cliView.quotaWeekRemainingPct = snapshot.secondaryRemainingPct
    }

    private func applyPlanOptionsFromAssistantText(_ text: String, connId: UUID?) async {
        let options = PlanOptionsExtractor.extract(from: text)
        guard !options.isEmpty else { return }

        if let connId, var state = clientStates[connId] {
            state.planOptions = options
            state.planSelectedIndex = 0
            clientStates[connId] = state
            if let conn = await wsServer.connection(id: connId) {
                emitPlanOptions(to: conn, state: state)
            }
            return
        }

        for (id, var state) in clientStates where state.authenticated {
            state.planOptions = options
            state.planSelectedIndex = 0
            clientStates[id] = state
            if let conn = await wsServer.connection(id: id) {
                emitPlanOptions(to: conn, state: state)
            }
        }
    }

    func broadcastCliSummary() {
        broadcastJson([
            "type": LANServerMessage.cli_summary,
            "latestUserText": cliView.latestUserText,
            "latestAssistantText": cliView.latestAssistantText,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": effectiveRepoLabel
        ])
        onCliSummary?(cliView.latestUserText, cliView.latestAssistantText)
    }

    func broadcastTodoState() async {
        let payload = await todoStatePayload()
        broadcastJson(payload)
        onTodoStateChange?(payload)
    }

    private func emitTodoState(to conn: WSConnection) async {
        let payload = await todoStatePayload()
        sendJson(to: conn, payload)
    }

    private func todoStatePayload() async -> [String: Any] {
        let snapshot = await getTodoSnapshot()
        return [
            "type": LANServerMessage.todo_state,
            "items": snapshot.items.map { itemToDict($0) },
            "archiveItems": snapshot.archiveItems.map { itemToDict($0) },
            "selectedIndex": snapshot.selectedIndex,
            "lastActionText": snapshot.lastActionText
        ]
    }

    func broadcastDisplayConfig(to conn: WSConnection? = nil) {
        let payload: [String: Any] = [
            "type": LANServerMessage.display_config,
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

    private func startExternalCliWatcher() {
        externalWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: externalWatchIntervalMs * 1_000_000)
                guard let self else { break }
                let running = await self.isRunning
                guard running else { break }
                await self.pollExternalCliState()
            }
        }
    }

    private func stopExternalCliWatcher() {
        externalWatchTask?.cancel()
        externalWatchTask = nil
        lastExternalSnapshotSignature = ""
    }

    private func pollExternalCliState() async {
        guard config.sendTarget == "codex_exec" || config.sendTarget == "claude_code" else { return }
        guard !codexSession.isRunning && !claudeSession.isRunning else { return }

        if config.sendTarget == "codex_exec" {
            guard let file = CodexRolloutParser.findLatestRolloutFile(threadId: cliView.threadId),
                  let snapshot = CodexRolloutParser.snapshot(from: file) else { return }
            applyExternalCodexSnapshot(snapshot)
        } else {
            guard let snapshot = ClaudeTranscriptParser.discoverLatest(cwdFilter: config.claudeCwd) else { return }
            applyExternalClaudeSnapshot(snapshot)
        }
    }

    private func applyExternalCodexSnapshot(_ snapshot: CodexRolloutSnapshot) {
        let signature = [
            snapshot.sessionId,
            snapshot.phase,
            snapshot.lastAssistantMessage,
            snapshot.currentTool,
            snapshot.summary
        ].joined(separator: "|")
        guard signature != lastExternalSnapshotSignature else { return }
        lastExternalSnapshotSignature = signature

        if !snapshot.sessionId.isEmpty { cliView.threadId = snapshot.sessionId }
        if !snapshot.lastUserPrompt.isEmpty { cliView.latestUserText = snapshot.lastUserPrompt }
        if !snapshot.lastAssistantMessage.isEmpty { cliView.latestAssistantText = snapshot.lastAssistantMessage }
        let status = !snapshot.currentTool.isEmpty
            ? "\(snapshot.currentTool)…"
            : (snapshot.summary.isEmpty ? "Codex" : snapshot.summary)
        setCliState(
            phase: snapshot.phase,
            statusLine: String(status.prefix(120)),
            threadId: snapshot.sessionId.isEmpty ? nil : snapshot.sessionId
        )
        if let primary = snapshot.primaryUsedPct {
            cliView.quota5hRemainingPct = max(0, Int((100 - primary).rounded()))
        }
        if let secondary = snapshot.secondaryUsedPct {
            cliView.quotaWeekRemainingPct = max(0, Int((100 - secondary).rounded()))
        }
        broadcastCliState()
        broadcastCliSummary()
    }

    private func applyExternalClaudeSnapshot(_ snapshot: ClaudeTranscriptSnapshot) {
        let signature = [
            snapshot.sessionId,
            snapshot.lastAssistantMessage,
            snapshot.currentTool,
            snapshot.lastUserPrompt
        ].joined(separator: "|")
        guard signature != lastExternalSnapshotSignature else { return }
        lastExternalSnapshotSignature = signature

        if !snapshot.sessionId.isEmpty { cliView.threadId = snapshot.sessionId }
        if !snapshot.lastUserPrompt.isEmpty { cliView.latestUserText = snapshot.lastUserPrompt }
        if !snapshot.lastAssistantMessage.isEmpty { cliView.latestAssistantText = snapshot.lastAssistantMessage }
        let status = !snapshot.currentTool.isEmpty
            ? "\(snapshot.currentTool)…"
            : (snapshot.lastAssistantMessage.isEmpty ? "Claude" : String(snapshot.lastAssistantMessage.prefix(120)))
        setCliState(
            phase: "running",
            statusLine: status,
            threadId: snapshot.sessionId.isEmpty ? nil : snapshot.sessionId
        )
        refreshRateLimits()
        broadcastCliState()
        broadcastCliSummary()
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

        if !config.lanSharedSecret.isEmpty {
            let serverNonce = UUID().uuidString.lowercased()
            state.authChallengeNonce = serverNonce
            clientStates[conn.id] = state
            sendJson(to: conn, ["type": LANServerMessage.auth_challenge, "serverNonce": serverNonce])
        }

        // Wire message handler
        conn.onMessage = { [weak self] message in
            Task { await self?.handleWSMessage(message, connId: conn.id) }
        }
        conn.onPong = { [weak self] in
            Task { await self?.markConnectionAlive(conn.id) }
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
            "type": LANServerMessage.device_event,
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
        markConnectionAlive(connId)
        switch message {
        case .text(let text):
            handleTextMessage(text, connId: connId)
        case .binary(let data):
            await handleBinary(data, connId: connId)
        }
    }

    private func markConnectionAlive(_ connId: UUID) {
        guard var state = clientStates[connId] else { return }
        state.missedPings = 0
        clientStates[connId] = state
    }

    // MARK: - Private Helpers

    private func sendJson(to conn: WSConnection, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        conn.send(text: str)
    }

    private func sendTodoResult(to conn: WSConnection, ok: Bool, action: String, message: String) {
        sendJson(to: conn, [
            "type": LANServerMessage.todo_result,
            "ok": ok,
            "action": action,
            "message": message
        ])
    }

    private func emitServerReady(to conn: WSConnection) {
        broadcastServerReady(to: conn)
    }

    private func emitCliSnapshot(to conn: WSConnection) {
        refreshRateLimits()
        var cliState: [String: Any] = [
            "type": LANServerMessage.cli_session_state,
            "phase": cliView.phase,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": effectiveRepoLabel,
            "cwd": cliView.cwd
        ]
        if let q5 = cliView.quota5hRemainingPct { cliState["quota5hRemainingPct"] = q5 }
        if let qw = cliView.quotaWeekRemainingPct { cliState["quotaWeekRemainingPct"] = qw }
        sendJson(to: conn, cliState)
        sendJson(to: conn, [
            "type": LANServerMessage.cli_summary,
            "latestUserText": cliView.latestUserText,
            "latestAssistantText": cliView.latestAssistantText,
            "statusLine": cliView.statusLine,
            "threadId": cliView.threadId,
            "repoName": effectiveRepoLabel
        ])
        sendJson(to: conn, [
            "type": LANServerMessage.cli_log_tail,
            "lines": cliView.logLines
        ])
    }

    private func resolveFirmwareVersion(binURL: URL) -> String? {
        let metadataURL = binURL.deletingLastPathComponent().appendingPathComponent("project_description.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let candidates = ["project_version", "app_version", "version"]
        for key in candidates {
            if let raw = json[key] as? String {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func emitPlanOptions(to conn: WSConnection, state: ClientState) {
        sendJson(to: conn, [
            "type": LANServerMessage.plan_options,
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
        sendJson(to: conn, ["type": LANServerMessage.error, "error": error])
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

    /// Label broadcast as `repoName` to the device header. Falls back to a
    /// target-derived name when no real repo name is set, so the e-paper
    /// header reflects the actual send target instead of a stale "codex".
    private var effectiveRepoLabel: String {
        let stored = cliView.repoName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        switch config.sendTarget {
        case "claude_code": return "Claude"
        case "text_injector": return "Inject"
        default: return "Codex"
        }
    }

    private func appendCliLog(_ line: String) {
        cliView.pushLogLine(line)
        broadcastJson(["type": LANServerMessage.cli_log_tail, "lines": cliView.logLines])
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
    case firmwareUpToDate

    var errorDescription: String? {
        switch self {
        case .cliBusy: "CLI session is busy"
        case .notRunning: "Server is not running"
        case .firmwareUpToDate: "Device firmware is already up to date"
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
