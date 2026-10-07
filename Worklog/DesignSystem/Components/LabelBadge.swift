import SwiftUI
import SwiftData

enum BadgeSize {
    case small, regular, large
}

/// The label's symbol (in the label color) + its name on a faint tint of the label color.
/// The name is always shown, so color is never the only signal. `nil` → "Unlabeled".
struct LabelBadge: View {
    @Environment(\.theme) private var theme
    private let label: WorkLabel?
    private let size: BadgeSize

    init(label: WorkLabel?, size: BadgeSize = .regular) {
        self.label = label
        self.size = size
    }

    var body: some View {
        let name: String = label.map { l in
            let n = l.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "Untitled label" : n
        } ?? "Unlabeled"
        let tint: Color = label?.color ?? theme.textTertiary
        let symbol = label?.symbolName ?? "circle.dashed"

        HStack(spacing: iconSpacing) {
            Image(systemName: symbol)
                .font(iconFont)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(name)
                .font(textFont)
                .foregroundStyle(label == nil ? theme.textSecondary : theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(theme.chipShape.fill(tint.opacity(label == nil ? 0.08 : theme.tintOpacity)))
        .overlay {
            if label == nil {
                theme.chipShape.stroke(theme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == nil ? "Unlabeled" : "Label: \(name)")
    }

    private var iconFont: Font {
        switch size {
        case .small: return .system(size: 9 * theme.textScale, weight: .semibold)
        case .regular: return .system(size: 10.5 * theme.textScale, weight: .semibold)
        case .large: return .system(size: 13 * theme.textScale, weight: .semibold)
        }
    }

    private var textFont: Font {
        switch size {
        case .small: return theme.captionFont
        case .regular: return theme.labelFont
        case .large: return theme.headlineFont
        }
    }

    private var iconSpacing: CGFloat {
        switch size {
        case .small: return 3
        case .regular: return 4
        case .large: return 6
        }
    }

    private var hPadding: CGFloat {
        switch size {
        case .small: return 5
        case .regular: return 7
        case .large: return 10
        }
    }

    private var vPadding: CGFloat {
        switch size {
        case .small: return 1.5
        case .regular: return 3
        case .large: return 5
        }
    }
}
