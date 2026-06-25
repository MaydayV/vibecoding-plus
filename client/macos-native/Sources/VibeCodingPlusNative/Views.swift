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
        case .overview: "rectangle.grid.2x2"
        case .devices: "display.2"
        case .todo: "checklist"
        case .reminders: "bell.badge"
        case .display: "rectangle.on.rectangle"
        case .environment: "checkmark.shield"
        case .settings: "slider.horizontal.3"
        case .logs: "terminal"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SidebarTab? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 196, ideal: 220)
        } detail: {
            ZStack {
                InkBackground()
                ScrollView {
                    content
                        .padding(24)
                        .frame(maxWidth: 1180, alignment: .topLeading)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("刷新") { Task { await state.refreshRuntime(); await state.refreshEnvironment() } }
                        .inkToolbarButton()
                    Button(state.serviceRunning ? "运行中" : "启动") { Task { await state.startService() } }
                        .inkToolbarProminentButton()
                        .disabled(state.serviceRunning)
                    Button("重启") { Task { await state.restartService() } }
                        .inkToolbarButton()
                    Button("停止") { Task { await state.stopService() } }
                        .inkToolbarButton()
                        .disabled(!state.serviceRunning)
                }
            }
        }
        .tint(.primary)
    }

    private var sidebar: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VibeCoding")
                        .font(.title3.weight(.bold))
                    Text(state.serviceRunning ? "原生服务运行中" : "服务未启动")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)

                VStack(spacing: 6) {
                    ForEach(SidebarTab.allCases) { item in
                        Button {
                            selection = item
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol)
                                    .frame(width: 18)
                                Text(item.label)
                                Spacer()
                            }
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .foregroundStyle(selection == item ? Color(nsColor: .textBackgroundColor) : .primary)
                            .background(selection == item ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selection == item ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                InkStatusPill(
                    title: state.serviceRunning ? "ONLINE" : "OFFLINE",
                    detail: state.inlineStatus.isEmpty ? "等待操作" : state.inlineStatus,
                    active: state.serviceRunning
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
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

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                eyebrow: "LOCAL CLIENT",
                title: "运行概览",
                subtitle: state.inlineStatus
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                MetricView(title: "服务", value: state.serviceRunning ? "运行中" : "已停止", detail: "TCP \(state.config.port) / UDP \(state.config.discoveryPort)", symbol: "power")
                MetricView(title: "设备", value: "\(state.devices.count)", detail: state.serviceStatus?.discoveryEnabled == true ? "发现已启用" : "发现未启用", symbol: "display")
                MetricView(title: "模式", value: state.config.sendTarget.label, detail: state.config.transcriptDeliveryMode, symbol: "command")
                MetricView(title: "语音", value: state.config.sttProvider.label, detail: state.serviceStatus?.sttProvider ?? "未启动", symbol: "waveform")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                InkPanel(title: "实时活动", symbol: "dot.radiowaves.left.and.right") {
                    VStack(spacing: 10) {
                        LiveField(label: "语音识别", value: state.liveActivity.lastTranscript)
                        Divider()
                        LiveField(label: "用户文本", value: state.liveActivity.lastUserText)
                        Divider()
                        LiveField(label: "AI 回复", value: state.liveActivity.lastAssistantText)
                    }
                }

                InkPanel(title: "服务状态", symbol: "server.rack") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow("Host ID", state.config.discoveryHostId)
                        InfoRow("端口", "\(state.config.port)")
                        InfoRow("发现端口", "\(state.config.discoveryPort)")
                        InfoRow("CLI", state.liveActivity.cliStatus.isEmpty ? "--" : state.liveActivity.cliStatus)
                    }
                }
            }

            InkPanel(title: "近期日志", symbol: "text.alignleft") {
                LogText(lines: Array((state.liveActivity.serviceLogLines.isEmpty ? state.liveActivity.cliLogLines : state.liveActivity.serviceLogLines).suffix(14)))
                    .frame(minHeight: 180)
            }
        }
    }
}

struct LiveField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "--" : value)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Environment

struct EnvironmentView: View {
    @EnvironmentObject private var state: AppState

    private var missingChecks: [EnvironmentCheck] {
        state.environmentReport?.checks.filter { $0.status == "missing" } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                eyebrow: "SETUP",
                title: "环境检测",
                subtitle: state.environmentReport?.ok == true ? "环境通过" : "请处理缺失项"
            )

            HStack(spacing: 10) {
                Button("重新检测") { Task { await state.refreshEnvironment() } }
                    .inkButton()
                Button("安装缺失项") {
                    Task {
                        for item in missingChecks where item.installable {
                            await state.install(toolId: item.id)
                        }
                    }
                }
                .inkProminentButton()
                .disabled(state.isBusy || missingChecks.allSatisfy { !$0.installable })
                Spacer()
                StatusBadge(text: state.environmentReport?.ok == true ? "READY" : "\(missingChecks.count) MISSING", active: state.environmentReport?.ok == true)
            }

            LazyVStack(spacing: 10) {
                ForEach(state.environmentReport?.checks ?? []) { item in
                    EnvironmentRow(item: item)
                }
            }

            if !state.installLog.isEmpty {
                InkPanel(title: "安装输出", symbol: "terminal") {
                    LogText(lines: state.installLog.split(whereSeparator: \.isNewline).map(String.init))
                        .frame(maxHeight: 180)
                }
            }
        }
    }
}

struct EnvironmentRow: View {
    @EnvironmentObject private var state: AppState
    let item: EnvironmentCheck

    var body: some View {
        InkCard {
            HStack(alignment: .top, spacing: 14) {
                StatusDot(status: item.status)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.label)
                            .font(.headline)
                        Text(item.statusLabel)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(Capsule().stroke(.primary.opacity(0.35), lineWidth: 1))
                    }
                    Text(item.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !item.path.isEmpty {
                        Text(item.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !item.version.isEmpty {
                        Text(item.version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !item.note.isEmpty {
                        Text(item.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 20)
                HStack(spacing: 8) {
                    if item.installable {
                        Button(item.installLabel) { Task { await state.install(toolId: item.id) } }
                            .inkProminentButton()
                            .disabled(state.isBusy)
                    }
                    if item.id == "macos_permissions" {
                        Button("打开权限") { state.openPermissions() }.inkButton()
                    }
                    if item.id == "codex" || item.id == "claude" {
                        Button("登录/检查") { state.openToolLogin(item.id) }.inkButton()
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "CONFIG", title: "设置", subtitle: state.inlineStatus)

            InkPanel(title: "运行模式", symbol: "switch.2") {
                VStack(spacing: 12) {
                    InkFormRow("发送目标") {
                        Picker("", selection: $state.config.sendTarget) {
                            ForEach(SendTarget.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    InkFormRow("语音识别") {
                        Picker("", selection: $state.config.sttProvider) {
                            ForEach(STTProvider.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    InkFormRow("LAN Secret") {
                        SecureField("", text: $state.config.lanSharedSecret)
                            .textFieldStyle(.plain)
                    }
                    InkFormRow("Codex 目录") {
                        PathField(text: $state.config.codexCwd) { state.chooseDirectory(for: .codexExec) }
                    }
                    InkFormRow("Claude 目录") {
                        PathField(text: $state.config.claudeCwd) { state.chooseDirectory(for: .claudeCode) }
                    }
                }
            }

            providerSettings

            InkPanel(title: "应用行为", symbol: "gearshape") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("开机启动", isOn: $state.desktopSettings.autoLaunch)
                    Toggle("隐藏启动", isOn: $state.desktopSettings.launchToTray)
                    Toggle("关闭时保留菜单栏运行", isOn: $state.desktopSettings.closeToTray)
                    Toggle("Codex 跳过 Git 仓库检查", isOn: $state.config.codexSkipGitRepoCheck)
                    Toggle("Claude 跳过权限确认", isOn: $state.config.claudeDangerouslySkipPermissions)
                }
                .toggleStyle(InkCheckboxToggleStyle())
            }

            HStack(spacing: 10) {
                Button("保存并应用") { Task { await state.saveSettings() } }
                    .inkProminentButton()
                Button("打开配置目录") { state.openConfigFolder() }
                    .inkButton()
                Spacer()
                Text(SettingsStore().configURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        InkPanel(title: "\(state.config.sttProvider.label) 参数", symbol: "waveform.path.ecg") {
            VStack(spacing: 12) {
                switch state.config.sttProvider {
                case .volcengine:
                    InkFormRow("App Key") { TextField("", text: $state.config.volcengineAppKey).textFieldStyle(.plain) }
                    InkFormRow("Access Key") { SecureField("", text: $state.config.volcengineAccessKey).textFieldStyle(.plain) }
                case .openai:
                    InkFormRow("API Key") { SecureField("", text: $state.config.openaiApiKey).textFieldStyle(.plain) }
                    InkFormRow("模型") { TextField("", text: $state.config.openaiModel).textFieldStyle(.plain) }
                case .whisperCpp:
                    InkFormRow("模型路径") { TextField("", text: $state.config.whisperCppModelPath).textFieldStyle(.plain) }
                    InkFormRow("命令") { TextField("", text: $state.config.whisperCppCommand).textFieldStyle(.plain) }
                    InkFormRow("语言") { TextField("", text: $state.config.whisperCppLanguage).textFieldStyle(.plain) }
                    InkFormRow("线程") { TextField("", text: $state.config.whisperCppThreads).textFieldStyle(.plain) }
                    InkFormRow("额外参数") { TextField("", text: $state.config.whisperCppExtraArgs).textFieldStyle(.plain) }
                case .qwenAsr:
                    InkFormRow("API Key") { SecureField("", text: $state.config.qwenAsrApiKey).textFieldStyle(.plain) }
                    InkFormRow("模型") { TextField("", text: $state.config.qwenAsrModel).textFieldStyle(.plain) }
                    InkFormRow("语言") { TextField("", text: $state.config.qwenAsrLanguage).textFieldStyle(.plain) }
                    InkFormRow("采样率") { TextField("", text: $state.config.qwenAsrSampleRate).textFieldStyle(.plain) }
                    InkFormRow("Realtime URL") { TextField("", text: $state.config.qwenAsrRealtimeBaseUrl).textFieldStyle(.plain) }
                    InkFormRow("提示词") { TextField("", text: $state.config.qwenAsrPrompt).textFieldStyle(.plain) }
                }
            }
        }
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "LAN", title: "设备", subtitle: state.inlineStatus)
            HStack {
                Button("刷新") { Task { await state.refreshRuntime() } }.inkButton()
                Button("重新发现") { Task { await state.discoverDevices() } }.inkProminentButton()
                Spacer()
                StatusBadge(text: "\(state.devices.count) CONNECTED", active: !state.devices.isEmpty)
            }

            if state.devices.isEmpty {
                EmptyPanel(title: "暂无设备连接", detail: "确认客户端服务已启动，墨水屏设备在同一局域网内。")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(state.devices) { device in
                        InkCard {
                            HStack(spacing: 14) {
                                Image(systemName: "display")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(device.deviceId)
                                        .font(.headline)
                                        .textSelection(.enabled)
                                    Text("\(device.boardType ?? "--") · \(device.voiceMode ?? "--")")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.remoteAddress ?? "--")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Todo

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var dueDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "TASKS", title: "待办", subtitle: state.inlineStatus)

            InkPanel(title: "新增待办", symbol: "plus.circle") {
                HStack(spacing: 10) {
                    TextField("输入待办内容", text: $title)
                        .textFieldStyle(.plain)
                        .onSubmit { add() }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.2), lineWidth: 1))
                    DatePicker("截止日期", selection: Binding(
                        get: { dueDate ?? Date() },
                        set: { dueDate = $0 }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .opacity(dueDate == nil ? 0.55 : 1)
                    Button(dueDate == nil ? "设置日期" : "清除日期") {
                        dueDate = dueDate == nil ? Date() : nil
                    }
                    .inkButton()
                    Button("添加") { add() }.inkProminentButton()
                    Button("同步提醒") { Task { await state.runReminderSync() } }.inkButton()
                }
            }

            HStack(alignment: .top, spacing: 14) {
                TodoSection(title: "进行中", items: state.todos, archived: false)
                TodoSection(title: "归档", items: state.archivedTodos, archived: true)
                    .frame(maxWidth: 360)
            }
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

struct TodoSection: View {
    let title: String
    let items: [TodoItem]
    let archived: Bool

    var body: some View {
        InkPanel(title: title, symbol: archived ? "archivebox" : "checklist") {
            if items.isEmpty {
                Text(archived ? "暂无归档" : "暂无待办")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        TodoRow(item: item, archived: archived)
                    }
                }
            }
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var state: AppState
    let item: TodoItem
    var archived: Bool = false
    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        InkCard {
            HStack(alignment: .center, spacing: 10) {
                if !archived {
                    Button {
                        Task { await state.setTodo(item, completed: !item.completed) }
                    } label: {
                        Image(systemName: item.completed ? "checkmark.square.fill" : "square")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    TextField("", text: $editTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.2), lineWidth: 1))
                        .onSubmit { saveEdit() }
                    Button("保存") { saveEdit() }.inkProminentButton()
                    Button("取消") { isEditing = false }.inkButton()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? .secondary : .primary)
                        HStack(spacing: 8) {
                            if let dueAt = item.dueAt, !dueAt.isEmpty {
                                Label(formatDueDate(dueAt), systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if item.appleId != nil {
                                Label("提醒", systemImage: "bell")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                if !isEditing && !archived {
                    Button("编辑") {
                        editTitle = item.title
                        isEditing = true
                    }
                    .inkButton()
                }
                Button("删除") { Task { await state.deleteTodo(item) } }
                    .inkButton()
            }
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
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "APPLE REMINDERS", title: "提醒事项同步", subtitle: state.inlineStatus)

            HStack(spacing: 10) {
                Button("立即同步") { Task { await state.runReminderSync() } }
                    .inkProminentButton()
                Button("加载列表") { Task { await state.fetchSyncLists(); listsLoaded = true } }
                    .inkButton()
                Button("刷新状态") { Task { await state.refreshRuntime() } }
                    .inkButton()
                Spacer()
                StatusBadge(text: state.syncStatus?.enabled == true ? "SYNC ON" : "SYNC OFF", active: state.syncStatus?.enabled == true)
            }

            HStack(alignment: .top, spacing: 14) {
                InkPanel(title: "同步状态", symbol: "arrow.triangle.2.circlepath") {
                    VStack(spacing: 10) {
                        InfoRow("状态", state.syncStatus?.enabled == true ? "已启用" : "未启用")
                        if let count = state.syncStatus?.syncCount {
                            InfoRow("同步次数", "\(count)")
                        }
                        if let lastSync = state.syncStatus?.lastSyncAt, lastSync > 0 {
                            InfoRow("上次同步", formatTimestamp(lastSync))
                        }
                        if let error = state.syncStatus?.lastError, !error.isEmpty {
                            InfoRow("最近错误", error)
                        }
                    }
                }
                .frame(width: 330)

                InkPanel(title: "同步配置", symbol: "list.bullet.rectangle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用提醒事项同步", isOn: $syncEnabled)
                            .toggleStyle(InkCheckboxToggleStyle())
                        InkFormRow("remindctl 路径") {
                            TextField("remindctl", text: $remindctlPath).textFieldStyle(.plain)
                        }
                        InkFormRow("轮询间隔") {
                            TextField("15", value: $pollSec, format: .number).textFieldStyle(.plain)
                        }
                        if listsLoaded && !state.reminderLists.isEmpty {
                            Divider()
                            Text("提醒事项列表")
                                .font(.callout.weight(.semibold))
                            ForEach(state.reminderLists) { list in
                                Button {
                                    selectedList = list.id
                                } label: {
                                    HStack {
                                        Image(systemName: selectedList == list.id ? "checkmark.circle.fill" : "circle")
                                        Text(list.title)
                                        Text("(\(list.reminderCount))").foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
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
                        .inkProminentButton()
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
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "E-PAPER", title: "墨水屏显示", subtitle: state.inlineStatus)

            InkPanel(title: "刷新节奏", symbol: "timer") {
                VStack(spacing: 16) {
                    SliderRow(title: "Todo 刷新间隔", value: Binding(
                        get: { Double(state.displayConfig.todoRefreshMs) },
                        set: { state.displayConfig.todoRefreshMs = Int($0) }
                    ), range: 200...10000, suffix: "ms")

                    SliderRow(title: "Coding 刷新间隔", value: Binding(
                        get: { Double(state.displayConfig.codingRefreshMs) },
                        set: { state.displayConfig.codingRefreshMs = Int($0) }
                    ), range: 200...10000, suffix: "ms")
                }
            }

            InkPanel(title: "显示风格", symbol: "circle.lefthalf.filled") {
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

            HStack {
                Button("保存显示配置") { Task { await state.saveDisplayConfig() } }
                    .inkProminentButton()
                Spacer()
                Text("修改后在设备下一次刷新周期生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            Task { await state.fetchDisplayConfig() }
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var cliFilter: LogFilter = .all
    @State private var svcFilter: ServiceLogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: "TRACE", title: "日志", subtitle: state.inlineStatus)
            HStack(alignment: .top, spacing: 14) {
                InkPanel(title: "CLI 事件", symbol: "terminal") {
                    VStack(spacing: 10) {
                        Picker("", selection: $cliFilter) {
                            ForEach(LogFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        LogText(lines: filteredCliLines)
                            .frame(minHeight: 430)
                    }
                }

                InkPanel(title: "服务日志", symbol: "server.rack") {
                    VStack(spacing: 10) {
                        Picker("", selection: $svcFilter) {
                            ForEach(ServiceLogFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        LogText(lines: filteredServiceLines)
                            .frame(minHeight: 430)
                    }
                }
            }
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
    var eyebrow: String = ""
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
            }
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        InkCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                    Spacer()
                    Text(title.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail.isEmpty ? "--" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 92)
        }
    }
}

struct InkPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

struct InkCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.primary.opacity(0.18), lineWidth: 1)
            )
    }
}

struct EmptyPanel: View {
    let title: String
    let detail: String

    var body: some View {
        InkCard {
            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }
}

struct InkStatusPill: View {
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(active ? Color.primary : Color.clear)
                    .overlay(Circle().stroke(.primary, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.monospaced().weight(.bold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.16), lineWidth: 1))
    }
}

struct StatusBadge: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color(nsColor: .textBackgroundColor) : .primary)
            .background(active ? Color.primary : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.5), lineWidth: 1))
    }
}

struct StatusDot: View {
    let status: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary, lineWidth: 1.4)
                .frame(width: 18, height: 18)
            if status == "ok" {
                Circle()
                    .fill(.primary)
                    .frame(width: 9, height: 9)
            } else if status == "missing" {
                Rectangle()
                    .fill(.primary)
                    .frame(width: 9, height: 2)
            }
        }
    }
}

struct InkFormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            content
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.18), lineWidth: 1))
        }
    }
}

struct PathField: View {
    @Binding var text: String
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
            Button("选择") { choose() }.inkButton()
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 140, alignment: .leading)
            Slider(value: $value, in: range, step: 100)
            Text("\(Int(value)) \(suffix)")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "--" : value)
                .font(.callout.monospaced())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct LogText: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "暂无日志" : lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12), lineWidth: 1))
    }
}

struct InkBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.035),
                    Color.clear,
                    Color.primary.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                let step: CGFloat = 18
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(path, with: .color(.primary.opacity(0.025)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func inkButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: false))
    }

    func inkProminentButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: true))
    }

    func inkToolbarButton() -> some View {
        self.inkButton()
    }

    func inkToolbarProminentButton() -> some View {
        self.inkProminentButton()
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.primary.opacity(prominent ? 0 : 0.28), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        if prominent {
            return Color(nsColor: .textBackgroundColor)
        }
        return .primary
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        if prominent {
            return Color.primary.opacity(configuration.isPressed ? 0.78 : 0.92)
        }
        return Color.primary.opacity(configuration.isPressed ? 0.10 : 0.035)
    }
}

struct InkCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? Color.primary : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.primary.opacity(0.55), lineWidth: 1.2)
                        .frame(width: 18, height: 18)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    }
                }
                configuration.label
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
