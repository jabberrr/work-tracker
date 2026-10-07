import SwiftUI
import SwiftData

extension WorkLabel {
    /// Color(hex: colorHex)
    var color: Color { Color(hex: colorHex) }
}

extension WorkTag {
    /// Color(hex: colorHex)
    var color: Color { Color(hex: colorHex) }

    /// (Extra) True when the tag still has the default neutral color; chips then omit the color dot.
    var hasCustomColor: Bool {
        LabelPalette.normalized(colorHex) != LabelPalette.normalized(LabelPalette.defaultTagHex)
    }
}

extension LabelPalette {
    /// (Extra) Default color of new tags (matches `WorkTag.colorHex` default).
    static let defaultTagHex = "#8E8E93"
}
