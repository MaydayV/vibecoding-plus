import SwiftUI
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
