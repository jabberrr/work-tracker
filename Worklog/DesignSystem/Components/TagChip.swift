import SwiftUI
import SwiftData

/// A compact tag token: optional color dot (only for tags with a custom color), name, optional
/// remove (×) button. Selected chips get an accent tint and border.
struct TagChip: View {
    @Environment(\.theme) private var theme
    @State private var isHoveringRemove = false

    private let tag: WorkTag?
    private let rawName: String
    private let rawHex: String
    private let isSelected: Bool
    private let onRemove: (() -> Void)?

    init(tag: WorkTag, isSelected: Bool = false, onRemove: (() -> Void)? = nil) {
        self.tag = tag
        self.rawName = ""
        self.rawHex = LabelPalette.defaultTagHex
        self.isSelected = isSelected
        self.onRemove = onRemove
    }

    init(name: String, colorHex: String, isSelected: Bool = false, onRemove: (() -> Void)? = nil) {
        self.tag = nil
        self.rawName = name
        self.rawHex = colorHex
        self.isSelected = isSelected
        self.onRemove = onRemove
    }

    var body: some View {
        // Read model properties in body so the chip observes renames/recolors.
        // A deleted tag is never read (that traps); it renders as an empty neutral chip.
        let liveTag = ModelLiveness.live(tag)
        let name = liveTag?.name ?? rawName
        let hex = liveTag?.colorHex ?? rawHex
        let showsDot = LabelPalette.normalized(hex) != LabelPalette.normalized(LabelPalette.defaultTagHex)

        HStack(spacing: 4) {
            if showsDot {
                ColorDot(hex: hex, size: 6 * theme.textScale)
            }
            Text(name)
                .font(theme.labelFont)
                .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5 * theme.textScale, weight: .bold))
                        .foregroundStyle(isHoveringRemove ? theme.textPrimary : theme.textTertiary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRemove = $0 }
                .accessibilityLabel("Remove tag \(name)")
                .help("Remove “\(name)”")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, onRemove == nil ? 7 : 4)
        .padding(.vertical, 2.5)
        .background(theme.chipShape.fill(isSelected ? theme.accent.opacity(theme.tintOpacity) : theme.insetSurface))
        .overlay {
            theme.chipShape.stroke(isSelected ? theme.accent.opacity(0.55) : theme.separator, lineWidth: 1)
        }
        .fixedSize()
        .accessibilityElement(children: onRemove == nil ? .combine : .contain)
        .accessibilityLabel("Tag: \(name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
