import SwiftUI
import EventKit
#if canImport(AVFoundation)
import AVFoundation
import AVFAudio
#endif

// MARK: - Navigation

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
        case .overview: "square.grid.2x2"
        case .devices: "display.2"
        case .todo: "checklist"
        case .reminders: "bell.badge"
        case .display: "rectangle.on.rectangle"
        case .environment: "checkmark.shield"
        case .settings: "slider.horizontal.3"
        case .logs: "terminal"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .overview, .devices, .todo, .reminders: .main
        case .display, .environment: .tools
        case .settings, .logs: .system
        }
    }
}

enum SidebarGroup: String, CaseIterable {
    case main
    case tools
    case system

    var label: String {
        switch self {
        case .main: "功能"
        case .tools: "工具"
        case .system: "系统"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SidebarTab? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: 232)
        } detail: {
            ZStack {
                InkBackground()
                ScrollView {
                    content
                        .padding(.horizontal, 28)
                        .padding(.top, 22)
                        .padding(.bottom, 36)
                        .frame(maxWidth: 1200, alignment: .topLeading)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    serviceControl
                }
            }
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
        }
        .tint(InkTheme.accent)
    }

    private var serviceControl: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.serviceRunning ? InkTheme.ink : InkTheme.warning)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.primary.opacity(0.15), lineWidth: 1))
                Text(state.serviceRunning ? "服务运行中" : "服务未启动")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)

            if state.serviceRunning {
                Button {
                    Task { await state.restartService() }
                } label: {
                    Label("重启", systemImage: "arrow.clockwise")
                }
                .inkToolbarButton()
                Button {
                    Task { await state.stopService() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .inkToolbarButton()
            } else {
                Button {
                    Task { await state.startService() }
                } label: {
                    Label("启动服务", systemImage: "play.fill")
                }
                .inkToolbarProminentButton()
            }

            Button {
                Task { await state.refreshRuntime(); await state.refreshEnvironment() }
            } label: {
                Label("刷新", systemImage: "arrow.triangle.2.circlepath")
            }
            .inkToolbarButton()
        }
    }

    private var sidebar: some View {
        ZStack {
            // 墨水屏纸色背景，与右侧主区一致
            InkTheme.paper
            InkDitherBackground(opacity: 0.3, step: 7)
            // 右侧分隔线，模拟墨水屏边框
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(InkTheme.ink.opacity(0.12))
                    .frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                brand
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(SidebarGroup.allCases, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(InkTheme.ink.opacity(0.5))
                                    .tracking(1)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 2)
                                ForEach(SidebarTab.allCases.filter { $0.group == group }) { item in
                                    sidebarButton(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }

                InkStatusPill(
                    title: state.serviceRunning ? "ONLINE" : "OFFLINE",
                    detail: state.inlineStatus.isEmpty ? "等待操作" : state.inlineStatus,
                    active: state.serviceRunning
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(InkTheme.ink)
                    .frame(width: 34, height: 34)
                InkDitherBackground(opacity: 0.18, step: 5)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeCoding")
                    .font(.headline)
                Text("原生客户端")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sidebarButton(_ item: SidebarTab) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.white : InkTheme.ink.opacity(0.85))
                Text(item.label)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                Spacer()
                if isSelected {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(isSelected ? Color.white : InkTheme.ink)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(InkTheme.ink)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.clear)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect()
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
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "LOCAL CLIENT",
                title: "运行概览",
                subtitle: state.inlineStatus,
                trailing: {
                    HStack(spacing: 8) {
                        StatusBadge(text: state.serviceRunning ? "ONLINE" : "OFFLINE", active: state.serviceRunning)
                        StatusBadge(text: "\(state.devices.count) 设备", active: !state.devices.isEmpty)
                    }
                }
            )

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ], spacing: 14) {
                MetricView(title: "服务", value: state.serviceRunning ? "运行中" : "已停止",
                           detail: "TCP \(state.config.port) · UDP \(state.config.discoveryPort)", symbol: "power",
                           tone: state.serviceRunning ? .success : .idle)
                MetricView(title: "设备", value: "\(state.devices.count)",
                           detail: state.serviceStatus?.discoveryEnabled == true ? "发现已启用" : "发现未启用", symbol: "display",
                           tone: !state.devices.isEmpty ? .accent : .idle)
                MetricView(title: "发送目标", value: state.config.sendTarget.label,
                           detail: deliveryLabel, symbol: "paperplane",
                           tone: .accent)
                MetricView(title: "语音识别", value: state.config.sttProvider.label,
                           detail: state.serviceStatus?.sttProvider ?? "未启动", symbol: "waveform",
                           tone: .accent)
            }

            // 实时活动 + 服务状态 固定比例分栏，顶部对齐；填满剩余高度避免留白
            HStack(alignment: .top, spacing: 16) {
                InkPanel(title: "实时活动", symbol: "dot.radiowaves.left.and.right", accent: true) {
                    VStack(spacing: 0) {
                        LiveField(label: "语音识别", value: state.liveActivity.lastTranscript, icon: "waveform")
                        InkDivider()
                        LiveField(label: "用户文本", value: state.liveActivity.lastUserText, icon: "person")
                        InkDivider()
                        LiveField(label: "AI 回复", value: state.liveActivity.lastAssistantText, icon: "sparkles")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                InkPanel(title: "服务状态", symbol: "server.rack") {
                    VStack(alignment: .leading, spacing: 11) {
                        InfoRow("Host ID", state.config.discoveryHostId)
                        InfoRow("端口", "\(state.config.port)")
                        InfoRow("发现端口", "\(state.config.discoveryPort)")
                        InfoRow("CLI", state.liveActivity.cliStatus.isEmpty ? "--" : state.liveActivity.cliStatus)
                        InfoRow("运行模式", state.config.sendTarget.label)
                        InfoRow("STT", state.config.sttProvider.label)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 近期日志 / 编程过程日志已移除：请到「日志」页面查看完整日志
        }
    }

    private var deliveryLabel: String {
        switch state.config.transcriptDeliveryMode {
        case "immediate": "立即输入"
        case "confirm_on_device": "设备确认"
        default: state.config.transcriptDeliveryMode
        }
    }
}

struct LiveField: View {
    let label: String
    let value: String
    var icon: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "暂无" : value)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11)
    }
}

// MARK: - Environment

struct EnvironmentView: View {
    @EnvironmentObject private var state: AppState

    private var missingChecks: [EnvironmentCheck] {
        state.environmentReport?.checks.filter { $0.status == "missing" } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "SETUP",
                title: "环境检测",
                subtitle: state.environmentReport?.ok == true ? "环境通过，可以正常使用" : "请处理缺失项",
                trailing: {
                    StatusBadge(text: state.environmentReport?.ok == true ? "READY" : "\(missingChecks.count) MISSING",
                                active: state.environmentReport?.ok == true)
                }
            )

            PageActionBar {
                Button {
                    Task { await state.refreshEnvironment() }
                } label: {
                    Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                }
                .inkButton()

                Button {
                    Task {
                        for item in missingChecks where item.installable {
                            await state.install(toolId: item.id)
                        }
                    }
                } label: {
                    Label("安装缺失项", systemImage: "arrow.down.circle")
                }
                .inkProminentButton()
                .disabled(state.isBusy || missingChecks.allSatisfy { !$0.installable })
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
        .onAppear {
            Task { await state.refreshEnvironment() }
        }
    }
}

struct EnvironmentRow: View {
    @EnvironmentObject private var state: AppState
    let item: EnvironmentCheck

    var body: some View {
        InkCard(hoverable: false) {
            HStack(alignment: .top, spacing: 14) {
                StatusDot(status: item.status)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.label)
                            .font(.headline)
                        Text(item.statusLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(statusForeground)
                            .background(statusBackground, in: Capsule())
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

    private var statusForeground: Color {
        switch item.status {
        case "ok": .white
        case "missing": .white
        default: .primary
        }
    }

    private var statusBackground: Color {
        switch item.status {
        case "ok": InkTheme.ink
        case "missing": InkTheme.warning
        default: .primary.opacity(0.08)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "CONFIG", title: "设置", subtitle: state.inlineStatus)

            InkPanel(title: "macOS 权限状态", symbol: "checkmark.shield", accent: true) {
                HStack(spacing: 20) {
                    permIndicator("辅助功能", granted: AXIsProcessTrusted(), needed: state.config.sendTarget == .textInjector)
                    permIndicator("麦克风", granted: micPermissionGranted(), needed: true)
                    permIndicator("提醒事项", granted: reminderPermissionGranted(), needed: state.config.remindersSyncEnabled)
                    Spacer()
                    Button { state.openPermissions() } label: {
                        Label("打开权限", systemImage: "lock.open")
                    }
                    .inkButton()
                    Button { Task { await state.refreshEnvironment() } } label: {
                        Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .inkButton()
                }
            }

            InkPanel(title: "运行模式", symbol: "switch.2", accessory: AnyView(sectionHint("语音识别结果如何发送到电脑"))) {
                VStack(spacing: 14) {
                    PickerRow(label: "发送目标", hint: "输入注入=打到光标处，Codex/Claude Code=发给对应 CLI") {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.config.sendTarget },
                                set: { newValue in
                                    state.config.sendTarget = newValue
                                    state.propagateRuntimeInput()
                                }
                            ),
                            options: SendTarget.allCases,
                            label: { $0.label }
                        )
                    }

                    PickerRow(label: "输入时机", hint: "设备确认=在墨水屏上点确认才输入；立即输入=说完立刻注入") {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.config.transcriptDeliveryMode },
                                set: { newValue in
                                    state.config.transcriptDeliveryMode = newValue
                                    state.propagateRuntimeInput()
                                }
                            ),
                            options: ["confirm_on_device", "immediate"],
                            label: { $0 == "immediate" ? "立即输入" : "设备确认" }
                        )
                    }

                    PickerRow(label: "输入动作", hint: "是否在注入文字后自动按回车") {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.config.textInjectionMode },
                                set: { newValue in
                                    state.config.textInjectionMode = newValue
                                    state.propagateRuntimeInput()
                                }
                            ),
                            options: ["type_and_enter", "type_only"],
                            label: { $0 == "type_only" ? "只输入" : "输入后回车" }
                        )
                    }

                    PickerRow(label: "语音识别", hint: "选择语音转文字的 provider，下方会显示对应参数") {
                        InkSegmentedPicker(
                            selection: $state.config.sttProvider,
                            options: STTProvider.allCases,
                            label: { $0.label }
                        )
                    }

                    InkFormRow("LAN Secret") {
                        SecureField("留空=不鉴权", text: $state.config.lanSharedSecret)
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

            usageGuidePanel

            providerSettings

            InkPanel(title: "应用行为", symbol: "gearshape") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("开机启动", isOn: $state.desktopSettings.autoLaunch)
                    Toggle("隐藏启动", isOn: $state.desktopSettings.launchToTray)
                    Toggle("关闭时保留菜单栏运行", isOn: $state.desktopSettings.closeToTray)
                    Toggle("Codex 跳过 Git 仓库检查", isOn: $state.config.codexSkipGitRepoCheck)
                    Toggle("Claude 跳过权限确认", isOn: $state.config.claudeDangerouslySkipPermissions)
                }
                .toggleStyle(InkCheckboxToggleStyle())
            }

            PageActionBar {
                Button { Task { await state.saveSettings() } } label: {
                    Label("保存并应用", systemImage: "checkmark.circle.fill")
                }
                .inkProminentButton()
                Button { state.openConfigFolder() } label: {
                    Label("打开配置目录", systemImage: "folder")
                }
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
        .onAppear {
            Task { await state.refreshEnvironment() }
        }
    }

    private func permIndicator(_ name: String, granted: Bool, needed: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : (needed ? "exclamationmark.triangle.fill" : "circle"))
                .foregroundStyle(granted ? InkTheme.ink : (needed ? InkTheme.warning : .secondary))
            Text(name)
                .font(.callout.weight(.medium))
            if !granted && needed {
                Text("未授权")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(InkTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(InkTheme.warning.opacity(0.15), in: Capsule())
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
                    VStack(alignment: .leading, spacing: 6) {
                        InkFormRow("API 地址") {
                            TextField("https://api.openai.com/v1", text: $state.config.openaiBaseUrl)
                                .textFieldStyle(.plain)
                        }
                        sectionHint("兼容 OpenAI 的第三方接口地址，留空则使用官方 https://api.openai.com/v1")
                            .padding(.leading, 146)
                    }
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

    @ViewBuilder
    private var usageGuidePanel: some View {
        InkPanel(title: "使用说明", symbol: "book.pages",
                 accessory: AnyView(sectionHint("文本输入模式按键说明"))) {
            VStack(alignment: .leading, spacing: 10) {
                UsageKeyRow(symbol: "rectangle.roundedtop.fill", action: "长按 BOOT",
                            detail: "开始录音，松开后自动识别并输入到光标处")
                UsageKeyRow(symbol: "arrow.forward.square", action: "继续长按 BOOT",
                            detail: "在已输入内容后追加新识别的文字")
                UsageKeyRow(symbol: "corner.downleft", action: "短按 BOOT",
                            detail: "发送回车（提交当前输入框）")
                UsageKeyRow(symbol: "xmark.square", action: "连按两次 BOOT",
                            detail: "清空输入框中已输入的内容")
                UsageKeyRow(symbol: "arrow.up.arrow.down", action: "上 / 下 键",
                            detail: "翻页 / 切换模式（不参与发送）")

                Divider().opacity(0.4).padding(.top, 2)

                Text("仅当发送目标为「文本注入」时适用；识别完成后自动输入，无需在设备上确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UsageKeyRow: View {
    let symbol: String
    let action: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InkTheme.accent)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(action)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Devices

func micPermissionGranted() -> Bool {
    #if canImport(AVFoundation)
    if #available(macOS 14.0, *) {
        return AVAudioApplication.shared.recordPermission == .granted
    } else {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    #else
    return false
    #endif
}

func reminderPermissionGranted() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    return status == .authorized || status == .fullAccess || status == .writeOnly
}

struct DevicesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "LAN",
                title: "设备",
                subtitle: state.inlineStatus,
                trailing: {
                    StatusBadge(text: "\(state.devices.count) 已连接", active: !state.devices.isEmpty)
                }
            )

            PageActionBar {
                Button { Task { await state.refreshRuntime() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .inkButton()
                Button { Task { await state.discoverDevices() } } label: {
                    Label("重新发现", systemImage: "antenna.radiowaves.left.and.right")
                }
                .inkProminentButton()
            }

            if state.devices.isEmpty {
                EmptyPanel(symbol: "display", title: "暂无设备连接", detail: "确认客户端服务已启动，墨水屏设备在同一局域网内。")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(state.devices) { device in
                        DeviceCard(device: device)
                    }
                }
            }
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var state: AppState
    let device: DeviceInfo
    @State private var idCopied = false

    private var currentMode: String { device.voiceMode ?? "normal" }
    private var boardType: String { device.boardType ?? "未知板型" }

    var body: some View {
        InkCard(hoverable: false) {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                metaGrid
                modeSwitcher
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(InkTheme.ink)
                    .frame(width: 50, height: 50)
                InkDitherBackground(opacity: 0.15, step: 6)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Image(systemName: "display")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(boardType)
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(InkTheme.ink)
                            .frame(width: 6, height: 6)
                        Text("在线")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(InkTheme.ink)
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.deviceId, forType: .string)
                    idCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        idCopied = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(device.deviceId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let addr = device.remoteAddress {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("远程地址")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Text(addr)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var metaGrid: some View {
        HStack(spacing: 0) {
            metaItem("板型", device.boardType ?? "--", icon: "cpu")
            metaDivider
            metaItem("当前模式", currentModeLabel, icon: "rectangle.on.rectangle")
            metaDivider
            metaItem("连接时长", connectedDuration, icon: "clock")
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var metaDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }

    private func metaItem(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.tertiary)
            .tracking(0.3)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 10) {
            Text("切换模式")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            modeButton(title: "编程", icon: "chevron.left.forwardslash.chevron.right", mode: "normal")
            modeButton(title: "备忘", icon: "checklist", mode: "todo")
            Spacer()
        }
    }

    private func modeButton(title: String, icon: String, mode: String) -> some View {
        let isActive = currentMode == mode
        return Button {
            Task { await state.setDeviceVoiceMode(device, mode: mode) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout.weight(isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.white : .primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(InkTheme.accent)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? Color.clear : .primary.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .opacity(isActive ? 1 : 0.85)
    }

    private var currentModeLabel: String {
        switch currentMode {
        case "todo": "备忘"
        case "normal": "编程"
        default: "--"
        }
    }

    private var connectedDuration: String {
        guard let connectedAt = device.connectedAt, connectedAt > 0 else { return "--" }
        let seconds = Int(Date().timeIntervalSince1970 * 1000 - connectedAt) / 1000
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        return "\(hours)时\(minutes % 60)分"
    }
}

// MARK: - Todo

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var dueDate: Date?
    @State private var isEditingDate = false
    @State private var reminderListSelection: String = ""
    @State private var useReminderList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "TASKS",
                title: "待办",
                subtitle: state.inlineStatus,
                trailing: {
                    HStack(spacing: 8) {
                        if state.syncStatus?.enabled == true {
                            StatusBadge(text: "同步开启", active: true)
                        }
                        Text("\(state.todos.count) 进行中")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            )

            InkPanel(title: "新增待办", symbol: "plus.circle", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("输入待办内容，回车快速添加", text: $title)
                            .textFieldStyle(.plain)
                            .onSubmit { add() }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))

                        dueDateChip

                        Button { add() } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .inkProminentButton()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if state.syncStatus?.enabled == true || !state.reminderLists.isEmpty {
                        HStack(spacing: 12) {
                            Toggle("同步到提醒分组", isOn: $useReminderList)
                                .toggleStyle(InkCheckboxToggleStyle())
                            if useReminderList {
                                Picker("提醒分组", selection: $reminderListSelection) {
                                    Text("使用默认列表").tag("")
                                    ForEach(state.reminderLists) { list in
                                        Text("\(list.title) (\(list.reminderCount))").tag(list.title)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 300)
                                Button { Task { await state.runReminderSync() } } label: {
                                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .inkButton()
                            }
                            Spacer()
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                TodoSection(title: "进行中", items: state.todos, archived: false)
                TodoSection(title: "归档", items: state.archivedTodos, archived: true)
                    .frame(maxWidth: 380)
            }
        }
        .onAppear {
            Task { await state.fetchSyncLists() }
        }
    }

    private func add() {
        let value = title
        title = ""
        let dueISO = dueDate.map { ISO8601DateFormatter().string(from: $0) }
        dueDate = nil
        isEditingDate = false
        let listForSync = useReminderList ? (reminderListSelection.isEmpty ? nil : reminderListSelection) : nil
        Task { await state.addTodo(value, dueAt: dueISO, reminderList: listForSync) }
    }

    @ViewBuilder
    private var dueDateChip: some View {
        if isEditingDate {
            HStack(spacing: 6) {
                DatePicker("截止日期", selection: Binding(
                    get: { dueDate ?? Date() },
                    set: { dueDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .frame(width: 132)
                Button {
                    dueDate = nil
                    isEditingDate = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .inkIconButton()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.3), lineWidth: 1))
        } else if let date = dueDate {
            Button {
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(formatDate(date))
                        .font(.callout.weight(.medium))
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(InkTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                dueDate = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .inkIconButton()
        } else {
            Button {
                dueDate = Date()
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.caption)
                    Text("添加日期")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

struct TodoSection: View {
    let title: String
    let items: [TodoItem]
    let archived: Bool

    var body: some View {
        InkPanel(title: title, symbol: archived ? "archivebox" : "checklist", accessory: AnyView(
            Text("\(items.count)")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        )) {
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
    @State private var isHovering = false

    var body: some View {
        InkCard(hoverable: true) {
            HStack(alignment: .center, spacing: 12) {
                if !archived {
                    Button {
                        Task { await state.setTodo(item, completed: !item.completed) }
                    } label: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(item.completed ? InkTheme.ink : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    TextField("", text: $editTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(InkTheme.ink.opacity(0.5), lineWidth: 1))
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
                                Label("提醒", systemImage: "bell.fill")
                                    .font(.caption)
                                    .foregroundStyle(InkTheme.ink)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                if !isEditing {
                    HStack(spacing: 6) {
                        if !archived {
                            Button {
                                editTitle = item.title
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                            }
                            .inkIconButton()
                            .opacity(isHovering ? 1 : 0.5)
                        }
                        Button {
                            Task { await state.deleteTodo(item) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption.weight(.semibold))
                        }
                        .inkIconButton(danger: true)
                        .opacity(isHovering ? 1 : 0.5)
                    }
                }
            }
        }
        .onHover { isHovering = $0 }
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
    @State private var selectedList = ""
    @State private var pollSec = 15
    @State private var listsLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "APPLE REMINDERS",
                title: "提醒事项同步",
                subtitle: state.inlineStatus,
                trailing: {
                    StatusBadge(text: state.syncStatus?.enabled == true ? "SYNC ON" : "SYNC OFF",
                                active: state.syncStatus?.enabled == true)
                }
            )

            PageActionBar {
                Button { Task { await state.runReminderSync() } } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .inkProminentButton()
                Button { Task { await state.fetchSyncLists(); listsLoaded = true } } label: {
                    Label("重新加载列表", systemImage: "arrow.clockwise")
                }
                .inkButton()
                Button { Task { await state.refreshRuntime() } } label: {
                    Label("刷新状态", systemImage: "info.circle")
                }
                .inkButton()
            }

            HStack(alignment: .top, spacing: 16) {
                InkPanel(title: "同步状态", symbol: "arrow.triangle.2.circlepath") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(spacing: 12) {
                            stateRow("状态", state.syncStatus?.enabled == true ? "已启用" : "未启用",
                                     tone: state.syncStatus?.enabled == true ? .success : .idle)
                            if let count = state.syncStatus?.syncCount {
                                InfoRow("同步次数", "\(count)")
                            }
                            if let lastSync = state.syncStatus?.lastSyncAt, lastSync > 0 {
                                InfoRow("上次同步", formatTimestamp(lastSync))
                            } else {
                                InfoRow("上次同步", "尚未同步")
                            }
                            if let error = state.syncStatus?.lastError, !error.isEmpty {
                                InfoRow("最近错误", error)
                            } else if state.syncStatus?.enabled == true {
                                InfoRow("最近错误", "无")
                            }
                        }

                        InkDivider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("待办统计")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(InkTheme.ink.opacity(0.5))
                                .tracking(0.3)
                            InfoRow("进行中", "\(state.todos.count)")
                            InfoRow("已归档", "\(state.archivedTodos.count)")
                            InfoRow("已同步提醒", "\(state.todos.filter { $0.appleId != nil }.count)")
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("说明")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(InkTheme.ink.opacity(0.5))
                                .tracking(0.3)
                            Text("启用后，待办会双向同步到选定的提醒事项列表；轮询间隔控制自动同步频率。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity)

                InkPanel(title: "同步配置", symbol: "list.bullet.rectangle", accent: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用提醒事项同步", isOn: $syncEnabled)
                            .toggleStyle(InkCheckboxToggleStyle())
                        InkFormRow("轮询间隔(秒)") {
                            TextField("15", value: $pollSec, format: .number).textFieldStyle(.plain)
                        }
                        InkDivider()
                        Text("提醒事项列表（点击选择同步目标）")
                            .font(.callout.weight(.semibold))
                        if state.reminderLists.isEmpty {
                            Text(listsLoaded ? "未找到提醒事项列表，请先在系统中创建提醒" : "正在加载提醒事项列表…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(state.reminderLists) { list in
                                    Button {
                                        selectedList = list.title
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: selectedList == list.title ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedList == list.title ? InkTheme.ink : .secondary)
                                            Text(list.title)
                                                .font(.callout.weight(.medium))
                                            Spacer()
                                            Text("\(list.reminderCount)")
                                                .font(.caption.monospaced().weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(selectedList == list.title ? InkTheme.ink.opacity(0.08) : Color.clear)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .hoverEffect()
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task {
                                await state.saveSyncConfig(
                                    enabled: syncEnabled,
                                    list: selectedList,
                                    pollSec: pollSec
                                )
                            }
                        } label: {
                            Label("保存配置并应用", systemImage: "checkmark.circle.fill")
                        }
                        .inkProminentButton()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            syncEnabled = state.syncStatus?.enabled ?? false
            selectedList = state.syncStatus?.list ?? ""
            pollSec = state.syncStatus?.pollSec ?? 15
            Task { await state.fetchSyncLists(); listsLoaded = true }
        }
    }

    private func stateRow(_ label: String, _ value: String, tone: MetricTone) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tone == .success ? InkTheme.ink : .primary)
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
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "E-PAPER", title: "墨水屏显示", subtitle: state.inlineStatus)

            HStack(alignment: .top, spacing: 16) {
                InkPanel(title: "刷新节奏", symbol: "timer", accent: true) {
                    VStack(spacing: 18) {
                        SliderRow(title: "Todo 刷新间隔", value: Binding(
                            get: { Double(state.displayConfig.todoRefreshMs) },
                            set: { state.displayConfig.todoRefreshMs = Int($0) }
                        ), range: 200...10000, suffix: "ms", hint: "备忘页自动刷新间隔")
                        InkDivider()
                        SliderRow(title: "Coding 刷新间隔", value: Binding(
                            get: { Double(state.displayConfig.codingRefreshMs) },
                            set: { state.displayConfig.codingRefreshMs = Int($0) }
                        ), range: 200...10000, suffix: "ms", hint: "编程页自动刷新间隔")
                        Spacer(minLength: 0)
                        InkDivider()
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("间隔越小屏幕更新越及时，但耗电略增；2 秒左右较平衡")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                InkPanel(title: "显示风格", symbol: "circle.lefthalf.filled", accent: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.displayConfig.style },
                                set: { state.displayConfig.style = $0 }
                            ),
                            options: ["light", "dark"],
                            label: { $0 == "dark" ? "暗色" : "亮色" }
                        )
                        sectionHint("墨水屏的显示配色，保存后立即推送到设备")

                        InkDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("预览")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .tracking(0.3)
                            stylePreview
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PageActionBar {
                Button { Task { await state.saveDisplayConfig() } } label: {
                    Label("保存并推送", systemImage: "checkmark.circle.fill")
                }
                .inkProminentButton()
                Button { Task { await state.forceDisplayRefresh() } } label: {
                    Label("立即刷新屏幕", systemImage: "arrow.clockwise")
                }
                .inkButton()
                Spacer()
                sectionHint("保存后立即推送到设备；立即刷新屏幕会强制设备重绘一次")
            }
        }
        .onAppear {
            Task { await state.fetchDisplayConfig() }
        }
    }

    private var stylePreview: some View {
        let isDark = state.displayConfig.style == "dark"
        let bg: Color = isDark ? Color(red: 0.12, green: 0.13, blue: 0.14) : Color(red: 0.96, green: 0.96, blue: 0.95)
        let fg: Color = isDark ? Color(white: 0.92) : Color(white: 0.12)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(fg.opacity(0.7)).frame(width: 6, height: 6)
                Text("待办")
                    .font(.caption2.weight(.semibold))
                Spacer()
            }
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(fg.opacity(0.6), lineWidth: 1)
                        .frame(width: 9, height: 9)
                    Text(["完成项目评审", "更新文档", "回复邮件"][i])
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .foregroundStyle(fg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fg.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var cliFilter: LogFilter = .all
    @State private var svcFilter: ServiceLogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "TRACE", title: "日志", subtitle: state.inlineStatus)

            HStack(alignment: .top, spacing: 16) {
                InkPanel(title: "CLI 事件", symbol: "terminal", accessory: AnyView(
                    InkSegmentedPicker(
                        selection: $cliFilter,
                        options: LogFilter.allCases,
                        label: { $0.label }
                    )
                    .frame(width: 300)
                )) {
                    LogText(lines: filteredCliLines)
                        .frame(minHeight: 460)
                }

                InkPanel(title: "服务日志", symbol: "server.rack", accessory: AnyView(
                    InkSegmentedPicker(
                        selection: $svcFilter,
                        options: ServiceLogFilter.allCases,
                        label: { $0.label }
                    )
                    .frame(width: 240)
                )) {
                    LogText(lines: filteredServiceLines)
                        .frame(minHeight: 460)
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

// MARK: - Theme

enum InkTheme {
    // 墨水屏黑白主色：accent 用近黑代替蓝色
    static let accent = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.96)
    // 状态用灰阶而非彩色：success 深黑、warning 中深灰、danger 深灰
    static let success = Color(red: 0.18, green: 0.20, blue: 0.18)
    static let warning = Color(red: 0.42, green: 0.40, blue: 0.32)
    static let danger = Color(red: 0.30, green: 0.26, blue: 0.26)
    // 像素点阵纹理色
    static let dither = Color(red: 0.55, green: 0.55, blue: 0.54)
}

/// 墨水屏点阵(dither)肌理：用稀疏小方点模拟墨水屏像素颗粒
struct InkDitherBackground: View {
    var opacity: Double = 0.5
    var step: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 1
            var y: CGFloat = step / 2
            var row = 0
            while y < size.height {
                let xOffset: CGFloat = (row % 2 == 0) ? 0 : step / 2
                var x: CGFloat = step / 2 + xOffset
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(rect), with: .color(InkTheme.dither.opacity(opacity)))
                    x += step
                }
                y += step
                row += 1
            }
        }
    }
}

enum MetricTone {
    case accent
    case success
    case idle
}

// MARK: - Shared Components

struct PageHeader<Trailing: View>: View {
    var eyebrow: String = ""
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(eyebrow: String = "", title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if !eyebrow.isEmpty {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(InkTheme.ink)
                            .frame(width: 14, height: 2)
                        Text(eyebrow)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(InkTheme.ink.opacity(0.75))
                            .tracking(1.6)
                    }
                }
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(InkTheme.ink)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PageActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.vertical, 2)
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: MetricTone

    init(title: String, value: String, detail: String, symbol: String, tone: MetricTone = .accent) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tone = tone
    }

    private var toneColor: Color {
        switch tone {
        case .accent: InkTheme.accent
        case .success: InkTheme.success
        case .idle: .secondary
        }
    }

    var body: some View {
        InkCard(hoverable: false) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(toneColor.opacity(0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(toneColor)
                    }
                    Spacer()
                    Text(title.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
                Text(value)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(tone == .idle ? .secondary : .primary)
                Text(detail.isEmpty ? "--" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 108, alignment: .topLeading)
        }
    }
}

struct InkPanel<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Bool
    let accessoryView: AnyView?
    @ViewBuilder var content: Content

    init(title: String, symbol: String, accent: Bool = false,
         accessory: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.accessoryView = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent ? InkTheme.accent : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                Spacer()
                if let accessoryView {
                    accessoryView
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(accent ? InkTheme.accent.opacity(0.25) : .primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
    }
}

struct InkCard<Content: View>: View {
    var hoverable: Bool
    @State private var isHovering = false
    @ViewBuilder var content: Content

    init(hoverable: Bool = false, @ViewBuilder content: () -> Content) {
        self.hoverable = hoverable
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(isHovering && hoverable ? 0.92 : 0.72),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.primary.opacity(isHovering && hoverable ? 0.28 : 0.16), lineWidth: 1)
            )
            .scaleEffect(isHovering && hoverable ? 1.005 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                guard hoverable else { return }
                isHovering = hovering
            }
    }
}

struct EmptyPanel: View {
    var symbol: String
    let title: String
    let detail: String

    init(symbol: String = "tray", title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    var body: some View {
        InkCard(hoverable: false) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

struct InkStatusPill: View {
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(active ? InkTheme.ink : .secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.14), lineWidth: 1))
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
            .foregroundStyle(active ? Color.white : .primary)
            .background(active ? InkTheme.ink : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(active ? Color.clear : .primary.opacity(0.22), lineWidth: 1))
    }
}

struct StatusDot: View {
    let status: String

    private var color: Color {
        switch status {
        case "ok": InkTheme.ink
        case "missing": InkTheme.warning
        default: .secondary
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 20, height: 20)
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
            if status != "ok" && status != "missing" {
                Circle()
                    .stroke(color, lineWidth: 1.4)
                    .frame(width: 20, height: 20)
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
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.16), lineWidth: 1))
        }
    }
}

struct PickerRow<Content: View>: View {
    let label: String
    let hint: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.callout.weight(.semibold))
            content
                .labelsHidden()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InkSegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    init(selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isSelected = selection == option
                let isLast = index == options.count - 1
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(InkTheme.accent)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .padding(isSelected ? 2 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if !isLast {
                        Rectangle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 1, height: 18)
                            .padding(.trailing, isSelected ? 0 : 0)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.primary.opacity(0.16), lineWidth: 1)
        )
    }
}

struct PathField: View {
    @Binding var text: String
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
            Button { choose() } label: {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
            }
            .inkIconButton()
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    var hint: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .frame(width: 140, alignment: .leading)
                Slider(value: $value, in: range, step: 100)
                    .tint(InkTheme.accent)
                Text("\(Int(value)) \(suffix)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(InkTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .frame(minWidth: 92, alignment: .trailing)
            }
            if !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 152)
            }
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

struct InkDivider: View {
    var body: some View {
        Divider()
            .opacity(0.6)
    }
}

func sectionHint(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
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
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.1), lineWidth: 1))
    }
}

struct InkBackground: View {
    var body: some View {
        ZStack {
            InkTheme.paper
            // 墨水屏点阵肌理
            InkDitherBackground(opacity: 0.35, step: 7)
            // 极淡的对角灰渐变，模拟墨水屏反光
            LinearGradient(
                colors: [
                    Color.white.opacity(0.5),
                    Color.clear,
                    Color.black.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Button Styles

extension View {
    func inkButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: false))
    }

    func inkProminentButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: true))
    }

    func inkDangerButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: true, tone: InkTheme.warning))
    }

    func inkIconButton(danger: Bool = false) -> some View {
        buttonStyle(InkIconButtonStyle(danger: danger))
    }

    func inkToolbarButton() -> some View {
        buttonStyle(InkToolbarButtonStyle())
    }

    func inkToolbarProminentButton() -> some View {
        buttonStyle(InkToolbarButtonStyle(prominent: true))
    }

    func hoverEffect() -> some View {
        modifier(HoverHighlightModifier())
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let prominent: Bool
    var tone: Color = InkTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, paddingH)
            .frame(minHeight: 30)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: prominent ? tone.opacity(configuration.isPressed ? 0.1 : 0.25) : .clear, radius: prominent ? 6 : 0, y: 2)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var paddingH: CGFloat {
        switch controlSize {
        case .small: 8
        default: 13
        }
    }

    private var foreground: Color {
        prominent ? .white : .primary
    }

    private var borderColor: Color {
        prominent ? Color.clear : .primary.opacity(0.22)
    }

    private func background(configuration: Configuration) -> Color {
        if prominent {
            return tone.opacity(configuration.isPressed ? 0.82 : 0.95)
        }
        return Color.primary.opacity(configuration.isPressed ? 0.1 : 0.04)
    }
}

struct InkIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let danger: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(danger ? InkTheme.warning : .primary)
            .frame(width: 26, height: 26)
            .background(
                (danger ? InkTheme.warning : Color.primary).opacity(configuration.isPressed ? 0.16 : 0.06),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct InkToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? .white : .primary)
            .padding(.horizontal, 11)
            .frame(minHeight: 26)
            .background(
                prominent ? InkTheme.accent.opacity(configuration.isPressed ? 0.82 : 0.95) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.primary.opacity(prominent ? 0 : 0.2), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InkTheme.ink.opacity(isHovering ? 0.08 : 0))
            )
            .onHover { isHovering = $0 }
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
                        .fill(configuration.isOn ? InkTheme.accent : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(configuration.isOn ? InkTheme.accent : .primary.opacity(0.5), lineWidth: 1.3)
                        .frame(width: 18, height: 18)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
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
