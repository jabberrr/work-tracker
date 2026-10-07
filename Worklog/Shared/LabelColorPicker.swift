import SwiftUI

/// Palette swatches (LabelPalette.swatches) + a system ColorPicker well for a custom color.
/// Writes "#RRGGBB" into `hex`. The selected swatch gets a ring (and the `isSelected` trait).
struct LabelColorPicker: View {
    @Environment(\.theme) private var theme
    @Binding private var hex: String

    init(hex: Binding<String>) {
        self._hex = hex
    }

    private var customColor: Binding<Color> {
        Binding<Color>(
            get: { Color(hex: hex) },
            set: { newValue in hex = newValue.hexString }
        )
    }

    var body: some View {
        let current = LabelPalette.normalized(hex)
        let isCustom = LabelPalette.name(forHex: hex) == nil

        HStack(alignment: .top, spacing: theme.spacingM) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(LabelPalette.swatches) { swatch in
                    let selected = LabelPalette.normalized(swatch.hex) == current
                    Button {
                        hex = swatch.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(theme.textPrimary.opacity(0.12), lineWidth: 0.5)
                            }
                            .padding(3)
                            .overlay {
                                if selected {
                                    Circle().strokeBorder(theme.textPrimary, lineWidth: 1.5)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .padding(2)
                .overlay {
                    if isCustom {
                        RoundedRectangle(cornerRadius: theme.radiusS + 2, style: .continuous)
                            .strokeBorder(theme.textPrimary, lineWidth: 1.5)
                    }
                }
                .help("Custom color")
                .accessibilityLabel("Custom color")
        }
    }
}
