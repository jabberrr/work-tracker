import SwiftUI

/// A small card with a quiet title, a large tabular value and an optional caption.
/// Lay several out in a `LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: theme.spacingM)])`.
struct StatTile: View {
    @Environment(\.theme) private var theme
    private let title: String
    private let value: String
    private let systemImage: String?
    private let caption: String?

    init(title: String, value: String, systemImage: String? = nil, caption: String? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS + 2) {
            HStack(spacing: theme.spacingXS + 1) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                titleText
            }
            .font(theme.captionFont.weight(.medium))
            .lineLimit(1)

            Text(value)
                .font(theme.displayNumberFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurfaceModifier(padding: theme.spacingM + 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption.map { "\(value), \($0)" } ?? value)
    }

    @ViewBuilder private var titleText: some View {
        if theme.sectionHeaderUppercased {
            Text(title)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
        } else {
            Text(title)
                .foregroundStyle(theme.textSecondary)
        }
    }
}

#Preview("StatTile") {
    HStack {
        StatTile(title: "Total", value: "23h 40m", systemImage: "clock", caption: "Last 7 days")
        StatTile(title: "Streak", value: "5 days", systemImage: "flame")
    }
    .padding(24)
    .frame(width: 420)
}
