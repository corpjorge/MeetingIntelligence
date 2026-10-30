import SwiftUI

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive, recording }
    enum Size { case regular, small, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(size == .small ? DS.Font.callout.weight(.medium) : DS.Font.bodyEmphasis)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, size == .small ? DS.Space.s : (size == .large ? DS.Space.l : DS.Space.m))
                .frame(minHeight: size == .small ? DS.Size.buttonHeightSmall : (size == .large ? DS.Size.buttonHeightLarge : DS.Size.buttonHeight))
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Layout.hairline)
                    }
                }
                .opacity(isEnabled ? 1 : DS.Opacity.disabledButton)
                .scaleEffect(configuration.isPressed ? DS.Scale.pressed : 1)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }

        private var foreground: Color {
            switch kind {
            case .primary, .recording: DS.Color.onAccent
            case .secondary, .ghost: DS.Color.textPrimary
            case .destructive: DS.Color.danger
            }
        }

        private var background: Color {
            let pressedOrHover = configuration.isPressed || hovering
            switch kind {
            case .primary: return DS.Color.accent.opacity(pressedOrHover ? DS.Opacity.pressedFill : 1)
            case .recording: return DS.Color.recording.opacity(pressedOrHover ? DS.Opacity.pressedFill : 1)
            case .secondary: return pressedOrHover ? DS.Color.hover : DS.Color.surface
            case .ghost: return pressedOrHover ? DS.Color.hover : .clear
            case .destructive: return DS.Color.danger.opacity(pressedOrHover ? DS.Opacity.destructivePressedFill : DS.Opacity.destructiveFill)
            }
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
    static func ds(_ kind: DSButtonStyle.Kind, size: DSButtonStyle.Size = .regular) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size)
    }
}

/// Square icon-only button with hover feedback and a mandatory help label (accessibility).
struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = DS.Color.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Font.iconButton)
                .foregroundStyle(hovering ? DS.Color.textPrimary : tint)
                .frame(width: DS.Layout.iconButton, height: DS.Layout.iconButton)
                .background(hovering ? DS.Color.hover : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
