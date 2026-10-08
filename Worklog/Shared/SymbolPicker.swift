import SwiftUI

/// Grid of LabelPalette.symbols. A current symbol that isn't in the palette is shown first so it
/// stays visible/selected. Selected cell: accent tint + accent symbol.
struct SymbolPicker: View {
    @Environment(\.theme) private var theme
    @Binding private var symbolName: String
    private let palette: [String]

    init(symbolName: Binding<String>) {
        self._symbolName = symbolName
        self.palette = LabelPalette.symbols
    }

    /// (Extra, round 3) A custom symbol list, e.g. `LabelPalette.profileSymbolChoices` for profiles.
    init(symbolName: Binding<String>, symbols: [String]) {
        self._symbolName = symbolName
        self.palette = symbols
    }

    private var symbols: [String] {
        if symbolName.isEmpty || palette.contains(symbolName) { return palette }
        return [symbolName] + palette
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 4)], spacing: 4) {
            ForEach(symbols, id: \.self) { symbol in
                SymbolPickerCell(symbol: symbol, isSelected: symbol == symbolName) {
                    symbolName = symbol
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Symbol")
    }
}

private struct SymbolPickerCell: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    init(symbol: String, isSelected: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS + 1, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? theme.accent : (isHovering ? theme.textPrimary : theme.textSecondary))
                .frame(width: 30, height: 30)
                .background(shape.fill(isSelected
                                       ? theme.accent.opacity(theme.tintOpacity + 0.04)
                                       : (isHovering ? theme.textPrimary.opacity(0.06) : Color.clear)))
                .overlay {
                    if isSelected {
                        shape.strokeBorder(theme.accent.opacity(0.6), lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(LabelPalette.accessibilityName(forSymbol: symbol))
        .accessibilityLabel(LabelPalette.accessibilityName(forSymbol: symbol))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
