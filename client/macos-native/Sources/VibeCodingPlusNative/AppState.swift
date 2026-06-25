import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig
    @Published var desktopSettings: DesktopSettings
    @Published var environmentReport: EnvironmentReport?
    @Published var devices: [DeviceInfo] = []
    @Published var todos: [TodoItem] = []
    @Published var archivedTodos: [TodoItem] = []
    @Published var serviceStatus: ServiceStatusPayload?
    @Published var syncStatus: ReminderSyncStatus?
    @Published var displayConfig = DisplayConfig()
    @Published var reminderLists: [ReminderListInfo] = []
    @Published var liveActivity = LiveActivity()
    @Published var installLog = ""
    @Published var inlineStatus = ""
    @Published var isBusy = false
    @Published var serviceRunning = false

    private var nativeServer: NativeServer?
    private let settingsStore = SettingsStore()
    private let checker = EnvironmentChecker()

    init() {
        config = settingsStore.loadConfig()
        desktopSettings = settingsStore.loadDesktopSettings()
    }

    // MARK: - ServerConfig Bridge

    private func makeServerConfig() -> ServerConfig {
        var sc = ServerConfig.load()
        sc.sendTarget = config.sendTarget.rawValue
        sc.sttProvider = config.sttProvider.rawValue
        sc.transcriptDeliveryMode = config.transcriptDeliveryMode
        sc.textInjectionMode = config.textInjectionMode
        sc.port = config.port
        sc.discoveryHostId = config.discoveryHostId
        sc.discoveryPort = config.discoveryPort
        sc.lanSharedSecret = config.lanSharedSecret
        sc.deepSeekApiKey = config.deepSeekApiKey
        sc.deepSeekModel = config.deepSeekModel
        sc.deepSeekBaseUrl = config.deepSeekBaseUrl
        sc.openaiApiKey = config.openaiApiKey
        sc.openaiModel = config.openaiModel
        sc.openaiBaseUrl = config.openaiBaseUrl
        sc.volcengineAppKey = config.volcengineAppKey
        sc.volcengineAccessKey = config.volcengineAccessKey
        sc.whisperCppModelPath = config.whisperCppModelPath
        sc.whisperCppLanguage = config.whisperCppLanguage
        sc.whisperCppThreads = Int(config.whisperCppThreads) ?? 4
        sc.whisperCppCommand = config.whisperCppCommand
        sc.whisperCppExtraArgs = config.whisperCppExtraArgs
        sc.qwenAsrApiKey = config.qwenAsrApiKey
        sc.qwenAsrModel = config.qwenAsrModel
        sc.qwenAsrLanguage = config.qwenAsrLanguage
        sc.qwenAsrSampleRate = Int(config.qwenAsrSampleRate) ?? 16000
        sc.qwenAsrRealtimeBaseUrl = config.qwenAsrRealtimeBaseUrl
        sc.qwenAsrPrompt = config.qwenAsrPrompt
        sc.claudeCommand = config.claudeCommand
        sc.claudeCwd = config.claudeCwd
        sc.claudeMaxTurns = config.claudeMaxTurns
        sc.claudeDangerouslySkipPermissions = config.claudeDangerouslySkipPermissions
        sc.codexCommand = config.codexCommand
        sc.codexCwd = config.codexCwd
        sc.codexSkipGitRepoCheck = config.codexSkipGitRepoCheck
        sc.mockTranscript = config.mockTranscript
        sc.remindersSyncEnabled = config.remindersSyncEnabled
        sc.remindersListName = config.remindersListName
        sc.remindersPollSec = config.remindersPollSec
        sc.displayTodoRefreshMs = config.displayTodoRefreshMs
        sc.displayCodingRefreshMs = config.displayCodingRefreshMs
        sc.displayStyle = config.displayStyle
        return sc
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        await refreshEnvironment()
        if serviceRunning {
            await refreshRuntime()
        }
    }

    func startService() async {
        do {
            let sc = makeServerConfig()
            let server = NativeServer(config: sc)
            nativeServer = server

            // Wire all NativeServer callbacks directly (replaces old WebSocketClient loopback)
            server.onStatusChange = { [weak self] status, message in
                Task { @MainActor in
                    self?.inlineStatus = message
                    self?.serviceRunning = (status == .running)
                }
            }
            server.onTranscript = { [weak self] text in
                Task { @MainActor in self?.liveActivity.lastTranscript = text }
            }
            server.onCliSummary = { [weak self] userText, assistantText in
                Task { @MainActor in
                    self?.liveActivity.lastUserText = userText
                    self?.liveActivity.lastAssistantText = assistantText
                }
            }
            server.onCliStateChange = { [weak self] json in
                Task { @MainActor in
                    if let statusLine = json["statusLine"] as? String {
                        self?.liveActivity.cliStatus = statusLine
                    }
                }
            }
            server.onCliLogTail = { [weak self] lines in
                Task { @MainActor in self?.liveActivity.cliLogLines = lines }
            }
            server.onServiceLog = { [weak self] lines in
                Task { @MainActor in self?.liveActivity.serviceLogLines = lines }
            }
            server.onDeviceEvent = { [weak self] event, deviceId, boardType in
                Task { @MainActor in
                    await self?.refreshRuntime()
                    if event == "disconnected" {
                        let content = UNMutableNotificationContent()
                        content.title = "设备断开"
                        content.body = "设备 \(deviceId) 已断开连接"
                        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                        try? await UNUserNotificationCenter.current().add(request)
                    }
                }
            }
            server.onTodoStateChange = { [weak self] json in
                Task { @MainActor in
                    guard let self else { return }
                    if let items = json["items"] as? [[String: Any]],
                       let data = try? JSONSerialization.data(withJSONObject: items),
                       let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
                        self.todos = decoded
                    }
                    if let archiveItems = json["archiveItems"] as? [[String: Any]],
                       let data = try? JSONSerialization.data(withJSONObject: archiveItems),
                       let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
                        self.archivedTodos = decoded
                    }
                }
            }

            try await server.start()
            serviceRunning = true
            inlineStatus = "原生服务运行中 (port \(sc.port))"
            await refreshRuntime()
        } catch {
            print("[AppState] startService error: \(error)")
            inlineStatus = "启动失败：\(error.localizedDescription)"
            serviceRunning = false
        }
    }

    func stopService() async {
        await nativeServer?.stop()
        nativeServer = nil
        serviceRunning = false
        inlineStatus = "服务已停止"
    }

    func restartService() async {
        await stopService()
        await startService()
    }

    func toggleService() async {
        if serviceRunning {
            await stopService()
        } else {
            await startService()
        }
    }

    func saveSettings(restart: Bool = true) async {
        do {
            try settingsStore.saveConfig(config)
            try settingsStore.saveDesktopSettings(desktopSettings)
            syncLoginItem()
            inlineStatus = restart ? "已保存；后台服务会重启，通常几秒内生效" : "已保存"
            if restart, serviceRunning {
                await restartService()
            }
            await refreshEnvironment()
        } catch {
            inlineStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    func refreshEnvironment() async {
        environmentReport = await checker.check(config: config)
    }

    func install(toolId: String) async {
        let script = checker.installScript(for: toolId)
        guard !script.isEmpty else { return }
        isBusy = true
        installLog = "开始安装 \(toolId)...\n"
        inlineStatus = "正在安装 \(toolId)"
        let result = await Shell.runBash(script) { [weak self] text in
            Task { @MainActor in self?.installLog += text }
        }
        isBusy = false
        inlineStatus = result.code == 0 ? "\(toolId) 安装完成，请重新检测" : "\(toolId) 安装失败，退出码 \(result.code)"
        if installLog.isEmpty {
            installLog = result.output
        }
        await refreshEnvironment()
    }

    func openPermissions() {
        checker.openPermissions()
        inlineStatus = "已打开系统设置，请允许辅助功能/自动化/麦克风权限；授权后自动重新检测"
        Task {
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(3))
                await refreshEnvironment()
            }
        }
    }

    func openToolLogin(_ id: String) {
        do {
            try checker.openToolLogin(id)
            inlineStatus = "已打开终端，请完成登录或检查"
        } catch {
            inlineStatus = "打开终端失败：\(error.localizedDescription)"
        }
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(settingsStore.configDirectory)
    }

    func propagateSendTarget() {
        guard serviceRunning, let server = nativeServer else { return }
        let target = config.sendTarget.rawValue
        Task { await server.updateSendTarget(target) }
    }

    func propagateRuntimeInput() {
        guard serviceRunning, let server = nativeServer else { return }
        let target = config.sendTarget.rawValue
        let deliveryMode = config.transcriptDeliveryMode
        let injectionMode = config.textInjectionMode
        Task { await server.updateRuntimeInput(sendTarget: target, deliveryMode: deliveryMode, injectionMode: injectionMode) }
    }

    func setDeviceVoiceMode(_ device: DeviceInfo, mode: String) async {
        guard let server = nativeServer else { return }
        await server.setDeviceVoiceMode(deviceId: device.deviceId, mode: mode)
        inlineStatus = mode == "todo" ? "已切换到备忘模式" : "已切换到编程模式"
        await refreshRuntime()
    }

    func chooseDirectory(for target: SendTarget) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            switch target {
            case .codexExec:
                config.codexCwd = url.path
            case .claudeCode:
                config.claudeCwd = url.path
            case .textInjector:
                break
            }
        }
    }

    func refreshRuntime() async {
        guard let server = nativeServer, serviceRunning else { return }

        let devices = await server.getDevices()
        let status = await server.getServiceStatus()
        let todoSnap = await server.getTodoSnapshot()
        let syncStatusRaw = await server.getSyncStatus()
        let dc = await server.getDisplayConfig()

        self.devices = devices.map { dict in
            DeviceInfo(
                deviceId: dict["deviceId"] as? String ?? "unknown",
                boardType: dict["boardType"] as? String,
                voiceMode: dict["voiceMode"] as? String,
                remoteAddress: dict["remoteAddress"] as? String,
                connectedAt: dict["connectedAt"] as? Double
            )
        }
        self.serviceStatus = ServiceStatusPayload(
            ok: status["ok"] as? Bool ?? false,
            clientCount: status["clientCount"] as? Int,
            sttProvider: status["sttProvider"] as? String,
            sendTarget: status["sendTarget"] as? String,
            discoveryEnabled: status["discoveryEnabled"] as? Bool,
            port: status["port"] as? Int
        )
        applyTodoSnapshot(todoSnap)
        self.displayConfig = dc
        self.syncStatus = ReminderSyncStatus(
            enabled: syncStatusRaw["enabled"] as? Bool,
            lastSyncAt: syncStatusRaw["lastSyncAt"] as? Double,
            syncCount: syncStatusRaw["syncCount"] as? Int,
            lastError: syncStatusRaw["lastError"] as? String,
            list: syncStatusRaw["list"] as? String,
            pollSec: syncStatusRaw["pollSec"] as? Int
        )
    }

    func discoverDevices() async {
        nativeServer?.triggerDiscovery(config: makeServerConfig())
        inlineStatus = "已发送发现请求"
        try? await Task.sleep(for: .seconds(2))
        await refreshRuntime()
    }

    // MARK: - Todo

    func addTodo(_ title: String, dueAt: String? = nil, reminderList: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineStatus = "请输入待办内容"
            return
        }
        guard let server = nativeServer else {
            inlineStatus = "请先启动服务"
            return
        }
        let snapshot = await server.createTodo(title: trimmed, dueAt: dueAt, reminderList: reminderList)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已添加"
    }

    func setTodo(_ item: TodoItem, completed: Bool) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.updateTodo(id: item.id, index: nil, title: nil, dueAt: nil, completed: completed)
        applyTodoSnapshot(snapshot)
        inlineStatus = completed ? "待办已完成" : "待办已恢复"
    }

    func editTodo(_ item: TodoItem, title: String, dueAt: String?) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.updateTodo(id: item.id, index: nil, title: title, dueAt: dueAt, completed: nil)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已更新"
    }

    func deleteTodo(_ item: TodoItem) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.deleteTodo(id: item.id, index: nil)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已删除"
    }

    private func applyTodoSnapshot(_ snapshot: TodoSnapshot) {
        todos = snapshot.items
        archivedTodos = snapshot.archiveItems
    }

    // MARK: - Reminder Sync

    func runReminderSync() async {
        await nativeServer?.runSyncNow()
        inlineStatus = "提醒同步已执行"
        await refreshRuntime()
    }

    func fetchSyncLists() async {
        guard let server = nativeServer else { return }
        reminderLists = await server.getReminderLists()
    }

    func saveSyncConfig(enabled: Bool, list: String, pollSec: Int) async {
        config.remindersSyncEnabled = enabled
        config.remindersListName = list
        config.remindersPollSec = pollSec
        try? settingsStore.saveConfig(config)
        await nativeServer?.updateReminderSyncConfig(enabled: enabled, list: list, pollSec: pollSec)
        inlineStatus = enabled ? "同步配置已保存并启用" : "同步配置已保存并停用"
        await refreshRuntime()
    }

    // MARK: - Display Config

    func fetchDisplayConfig() async {
        guard let server = nativeServer else { return }
        displayConfig = await server.getDisplayConfig()
    }

    func saveDisplayConfig() async {
        await nativeServer?.updateDisplayConfig(displayConfig)
        config.displayTodoRefreshMs = displayConfig.todoRefreshMs
        config.displayCodingRefreshMs = displayConfig.codingRefreshMs
        config.displayStyle = displayConfig.style
        try? settingsStore.saveConfig(config)
        inlineStatus = "显示配置已保存并推送到设备"
        await refreshRuntime()
    }

    func forceDisplayRefresh() async {
        await nativeServer?.forceDisplayRefresh()
        inlineStatus = "已请求设备立即刷新屏幕"
    }

    // MARK: - Server Restart

    func restartServer() async {
        inlineStatus = "服务正在重启..."
        await restartService()
    }

    // MARK: - Login Item (Auto-Launch)

    private func syncLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if desktopSettings.autoLaunch {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[LoginItem] \(error.localizedDescription)")
            }
        }
    }

}
