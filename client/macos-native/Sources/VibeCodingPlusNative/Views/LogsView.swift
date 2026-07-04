import SwiftUI

private enum LogSection: String, CaseIterable, Identifiable {
    case cli
    case service

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cli: "CLI 事件"
        case .service: "服务日志"
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: LogSection = .cli
    @State private var cliFilter: LogFilter = .all
    @State private var svcFilter: ServiceLogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "TRACE", title: "日志", subtitle: state.inlineStatus)

            InkSegmentedPicker(
                selection: $section,
                options: LogSection.allCases,
                label: { $0.label }
            )
            .frame(maxWidth: 320)

            switch section {
            case .cli:
                logCard {
                    InkSegmentedPicker(
                        selection: $cliFilter,
                        options: LogFilter.allCases,
                        label: { $0.label }
                    )
                    LogText(lines: filteredCliLines)
                        .frame(maxWidth: .infinity)
                        .frame(height: 480)
                }
            case .service:
                logCard {
                    InkSegmentedPicker(
                        selection: $svcFilter,
                        options: ServiceLogFilter.allCases,
                        label: { $0.label }
                    )
                    LogText(lines: filteredServiceLines)
                        .frame(maxWidth: .infinity)
                        .frame(height: 480)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(18)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
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
