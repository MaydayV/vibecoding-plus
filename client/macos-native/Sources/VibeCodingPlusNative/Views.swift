import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case overview
    case devices
    case todo
    case reminders
    case display
    case environment
    case settings
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "概览"
        case .devices: "设备"
        case .todo: "待办"
        case .reminders: "提醒"
        case .display: "显示"
        case .environment: "环境"
        case .settings: "设置"
        case .logs: "日志"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "speedometer"
        case .devices: "display.2"
        case .todo: "checklist"
        case .reminders: "bell.badge"
        case .display: "paintbrush"
        case .environment: "checklist.checked"
        case .settings: "gearshape"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SidebarTab? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selection) { item in
                Label(item.label, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ZStack {
                GlassBackground()
                content
                    .padding(20)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("刷新") { Task { await state.refreshRuntime(); await state.refreshEnvironment() } }
                        .glassButton()
                    Button("启动") { Task { await state.startService() } }
                        .glassProminentButton()
                        .disabled(state.serviceRunning)
                    Button("重启") { Task { await state.restartService() } }
                        .glassButton()
                    Button("停止") { Task { await state.stopService() } }
                        .glassButton()
                        .disabled(!state.serviceRunning)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView()
        case .devices:
            DevicesView()
        case .todo:
            TodoView()
        case .reminders:
            RemindersView()
        case .display:
            DisplayConfigView()
        case .environment:
            EnvironmentView()
        case .settings:
            SettingsView()
        case .logs:
            LogsView()
        }
    }
}

// MARK: - Overview with Live Activity

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "概览", subtitle: state.inlineStatus)
            HStack(spacing: 12) {
                MetricView(title: "服务", value: (state.serviceRunning ? "运行中" : "已停止"), detail: state.inlineStatus)
                MetricView(title: "模式", value: state.config.sendTarget.label, detail: "端口 \(state.config.port)")
                MetricView(title: "设备", value: "\(state.devices.count)", detail: state.serviceStatus?.discoveryEnabled == true ? "发现服务已启用" : "发现服务未启用")
                MetricView(title: "STT", value: state.config.sttProvider.label, detail: state.serviceStatus?.sttProvider ?? "--")
            }
            .frame(maxWidth: .infinity)

            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("实时活动").font(.headline)
                    HStack(spacing: 12) {
                        LiveField(label: "最后语音识别", value: state.liveActivity.lastTranscript)
                        LiveField(label: "最后用户文本", value: state.liveActivity.lastUserText)
                        LiveField(label: "最后 AI 回复", value: state.liveActivity.lastAssistantText)
                    }
                    if !state.liveActivity.cliStatus.isEmpty {
                        Text("CLI 状态：\(state.liveActivity.cliStatus)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("近期日志").font(.headline)
                    LogText(lines: Array(state.liveActivity.cliLogLines.suffix(12)))
                }
            }

            Spacer()
        }
    }
}

struct LiveField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "--" : value)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Environment

struct EnvironmentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "环境", subtitle: state.inlineStatus)
            HStack {
                Button("重新检测") { Task { await state.refreshEnvironment() } }
                    .glassButton()
                Button("安装缺失项") {
                    Task {
                        for item in state.environmentReport?.checks.filter({ $0.status == "missing" && $0.installable }) ?? [] {
                            await state.install(toolId: item.id)
                        }
                    }
                }
                .glassProminentButton()
                .disabled(state.isBusy)
                Spacer()
                Text(state.environmentReport?.ok == true ? "环境通过" : "需要处理")
                    .font(.callout.weight(.semibold))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.environmentReport?.checks ?? []) { item in
                        EnvironmentRow(item: item)
                    }
                }
            }

            if !state.installLog.isEmpty {
                GlassPanel {
                    LogText(lines: state.installLog.split(whereSeparator: \.isNewline).map(String.init))
                        .frame(maxHeight: 160)
                }
            }
        }
    }
}

struct EnvironmentRow: View {
    @EnvironmentObject private var state: AppState
    let item: EnvironmentCheck

    var body: some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.status == "ok" ? "checkmark.circle.fill" : item.status == "missing" ? "exclamationmark.triangle.fill" : "circle")
                    .foregroundStyle(item.status == "ok" ? .green : item.status == "missing" ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).font(.headline)
                    Text(item.purpose).foregroundStyle(.secondary)
                    if !item.path.isEmpty { Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if !item.version.isEmpty { Text(item.version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(item.statusLabel).font(.callout.weight(.medium))
                if item.installable {
                    Button(item.installLabel) { Task { await state.install(toolId: item.id) } }
                        .glassProminentButton()
                        .disabled(state.isBusy)
                }
                if item.id == "macos_permissions" {
                    Button("打开权限") { state.openPermissions() }.glassButton()
                }
                if item.id == "codex" || item.id == "claude" {
                    Button("登录/检查") { state.openToolLogin(item.id) }.glassButton()
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "设置", subtitle: state.inlineStatus)

                GlassPanel {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("发送目标")
                            Picker("", selection: $state.config.sendTarget) {
                                ForEach(SendTarget.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                        GridRow {
                            Text("语音识别")
                            Picker("", selection: $state.config.sttProvider) {
                                ForEach(STTProvider.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                        GridRow { Text("LAN Secret"); SecureField("", text: $state.config.lanSharedSecret) }
                        GridRow { Text("Codex 目录"); PathField(text: $state.config.codexCwd) { state.chooseDirectory(for: .codexExec) } }
                        GridRow { Text("Claude 目录"); PathField(text: $state.config.claudeCwd) { state.chooseDirectory(for: .claudeCode) } }
                    }
                }

                providerSettings

                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("开机启动", isOn: $state.desktopSettings.autoLaunch)
                        Toggle("隐藏启动", isOn: $state.desktopSettings.launchToTray)
                        Toggle("关闭时保留菜单栏运行", isOn: $state.desktopSettings.closeToTray)
                        Toggle("Codex 跳过 Git 仓库检查", isOn: $state.config.codexSkipGitRepoCheck)
                        Toggle("Claude 跳过权限确认", isOn: $state.config.claudeDangerouslySkipPermissions)
                    }
                }

                HStack {
                    Button("保存并应用") { Task { await state.saveSettings() } }
                        .glassProminentButton()
                    Button("打开配置目录") { state.openConfigFolder() }
                        .glassButton()
                    Spacer()
                    Text(SettingsStore().configURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        GlassPanel {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                switch state.config.sttProvider {
                case .volcengine:
                    GridRow { Text("App Key"); TextField("", text: $state.config.volcengineAppKey) }
                    GridRow { Text("Access Key"); SecureField("", text: $state.config.volcengineAccessKey) }
                case .openai:
                    GridRow { Text("API Key"); SecureField("", text: $state.config.openaiApiKey) }
                    GridRow { Text("模型"); TextField("", text: $state.config.openaiModel) }
                case .whisperCpp:
                    GridRow { Text("模型路径"); TextField("", text: $state.config.whisperCppModelPath) }
                    GridRow { Text("命令"); TextField("", text: $state.config.whisperCppCommand) }
                    GridRow { Text("语言"); TextField("", text: $state.config.whisperCppLanguage) }
                    GridRow { Text("线程"); TextField("", text: $state.config.whisperCppThreads) }
                    GridRow { Text("额外参数"); TextField("", text: $state.config.whisperCppExtraArgs) }
                case .qwenAsr:
                    GridRow { Text("API Key"); SecureField("", text: $state.config.qwenAsrApiKey) }
                    GridRow { Text("模型"); TextField("", text: $state.config.qwenAsrModel) }
                    GridRow { Text("语言"); TextField("", text: $state.config.qwenAsrLanguage) }
                    GridRow { Text("采样率"); TextField("", text: $state.config.qwenAsrSampleRate) }
                    GridRow { Text("Realtime URL"); TextField("", text: $state.config.qwenAsrRealtimeBaseUrl) }
                    GridRow { Text("提示词"); TextField("", text: $state.config.qwenAsrPrompt) }
                }
            }
        }
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "设备", subtitle: state.inlineStatus)
            HStack {
                Button("刷新") { Task { await state.refreshRuntime() } }.glassButton()
                Button("重新发现") { Task { await state.discoverDevices() } }.glassProminentButton()
                Spacer()
            }
            List(state.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.deviceId).font(.headline)
                    Text("\(device.boardType ?? "--") · \(device.voiceMode ?? "--") · \(device.remoteAddress ?? "")")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Todo (enhanced with date picker & edit)

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var dueDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "待办", subtitle: state.inlineStatus)
            HStack {
                TextField("新增待办", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                DatePicker("截止日期", selection: Binding(
                    get: { dueDate ?? Date() },
                    set: { dueDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .opacity(dueDate == nil ? 0.6 : 1)
                Button(dueDate == nil ? "📅" : "✕") {
                    dueDate = dueDate == nil ? Date() : nil
                }
                .glassButton()
                Button("添加") { add() }.glassProminentButton()
                Button("同步提醒") { Task { await state.runReminderSync() } }.glassButton()
            }
            List {
                Section("进行中") {
                    ForEach(state.todos) { item in
                        TodoRow(item: item)
                    }
                }
                Section("归档") {
                    ForEach(state.archivedTodos) { item in
                        TodoRow(item: item, archived: true)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func add() {
        let value = title
        title = ""
        let dueISO = dueDate.map { ISO8601DateFormatter().string(from: $0) }
        dueDate = nil
        Task { await state.addTodo(value, dueAt: dueISO) }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var state: AppState
    let item: TodoItem
    var archived: Bool = false
    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        HStack {
            if !archived {
                Button {
                    Task { await state.setTodo(item, completed: !item.completed) }
                } label: {
                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                TextField("", text: $editTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveEdit() }
                Button("保存") { saveEdit() }.glassProminentButton()
                Button("取消") { isEditing = false }.glassButton()
            } else {
                Text(item.title)
                    .strikethrough(item.completed)
                if let dueAt = item.dueAt, !dueAt.isEmpty {
                    Text(formatDueDate(dueAt))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if item.appleId != nil {
                    Text("提醒").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !isEditing && !archived {
                Button("编辑") {
                    editTitle = item.title
                    isEditing = true
                }
                .glassButton()
            }
            Button("删除") { Task { await state.deleteTodo(item) } }
                .glassButton()
        }
    }

    private func saveEdit() {
        isEditing = false
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        Task { await state.editTodo(item, title: trimmed, dueAt: item.dueAt) }
    }

    private func formatDueDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Reminders Sync

struct RemindersView: View {
    @EnvironmentObject private var state: AppState
    @State private var syncEnabled = false
    @State private var remindctlPath = "remindctl"
    @State private var selectedList = ""
    @State private var pollSec = 15
    @State private var listsLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "提醒事项同步", subtitle: state.inlineStatus)

                HStack {
                    Button("立即同步") { Task { await state.runReminderSync() } }
                        .glassProminentButton()
                    Button("加载列表") { Task { await state.fetchSyncLists(); listsLoaded = true } }
                        .glassButton()
                    Button("刷新状态") { Task { await state.refreshRuntime() } }
                        .glassButton()
                    Spacer()
                }

                // Sync status
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("同步状态").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("状态")
                                Text(state.syncStatus?.enabled == true ? "已启用" : "未启用")
                                    .foregroundStyle(state.syncStatus?.enabled == true ? .green : .secondary)
                            }
                            if let count = state.syncStatus?.syncCount {
                                GridRow { Text("同步次数"); Text("\(count)") }
                            }
                            if let lastSync = state.syncStatus?.lastSyncAt, lastSync > 0 {
                                GridRow { Text("上次同步"); Text(formatTimestamp(lastSync)) }
                            }
                            if let error = state.syncStatus?.lastError, !error.isEmpty {
                                GridRow { Text("最近错误"); Text(error).foregroundStyle(.red) }
                            }
                        }
                    }
                }

                // Sync config
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("同步配置").font(.headline)
                        Toggle("启用提醒事项同步", isOn: $syncEnabled)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow { Text("remindctl 路径"); TextField("remindctl", text: $remindctlPath) }
                            GridRow { Text("轮询间隔（秒）"); TextField("15", value: $pollSec, format: .number) }
                        }
                        if listsLoaded && !state.reminderLists.isEmpty {
                            Text("提醒事项列表").font(.callout.weight(.medium))
                            ForEach(state.reminderLists) { list in
                                HStack {
                                    Button {
                                        selectedList = list.id
                                    } label: {
                                        HStack {
                                            Image(systemName: selectedList == list.id ? "checkmark.circle.fill" : "circle")
                                            Text(list.title)
                                            Text("(\(list.reminderCount))").foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                            }
                        }
                        HStack {
                            Button("保存配置") {
                                Task {
                                    await state.saveSyncConfig(
                                        enabled: syncEnabled,
                                        remindctlPath: remindctlPath,
                                        list: selectedList,
                                        pollSec: pollSec
                                    )
                                }
                            }
                            .glassProminentButton()
                            Spacer()
                        }
                    }
                }
            }
        }
        .onAppear {
            syncEnabled = state.syncStatus?.enabled ?? false
            remindctlPath = state.syncStatus?.remindctlPath ?? "remindctl"
            selectedList = state.syncStatus?.list ?? ""
            pollSec = state.syncStatus?.pollSec ?? 15
        }
    }

    private func formatTimestamp(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Display Config

struct DisplayConfigView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "墨水屏显示配置", subtitle: state.inlineStatus)

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("刷新间隔").font(.headline)

                        HStack {
                            Text("Todo 刷新间隔")
                            Slider(value: Binding(
                                get: { Double(state.displayConfig.todoRefreshMs) },
                                set: { state.displayConfig.todoRefreshMs = Int($0) }
                            ), in: 200...10000, step: 100)
                            Text("\(state.displayConfig.todoRefreshMs) ms")
                                .font(.caption.monospaced())
                                .frame(width: 70)
                        }

                        HStack {
                            Text("Coding 刷新间隔")
                            Slider(value: Binding(
                                get: { Double(state.displayConfig.codingRefreshMs) },
                                set: { state.displayConfig.codingRefreshMs = Int($0) }
                            ), in: 200...10000, step: 100)
                            Text("\(state.displayConfig.codingRefreshMs) ms")
                                .font(.caption.monospaced())
                                .frame(width: 70)
                        }
                    }
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("显示风格").font(.headline)
                        Picker("", selection: Binding(
                            get: { state.displayConfig.style },
                            set: { state.displayConfig.style = $0 }
                        )) {
                            Text("亮色").tag("light")
                            Text("暗色").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                    }
                }

                HStack {
                    Button("保存显示配置") { Task { await state.saveDisplayConfig() } }
                        .glassProminentButton()
                    Spacer()
                    Text("修改后设备会在下一次刷新周期生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            Task { await state.fetchDisplayConfig() }
        }
    }
}

// MARK: - Logs (enhanced: dual-column with filters)

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var cliFilter: LogFilter = .all
    @State private var svcFilter: ServiceLogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "日志", subtitle: state.inlineStatus)
            HStack(spacing: 16) {
                // CLI Events
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CLI 事件").font(.headline)
                        Spacer()
                        Picker("", selection: $cliFilter) {
                            ForEach(LogFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                    LogText(lines: filteredCliLines)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Service Log
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("服务日志").font(.headline)
                        Spacer()
                        Picker("", selection: $svcFilter) {
                            ForEach(ServiceLogFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                    LogText(lines: filteredServiceLines)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredCliLines: [String] {
        let lines = state.liveActivity.cliLogLines
        switch cliFilter {
        case .all: return lines
        case .transcript: return lines.filter { $0.localizedCaseInsensitiveContains("transcript") || $0.localizedCaseInsensitiveContains("语音") }
        case .user: return lines.filter { $0.localizedCaseInsensitiveContains("user") || $0.localizedCaseInsensitiveContains("用户") }
        case .assistant: return lines.filter { $0.localizedCaseInsensitiveContains("assistant") || $0.localizedCaseInsensitiveContains("AI") || $0.localizedCaseInsensitiveContains("claude") || $0.localizedCaseInsensitiveContains("codex") }
        }
    }

    private var filteredServiceLines: [String] {
        let lines = state.liveActivity.serviceLogLines
        switch svcFilter {
        case .all: return lines
        case .device: return lines.filter { $0.localizedCaseInsensitiveContains("设备") || $0.localizedCaseInsensitiveContains("device") }
        case .process: return lines.filter { $0.localizedCaseInsensitiveContains("STT") || $0.localizedCaseInsensitiveContains("服务") || $0.localizedCaseInsensitiveContains("error") }
        }
    }
}

// MARK: - Shared Components

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PathField: View {
    @Binding var text: String
    let choose: () -> Void

    var body: some View {
        HStack {
            TextField("", text: $text)
            Button("选择") { choose() }.glassButton()
        }
    }
}

struct LogText: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "暂无日志" : lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
    }
}

struct GlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
