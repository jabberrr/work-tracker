import SwiftUI

/// Horizontal section switcher (Settings).
/// - Buttons: icon + title, calloutFont .medium, padding 10×5, radiusS.
/// - Selected: accent.opacity(tintOpacity) fill + accent foreground.
/// - Unselected: textSecondary, hover fill textPrimary.opacity(0.06).
/// - Scrolls horizontally when it doesn't fit (ViewThatFits).
/// - Each button has the .isSelected trait; the container's a11y label is "Sections".
///
///     PillTabBar(items: SettingsTab.allCases, selection: $tab, title: { $0.title }, systemImage: { $0.systemImage })
///
/// The bar takes its natural width when it fits (place it with the parent's alignment); otherwise it fills the
/// proposed width and scrolls.
struct PillTabBar<Item: Hashable & Identifiable>: View {
    @Environment(\.theme) private var theme
    @Binding private var selection: Item
    private let items: [Item]
    private let title: (Item) -> String
    private let systemImage: (Item) -> String?

    init(items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
         systemImage: @escaping (Item) -> String?) {
        self.items = items
        self._selection = selection
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttonRow
            ScrollView(.horizontal, showsIndicators: false) {
                buttonRow
                    .padding(.vertical, 3)   // keeps the focus ring inside the clip
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private var buttonRow: some View {
        HStack(spacing: theme.spacingXS) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    PillTabLabel(title: title(item), systemImage: systemImage(item))
                }
                .buttonStyle(PillTabButtonStyle(isSelected: isSelected))
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Implementation

private struct PillTabLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
        }
    }
}

private struct PillTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillTabButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct PillTabButtonBody: View {
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
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        configuration.label
            .font(theme.calloutFont.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(shape.fill(fill))
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

    private var foreground: Color {
        if isSelected { return theme.accent }
        return isHovering || configuration.isPressed ? theme.textPrimary : theme.textSecondary
    }

    private var fill: Color {
        if isSelected {
            return theme.accent.opacity(theme.tintOpacity + (configuration.isPressed ? 0.06 : 0))
        }
        if configuration.isPressed { return theme.textPrimary.opacity(0.1) }
        return isHovering ? theme.textPrimary.opacity(0.06) : .clear
    }
}

private enum PillTabPreviewItem: String, CaseIterable, Identifiable {
    case general, appearance, overlay, shortcuts
    var id: String { rawValue }
}

#Preview("PillTabBar") {
    PillTabBar(items: PillTabPreviewItem.allCases, selection: .constant(.appearance),
               title: { $0.rawValue.capitalized },
               systemImage: { item -> String? in
                   switch item {
                   case .general: return "gearshape"
                   case .appearance: return "paintpalette"
                   case .overlay: return "rectangle.inset.topright.filled"
                   case .shortcuts: return "keyboard"
                   }
               })
        .padding(24)
}
