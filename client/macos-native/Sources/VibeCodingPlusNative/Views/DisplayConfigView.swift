import SwiftUI
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
