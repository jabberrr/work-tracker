import SwiftUI

/// Larger, clickable filter chip (it is the Button). At text size Standard:
/// - calloutFont .medium, padding h 11 / v 5, min height 26, chipShape, ColorDot 8 × textScale when colorHex != nil.
/// - Selected: accent tint fill + accent 1 pt stroke + accent text.
/// - Unselected: insetSurface + separator stroke + textPrimary.
/// - Hover: overlay textPrimary.opacity(0.05).
/// - a11y: label = title, .isSelected trait. Caller adds .help(title).
///
///     FilterChip("All", colorHex: nil, isSelected: filter == nil) { filter = nil }.help("All")
///
/// Use in a horizontal `ScrollView(showsIndicators: false)` with `HStack(spacing: 6)` (History label filter).
/// `TagChip` stays the small, read-only token for tags.
struct FilterChip: View {
    @Environment(\.theme) private var theme
    private let title: String
    private let colorHex: String?
    private let isSelected: Bool
    private let action: () -> Void

    init(_ title: String, colorHex: String?, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.colorHex = colorHex
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let colorHex {
                    ColorDot(hex: colorHex, size: 8 * theme.textScale)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(FilterChipButtonStyle(isSelected: isSelected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Implementation

private struct FilterChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        FilterChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct FilterChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, isSelected: Bool) {
        self.configuration = configuration
        self.isSelected = isSelected
    }

    var body: some View {
        let shape = theme.chipShape
        configuration.label
            .font(theme.calloutFont.weight(.medium))
            .foregroundStyle(isSelected ? theme.accent : theme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(minHeight: (26 * theme.textScale).rounded())
            .background {
                ZStack {
                    shape.fill(isSelected ? theme.accent.opacity(theme.tintOpacity) : theme.insetSurface)
                    if configuration.isPressed {
                        shape.fill(theme.textPrimary.opacity(0.1))
                    } else if isHovering {
                        shape.fill(theme.textPrimary.opacity(0.05))
                    }
                }
            }
            .overlay {
                // `chipShape` isn't insettable: inset the 1 pt stroke by half its width so it stays inside.
                shape
                    .stroke(isSelected ? theme.accent : theme.separator, lineWidth: 1)
                    .padding(0.5)
            }
            .overlay {
                if isFocused {
                    shape.stroke(theme.accent.opacity(0.55), lineWidth: 2).padding(-2)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in isHovering = isEnabled && hovering }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }
}

#Preview("FilterChip") {
    HStack(spacing: 6) {
        FilterChip("All", colorHex: nil, isSelected: true) {}
        FilterChip("Deep work", colorHex: "#3B82F6", isSelected: false) {}
        FilterChip("Meetings", colorHex: "#F59E0B", isSelected: false) {}
    }
    .padding(24)
}
