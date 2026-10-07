import SwiftUI

/// A section title with an optional leading symbol and trailing accessory (buttons, counts, menus).
/// Each theme styles it differently:
/// - Paper: serif semibold title followed by a hairline rule.
/// - Graphite: UPPERCASE tracked SF Mono label followed by a rule.
/// - Meadow: rounded semibold title, no rule.
struct SectionHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    private let title: String
    private let systemImage: String?
    private let trailing: Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: theme.spacingS) {
            HStack(spacing: theme.spacingXS + 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(theme.captionFont.weight(.semibold))
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                titleText
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if theme.sectionHeaderRuled {
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: theme.spacingS)
            }
            trailing
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.bottom, theme.spacingXS)
    }

    @ViewBuilder private var titleText: some View {
        if theme.sectionHeaderUppercased {
            Text(title)
                .font(theme.sectionHeaderFont)
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(theme.textSecondary)
        } else {
            Text(title)
                .font(theme.sectionHeaderFont)
                .foregroundStyle(theme.textPrimary)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

#Preview("SectionHeader") {
    VStack(alignment: .leading, spacing: 20) {
        SectionHeader("Notes", systemImage: "note.text")
        SectionHeader("Segments") { Text("3") }
    }
    .padding(24)
    .frame(width: 420)
}
