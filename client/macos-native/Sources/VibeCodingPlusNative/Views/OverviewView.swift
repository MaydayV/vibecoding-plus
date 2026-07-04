import SwiftUI
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
