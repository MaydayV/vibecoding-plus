import SwiftUI
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
                .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)
        } detail: {
            ZStack {
                InkBackground()
                detailContent
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    serviceControl
                }
            }
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
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
    private var detailContent: some View {
        let padded = content
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 1200, alignment: .topLeading)

        if selection == .logs {
            padded
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                padded
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
