import SwiftUI

/// A row of compact `ThemePreviewSwatch`es, one per `ThemeID`, that switches the theme on click.
/// Reads `ThemeManager` from the environment (injected by `withAppServices`); renders nothing without it.
///
///     ThemeSwatchRow()                 // Welcome screen: compact, ~396 pt wide
///     ThemeSwatchRow(compact: false)   // full swatches with summaries (~612 pt wide)
@MainActor
struct ThemeSwatchRow: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeManager.self) private var manager: ThemeManager?
    private let compact: Bool

    init(compact: Bool = true) {
        self.compact = compact
    }

    var body: some View {
        if let manager {
            HStack(alignment: .top, spacing: theme.spacingM) {
                ForEach(ThemeID.allCases) { id in
                    Button {
                        manager.themeID = id
                    } label: {
                        ThemePreviewSwatch(themeID: id, isSelected: manager.themeID == id, compact: compact)
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")
        }
    }
}
