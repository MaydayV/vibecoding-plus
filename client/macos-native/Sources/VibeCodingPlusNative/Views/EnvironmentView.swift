import SwiftUI
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
