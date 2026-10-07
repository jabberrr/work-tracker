import SwiftUI

/// A small filled circle in a label/tag color, with a faint ring so very light or very dark colors
/// stay visible on any surface. Decorative: hidden from VoiceOver (pair it with text).
struct ColorDot: View {
    @Environment(\.theme) private var theme
    private let hex: String
    private let size: CGFloat

    init(hex: String, size: CGFloat = 8) {
        self.hex = hex
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .overlay(Circle().strokeBorder(theme.textPrimary.opacity(0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
