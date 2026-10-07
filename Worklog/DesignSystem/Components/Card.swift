import SwiftUI

/// A themed container: surface fill, radiusM, hairline border (themes with borders), soft shadow
/// (themes with shadows). Fills the available width and aligns content leading.
struct Card<Content: View>: View {
    private let padding: CGFloat?
    private let content: Content

    /// `padding` nil → `theme.spacingL`.
    init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurfaceModifier(padding: padding))
    }
}

#Preview("Card") {
    VStack(spacing: 16) {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last takeaway").font(Theme.fallback.headlineFont)
                Text("Batch the review comments before replying.").font(Theme.fallback.bodyFont)
            }
        }
        Text("Card style modifier").cardStyle()
    }
    .padding(24)
    .frame(width: 360)
    .themedBackground()
}
