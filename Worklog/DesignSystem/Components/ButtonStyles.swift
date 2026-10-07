import SwiftUI

// All styles: read the theme, respond to hover (subtle fill change), press (slight darken/scale-free),
// disabled (45 % opacity), keyboard focus (accent ring), and `controlSize` (.small / .regular / .large).
// Hover/press animations are skipped under Reduce Motion.

/// Filled accent button for the one primary action in a region (Start, Save, Create).
struct PrimaryButtonStyle: ButtonStyle {
    init() {}
    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: .primary)
    }
}

/// Low-emphasis bordered button (secondary actions: Pause, Split, Cancel, Attach…).
struct QuietButtonStyle: ButtonStyle {
    init() {}
    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: .quiet)
    }
}

/// Danger-tinted button (Discard, Delete). Not filled: destructive actions should not shout.
struct DestructiveButtonStyle: ButtonStyle {
    init() {}
    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: .destructive)
    }
}

/// Square, borderless icon button (toolbar-like). Always add `.accessibilityLabel` and `.help`.
struct IconButtonStyle: ButtonStyle {
    private let size: CGFloat
    init(size: CGFloat = 28) {
        self.size = size
    }
    func makeBody(configuration: Configuration) -> some View {
        DSIconButtonBody(configuration: configuration, size: size)
    }
}

// MARK: - Implementation

private enum DSButtonKind { case primary, quiet, destructive }

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonKind

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, kind: DSButtonKind) {
        self.configuration = configuration
        self.kind = kind
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS + (controlSize == .large ? 2 : 0), style: .continuous)
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .frame(minHeight: minHeight)
            .background(shape.fill(fill))
            .overlay {
                if let b = border {
                    shape.strokeBorder(b, lineWidth: 1)
                }
            }
            .overlay {
                if isFocused {
                    shape.stroke(theme.accent.opacity(0.55), lineWidth: 2).padding(-2.5)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in isHovering = isEnabled && hovering }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var font: Font {
        switch controlSize {
        case .mini, .small: return theme.calloutFont.weight(.medium)
        case .large, .extraLarge: return theme.bodyFont.weight(.semibold)
        default: return theme.bodyFont.weight(kind == .primary ? .semibold : .medium)
        }
    }

    private var hPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 8
        case .large, .extraLarge: return 18
        default: return 12
        }
    }

    private var vPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 3
        case .large, .extraLarge: return 8
        default: return 5
        }
    }

    private var minHeight: CGFloat {
        switch controlSize {
        case .mini, .small: return 22
        case .large, .extraLarge: return 34
        default: return 28
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return theme.onAccent
        case .quiet: return theme.textPrimary
        case .destructive: return theme.danger
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary:
            if pressed { return theme.accent.opacity(0.78) }
            return isHovering ? theme.accent.opacity(0.9) : theme.accent
        case .quiet:
            if pressed { return theme.textPrimary.opacity(0.12) }
            return isHovering ? theme.textPrimary.opacity(0.06) : theme.surface.opacity(0.6)
        case .destructive:
            if pressed { return theme.danger.opacity(0.24) }
            return theme.danger.opacity(isHovering ? 0.16 : 0.09)
        }
    }

    private var border: Color? {
        switch kind {
        case .primary: return nil
        case .quiet: return theme.separator
        case .destructive: return theme.danger.opacity(0.35)
        }
    }
}

private struct DSIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, size: CGFloat) {
        self.configuration = configuration
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.radiusS + 1, size / 3), style: .continuous)
        configuration.label
            .font(.system(size: (size * 0.46).rounded(), weight: .medium))
            .labelStyle(.iconOnly)
            .foregroundStyle(isHovering || configuration.isPressed ? theme.textPrimary : theme.textSecondary)
            .frame(width: size, height: size)
            .background(shape.fill(fill))
            .overlay {
                if isFocused {
                    shape.stroke(theme.accent.opacity(0.55), lineWidth: 2).padding(-1.5)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering in isHovering = isEnabled && hovering }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: Color {
        if configuration.isPressed { return theme.textPrimary.opacity(0.14) }
        return isHovering ? theme.textPrimary.opacity(0.07) : .clear
    }
}

#Preview("Buttons") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Button("Start session") {}.buttonStyle(PrimaryButtonStyle())
            Button("Pause") {}.buttonStyle(QuietButtonStyle())
            Button("Discard") {}.buttonStyle(DestructiveButtonStyle())
            Button {} label: { Image(systemName: "scissors") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Split segment")
        }
        HStack {
            Button("Small") {}.buttonStyle(PrimaryButtonStyle()).controlSize(.small)
            Button("Large") {}.buttonStyle(QuietButtonStyle()).controlSize(.large)
            Button("Disabled") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
        }
    }
    .padding(24)
}
