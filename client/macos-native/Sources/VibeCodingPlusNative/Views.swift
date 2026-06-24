import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case overview
    case environment
    case settings
    case devices
    case todo
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "概览"
        case .environment: "环境"
        case .settings: "设置"
        case .devices: "设备"
        case .todo: "待办"
        case .logs: "日志"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "speedometer"
        case .environment: "checklist.checked"
        case .settings: "gearshape"
        case .devices: "display.2"
        case .todo: "checklist"
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
                        .disabled(state.bridge.snapshot.status == .running || state.bridge.snapshot.status == .starting)
                    Button("重启") { Task { await state.restartService() } }
                        .glassButton()
                    Button("停止") { Task { await state.stopService() } }
                        .glassButton()
                        .disabled(state.bridge.snapshot.status == .stopped)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView()
        case .environment:
            EnvironmentView()
        case .settings:
            SettingsView()
        case .devices:
            DevicesView()
        case .todo:
            TodoView()
        case .logs:
            LogsView()
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "概览", subtitle: state.inlineStatus)
            HStack(spacing: 12) {
                MetricView(title: "服务", value: state.bridge.snapshot.status.label, detail: state.bridge.snapshot.message)
                MetricView(title: "模式", value: state.config.sendTarget.label, detail: "端口 \(state.config.port)")
                MetricView(title: "设备", value: "\(state.devices.count)", detail: state.serviceStatus?.discoveryEnabled == true ? "发现服务已启用" : "发现服务未启用")
                MetricView(title: "STT", value: state.config.sttProvider.label, detail: state.serviceStatus?.nodeVersion ?? "--")
            }
            .frame(maxWidth: .infinity)

            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("近期日志").font(.headline)
                    LogText(lines: Array(state.bridge.snapshot.logs.suffix(12)))
                }
            }

            Spacer()
        }
    }
}

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

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "待办", subtitle: state.inlineStatus)
            HStack {
                TextField("新增待办", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
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
                        TodoRow(item: item)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func add() {
        let value = title
        title = ""
        Task { await state.addTodo(value) }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var state: AppState
    let item: TodoItem

    var body: some View {
        HStack {
            Button {
                Task { await state.setTodo(item, completed: !item.completed) }
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            Text(item.title)
                .strikethrough(item.completed)
            if item.appleId != nil {
                Text("提醒").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("删除") { Task { await state.deleteTodo(item) } }
                .glassButton()
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "日志", subtitle: state.bridge.snapshot.message)
            LogText(lines: state.bridge.snapshot.logs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

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
