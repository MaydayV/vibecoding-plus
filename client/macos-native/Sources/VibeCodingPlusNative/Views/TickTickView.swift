import SwiftUI

struct TickTickView: View {
    @EnvironmentObject private var state: AppState
    @State private var showToken = false
    @State private var selectedProjectId = ""
    @State private var pollSec: String = "60"

    var body: some View {
        InkPanel(title: "TickTick 同步", symbol: "arrow.triangle.2.circlepath", accent: true) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("启用 TickTick 同步", isOn: $state.config.tickTickSyncEnabled)
                    .toggleStyle(InkCheckboxToggleStyle())

                InkFormRow("Access Token") {
                    HStack(spacing: 8) {
                        if showToken {
                            TextField("粘贴 TickTick OAuth Access Token", text: $state.config.tickTickAccessToken)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("粘贴 TickTick OAuth Access Token", text: $state.config.tickTickAccessToken)
                                .textFieldStyle(.plain)
                        }
                        Button { showToken.toggle() } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .inkIconButton()
                    }
                }

                HStack(spacing: 12) {
                    Picker("默认清单", selection: $selectedProjectId) {
                        Text("请选择清单").tag("")
                        ForEach(state.tickTickProjects) { project in
                            Text(project.title).tag(project.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                    .onChange(of: selectedProjectId) { _, newValue in
                        state.config.tickTickProjectId = newValue
                    }

                    Button { Task { await state.fetchTickTickProjects() } } label: {
                        Label("刷新清单", systemImage: "arrow.clockwise")
                    }
                    .inkButton()

                    Spacer()
                }

                HStack(spacing: 12) {
                    InkFormRow("轮询间隔 (秒)") {
                        TextField("60", text: $pollSec)
                            .textFieldStyle(.plain)
                            .frame(width: 80)
                            .onChange(of: pollSec) { _, newValue in
                                if let value = Int(newValue), value > 0 {
                                    state.config.tickTickPollSec = value
                                }
                            }
                    }

                    Button { Task { await state.runTickTickSync() } } label: {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .inkButton()

                    Spacer()
                }

                if let status = state.tickTickSyncStatus {
                    HStack(spacing: 12) {
                        StatusBadge(
                            text: status.enabled == true ? "同步已启用" : "同步已停用",
                            active: status.enabled == true
                        )
                        if let last = status.lastSyncAt {
                            Text("上次同步: \(formatTimestamp(last))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = status.lastError, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(InkTheme.warning)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                }

                Text("Access Token 会保存在本地 config.env 中。如需 OAuth 授权流程，可在后续版本补充。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            selectedProjectId = state.config.tickTickProjectId
            pollSec = String(state.config.tickTickPollSec)
            Task { await state.fetchTickTickProjects() }
        }
    }

    private func formatTimestamp(_ value: Double) -> String {
        let date = Date(timeIntervalSince1970: value)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
