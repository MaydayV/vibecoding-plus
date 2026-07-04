import SwiftUI
// MARK: - Shared Components

struct PageHeader<Trailing: View>: View {
    var eyebrow: String = ""
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(eyebrow: String = "", title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if !eyebrow.isEmpty {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(InkTheme.ink)
                            .frame(width: 14, height: 2)
                        Text(eyebrow)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(InkTheme.ink.opacity(0.75))
                            .tracking(1.6)
                    }
                }
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(InkTheme.ink)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PageActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.vertical, 2)
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: MetricTone

    init(title: String, value: String, detail: String, symbol: String, tone: MetricTone = .accent) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tone = tone
    }

    private var toneColor: Color {
        switch tone {
        case .accent: InkTheme.accent
        case .success: InkTheme.success
        case .idle: .secondary
        }
    }

    var body: some View {
        InkCard(hoverable: false) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(toneColor.opacity(0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(toneColor)
                    }
                    Spacer()
                    Text(title.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
                Text(value)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(tone == .idle ? .secondary : .primary)
                Text(detail.isEmpty ? "--" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 108, alignment: .topLeading)
        }
    }
}

struct InkPanel<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Bool
    let accessoryView: AnyView?
    @ViewBuilder var content: Content

    init(title: String, symbol: String, accent: Bool = false,
         accessory: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.accessoryView = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent ? InkTheme.accent : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                Spacer()
                if let accessoryView {
                    accessoryView
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(accent ? InkTheme.accent.opacity(0.25) : .primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
    }
}

struct InkCard<Content: View>: View {
    var hoverable: Bool
    @State private var isHovering = false
    @ViewBuilder var content: Content

    init(hoverable: Bool = false, @ViewBuilder content: () -> Content) {
        self.hoverable = hoverable
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(isHovering && hoverable ? 0.92 : 0.72),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.primary.opacity(isHovering && hoverable ? 0.28 : 0.16), lineWidth: 1)
            )
            .scaleEffect(isHovering && hoverable ? 1.005 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                guard hoverable else { return }
                isHovering = hovering
            }
    }
}

struct EmptyPanel: View {
    var symbol: String
    let title: String
    let detail: String

    init(symbol: String = "tray", title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    var body: some View {
        InkCard(hoverable: false) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

struct InkStatusPill: View {
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(active ? InkTheme.ink : .secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                Text(title)
                    .font(.caption.monospaced().weight(.bold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.14), lineWidth: 1))
    }
}

struct StatusBadge: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.white : .primary)
            .background(active ? InkTheme.ink : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(active ? Color.clear : .primary.opacity(0.22), lineWidth: 1))
    }
}

struct StatusDot: View {
    let status: String

    private var color: Color {
        switch status {
        case "ok": InkTheme.ink
        case "missing": InkTheme.warning
        default: .secondary
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 20, height: 20)
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
            if status != "ok" && status != "missing" {
                Circle()
                    .stroke(color, lineWidth: 1.4)
                    .frame(width: 20, height: 20)
            }
        }
    }
}

struct InkFormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            content
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.16), lineWidth: 1))
        }
    }
}

struct PickerRow<Content: View>: View {
    let label: String
    let hint: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.callout.weight(.semibold))
            content
                .labelsHidden()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InkSegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    init(selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isSelected = selection == option
                let isLast = index == options.count - 1
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(InkTheme.accent)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .padding(isSelected ? 2 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if !isLast {
                        Rectangle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 1, height: 18)
                            .padding(.trailing, isSelected ? 0 : 0)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.primary.opacity(0.16), lineWidth: 1)
        )
    }
}

struct PathField: View {
    @Binding var text: String
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
            Button { choose() } label: {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
            }
            .inkIconButton()
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    var hint: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .frame(width: 140, alignment: .leading)
                Slider(value: $value, in: range, step: 100)
                    .tint(InkTheme.accent)
                Text("\(Int(value)) \(suffix)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(InkTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .frame(minWidth: 92, alignment: .trailing)
            }
            if !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 152)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "--" : value)
                .font(.callout.monospaced())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct InkDivider: View {
    var body: some View {
        Divider()
            .opacity(0.6)
    }
}

func sectionHint(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

struct LogText: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "暂无日志" : lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.1), lineWidth: 1))
    }
}

struct InkBackground: View {
    var body: some View {
        ZStack {
            InkTheme.paper
            // 墨水屏点阵肌理
            InkDitherBackground(opacity: 0.35, step: 7)
            // 极淡的对角灰渐变，模拟墨水屏反光
            LinearGradient(
                colors: [
                    Color.white.opacity(0.5),
                    Color.clear,
                    Color.black.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
