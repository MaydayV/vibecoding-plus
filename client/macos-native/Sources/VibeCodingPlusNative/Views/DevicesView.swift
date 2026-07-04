import SwiftUI
import AppKit
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

            if state.serviceRunning {
                pairingBanner
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

    private var pairingBanner: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Host: \(state.config.discoveryHostId) · 配对码")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.pairingCode.isEmpty ? "------" : state.pairingCode)
                    .font(.title2.monospaced().weight(.bold))
                    .textSelection(.enabled)
            }
            Spacer()
            Text("设备连上后点「确认配对」下发密钥。未连 Wi‑Fi 时碰 NFC 进配网；已有 Wi‑Fi 未连 Mac 时碰 NFC 打开手机配对说明页（:8768/pair）。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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
                deviceActions
                otaProgressRow
            }
        }
    }

    @ViewBuilder
    private var otaProgressRow: some View {
        if let progress = state.otaProgress[device.deviceId] {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("固件升级")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(progress.phase) \(progress.pct)%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(progress.pct), total: 100)
            }
        }
    }

    private var deviceActions: some View {
        HStack(spacing: 10) {
            Text("设备操作")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                Task { await state.provisionDevice(device) }
            } label: {
                Label(device.isProvisioned ? "已配对" : "确认配对", systemImage: "key.fill")
            }
            .inkButton()
            .disabled(device.isProvisioned)
            Button {
                Task { await state.offerFirmware(to: device) }
            } label: {
                Label("固件 OTA", systemImage: "arrow.down.circle")
            }
            .inkButton()
            Spacer()
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
