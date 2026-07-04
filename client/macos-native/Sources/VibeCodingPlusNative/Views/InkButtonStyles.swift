import SwiftUI
// MARK: - Button Styles

extension View {
    func inkButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: false))
    }

    func inkProminentButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: true))
    }

    func inkDangerButton() -> some View {
        buttonStyle(InkButtonStyle(prominent: true, tone: InkTheme.warning))
    }

    func inkIconButton(danger: Bool = false) -> some View {
        buttonStyle(InkIconButtonStyle(danger: danger))
    }

    func inkToolbarButton() -> some View {
        buttonStyle(InkToolbarButtonStyle())
    }

    func inkToolbarProminentButton() -> some View {
        buttonStyle(InkToolbarButtonStyle(prominent: true))
    }

    func hoverEffect() -> some View {
        modifier(HoverHighlightModifier())
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let prominent: Bool
    var tone: Color = InkTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, paddingH)
            .frame(minHeight: 30)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: prominent ? tone.opacity(configuration.isPressed ? 0.1 : 0.25) : .clear, radius: prominent ? 6 : 0, y: 2)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var paddingH: CGFloat {
        switch controlSize {
        case .small: 8
        default: 13
        }
    }

    private var foreground: Color {
        prominent ? .white : .primary
    }

    private var borderColor: Color {
        prominent ? Color.clear : .primary.opacity(0.22)
    }

    private func background(configuration: Configuration) -> Color {
        if prominent {
            return tone.opacity(configuration.isPressed ? 0.82 : 0.95)
        }
        return Color.primary.opacity(configuration.isPressed ? 0.1 : 0.04)
    }
}

struct InkIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let danger: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(danger ? InkTheme.warning : .primary)
            .frame(width: 26, height: 26)
            .background(
                (danger ? InkTheme.warning : Color.primary).opacity(configuration.isPressed ? 0.16 : 0.06),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct InkToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? .white : .primary)
            .padding(.horizontal, 11)
            .frame(minHeight: 26)
            .background(
                prominent ? InkTheme.accent.opacity(configuration.isPressed ? 0.82 : 0.95) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.primary.opacity(prominent ? 0 : 0.2), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InkTheme.ink.opacity(isHovering ? 0.08 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

struct InkCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? InkTheme.accent : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(configuration.isOn ? InkTheme.accent : .primary.opacity(0.5), lineWidth: 1.3)
                        .frame(width: 18, height: 18)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                configuration.label
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
