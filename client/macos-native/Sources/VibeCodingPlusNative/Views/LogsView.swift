import SwiftUI
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
