import SwiftUI
import SwiftData

extension WorkLabel {
    /// Color(hex: colorHex). A deleted label (not readable) yields the neutral tag color.
    var color: Color {
        ModelLiveness.isLive(self) ? Color(hex: colorHex) : Color(hex: LabelPalette.defaultTagHex)
    }
}

extension WorkTag {
    /// Color(hex: colorHex). A deleted tag (not readable) yields the neutral tag color.
    var color: Color {
        ModelLiveness.isLive(self) ? Color(hex: colorHex) : Color(hex: LabelPalette.defaultTagHex)
    }

    /// (Extra) True when the tag still has the default neutral color; chips then omit the color dot.
    /// False for a deleted tag.
    var hasCustomColor: Bool {
        guard ModelLiveness.isLive(self) else { return false }
        return LabelPalette.normalized(colorHex) != LabelPalette.normalized(LabelPalette.defaultTagHex)
    }
}

extension WorkProfile {
    /// Color(hex: colorHex). A deleted profile (not readable) yields the neutral tag color.
    var color: Color {
        ModelLiveness.isLive(self) ? Color(hex: colorHex) : Color(hex: LabelPalette.defaultTagHex)
    }
}

extension LabelPalette {
    /// (Extra) Default color of new tags (matches `WorkTag.colorHex` default).
    static let defaultTagHex = "#8E8E93"

    /// (Extra) Symbols that suit a profile (a context of life or work), offered first when picking one.
    /// All available on macOS 14.
    static let profileSymbols: [String] = [
        "briefcase.fill", "house.fill", "person.fill", "graduationcap.fill", "building.2.fill",
        "hammer.fill", "heart.fill", "star.fill", "leaf.fill", "laptopcomputer"
    ]

    /// (Extra) `profileSymbols`, then every other `symbols` entry (no duplicates). For
    /// `SymbolPicker(symbolName:symbols:)` in profile editors.
    static let profileSymbolChoices: [String] =
        profileSymbols + symbols.filter { !profileSymbols.contains($0) }
}
