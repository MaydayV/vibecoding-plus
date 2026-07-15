import SwiftUI
import EventKit
// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "CONFIG", title: "设置", subtitle: state.inlineStatus)

            InkPanel(title: "macOS 权限状态", symbol: "checkmark.shield", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        permIndicator("辅助功能", granted: AccessibilitySupport.isTrusted, needed: state.config.sendTarget == .textInjector)
                        permIndicator("麦克风", granted: micPermissionGranted(), needed: true)
                        permIndicator("提醒事项", granted: reminderPermissionGranted(), needed: state.config.remindersSyncEnabled)
                        Spacer()
                        Button { state.revealAppInFinder() } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        .inkButton()
                        Button { state.openPermissions() } label: {
                            Label("打开权限", systemImage: "lock.open")
                        }
                        .inkButton()
                        Button { Task { await state.refreshEnvironment() } } label: {
                            Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .inkButton()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前运行的应用")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(InkTheme.ink.opacity(0.5))
                        Text(AccessibilitySupport.runningAppPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }

                    if state.config.sendTarget == .textInjector && !AccessibilitySupport.isTrusted {
                        Text(AccessibilitySupport.reauthorizeHint)
                            .font(.caption)
                            .foregroundStyle(InkTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("注入诊断日志：~/Library/Application Support/vibecoding-plus/inject.log")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
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

            TickTickView()

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
