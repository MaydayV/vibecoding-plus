import AppKit
import Combine
import Foundation

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
    @Published var installLog = ""
    @Published var inlineStatus = ""
    @Published var isBusy = false

    let bridge = BridgeService()
    private let settingsStore = SettingsStore()
    private let checker = EnvironmentChecker()

    init() {
        config = settingsStore.loadConfig()
        desktopSettings = settingsStore.loadDesktopSettings()
    }

    var admin: AdminAPIClient {
        AdminAPIClient(port: config.port)
    }

    func bootstrap() async {
        await refreshEnvironment()
        await refreshRuntime()
    }

    func startService() async {
        await bridge.start(config: config)
        await refreshRuntime()
    }

    func stopService() async {
        await bridge.stop()
    }

    func restartService() async {
        await bridge.restart(config: config)
        await refreshRuntime()
    }

    func saveSettings(restart: Bool = true) async {
        do {
            try settingsStore.saveConfig(config)
            try settingsStore.saveDesktopSettings(desktopSettings)
            syncLoginItem()
            inlineStatus = restart ? "已保存；后台服务会重启，通常几秒内生效" : "已保存"
            if restart, bridge.snapshot.status == .running {
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
        inlineStatus = "已打开系统设置，请允许辅助功能/自动化/麦克风权限"
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
        bridge.openConfigFolder()
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
        await bridge.refreshHealth(config: config)
        guard bridge.snapshot.status == .running else { return }
        do {
            async let nextDevices = admin.getDevices()
            async let nextStatus = admin.getServiceStatus()
            async let nextTodos = admin.getTodos()
            async let nextSync = admin.syncStatus()
            devices = try await nextDevices
            serviceStatus = try await nextStatus
            let snapshot = try await nextTodos
            todos = snapshot.items
            archivedTodos = snapshot.archiveItems
            syncStatus = try await nextSync.status
        } catch {
            inlineStatus = "刷新失败：\(error.localizedDescription)"
        }
    }

    func discoverDevices() async {
        do {
            try await admin.discover()
            inlineStatus = "已发送发现请求"
            try? await Task.sleep(for: .seconds(2))
            await refreshRuntime()
        } catch {
            inlineStatus = "发现失败：\(error.localizedDescription)"
        }
    }

    func addTodo(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineStatus = "请输入待办内容"
            return
        }
        do {
            try await admin.createTodo(title: trimmed)
            inlineStatus = "待办已添加，设备会在下一次刷新周期更新"
            await refreshRuntime()
        } catch {
            inlineStatus = "添加失败：\(error.localizedDescription)"
        }
    }

    func setTodo(_ item: TodoItem, completed: Bool) async {
        do {
            try await admin.updateTodo(id: item.id, completed: completed)
            inlineStatus = completed ? "待办已完成" : "待办已恢复"
            await refreshRuntime()
        } catch {
            inlineStatus = "更新失败：\(error.localizedDescription)"
        }
    }

    func deleteTodo(_ item: TodoItem) async {
        do {
            try await admin.deleteTodo(id: item.id)
            inlineStatus = "待办已删除；如已同步提醒事项，会尝试同步删除"
            await refreshRuntime()
        } catch {
            inlineStatus = "删除失败：\(error.localizedDescription)"
        }
    }

    func runReminderSync() async {
        do {
            try await admin.runSyncNow()
            inlineStatus = "提醒同步已执行"
            await refreshRuntime()
        } catch {
            inlineStatus = "同步失败：\(error.localizedDescription)"
        }
    }

    private func syncLoginItem() {
        // ServiceManagement migration will replace this placeholder in phase 2.
    }
}
