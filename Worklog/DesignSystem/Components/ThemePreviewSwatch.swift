import SwiftUI

/// A miniature of a theme for the Appearance settings grid: a light and a dark half, each with a
/// sidebar strip, a display-face "Aa", a timer readout in the theme's timer face and an accent pill;
/// below, the theme name and summary. Selected → accent ring + checkmark.
///
/// `compact: true` (Welcome screen): 124 pt wide, one preview in the current appearance, name only
/// (VoiceOver still reads the summary as the value).
///
/// Not interactive by itself: wrap it in `Button { manager.themeID = id } label: { ThemePreviewSwatch(…) }
/// .buttonStyle(.plain)` — or use `ThemeSwatchRow`, which does that for every theme.
struct ThemePreviewSwatch: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var manager: ThemeManager?
    private let themeID: ThemeID
    private let isSelected: Bool
    private let compact: Bool

    init(themeID: ThemeID, isSelected: Bool, compact: Bool = false) {
        self.themeID = themeID
        self.isSelected = isSelected
        self.compact = compact
    }

    var body: some View {
        let accent = manager?.accent ?? .themeDefault
        let light = Theme.make(themeID, colorScheme: .light, accent: accent)
        let dark = Theme.make(themeID, colorScheme: .dark, accent: accent)
        let frameShape = RoundedRectangle(cornerRadius: theme.radiusM + 2, style: .continuous)

        VStack(alignment: .leading, spacing: compact ? theme.spacingXS + 2 : theme.spacingS) {
            HStack(spacing: 0) {
                if compact {
                    ThemeMiniPreview(preview: colorScheme == .dark ? dark : light)
                } else {
                    ThemeMiniPreview(preview: light)
                        .environment(\.colorScheme, .light)
                    ThemeMiniPreview(preview: dark)
                        .environment(\.colorScheme, .dark)
                }
            }
            .frame(height: compact ? 64 : 92)
            .clipShape(frameShape)
            .overlay {
                frameShape.strokeBorder(isSelected ? theme.accent : theme.separator,
                                        lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(theme.onAccent, theme.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(themeID.displayName)
                    .font(compact ? theme.calloutFont.weight(.semibold) : theme.headlineFont)
                    .foregroundStyle(isSelected && compact ? theme.accent : theme.textPrimary)
                if !compact {
                    Text(themeID.summary)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: compact ? 124 : 196)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(themeID.displayName) theme")
        .accessibilityValue(themeID.summary)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits([.isSelected, .isButton]) : AccessibilityTraits.isButton)
    }
}

/// One half of the swatch, drawn entirely from `preview` (never from the environment theme).
private struct ThemeMiniPreview: View {
    let preview: Theme

    var body: some View {
        let r = preview.fontRecipe
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(preview.accent).frame(width: 14, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(preview.textTertiary.opacity(0.6)).frame(width: 12, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(preview.textTertiary.opacity(0.6)).frame(width: 15, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 5)
            .frame(width: 26)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(preview.sidebarBackground)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aa")
                    .font(.system(size: 13, weight: r.titleWeight, design: r.displayDesign))
                    .foregroundStyle(preview.textPrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("1:24:07")
                        .font(.system(size: 13, weight: r.timerWeight, design: r.timerDesign).monospacedDigit())
                        .foregroundStyle(preview.timerRunning)
                    HStack(spacing: 3) {
                        Capsule().fill(preview.accent).frame(width: 18, height: 5)
                        Capsule().fill(preview.textTertiary.opacity(0.5)).frame(width: 12, height: 5)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: min(preview.radiusM, 6), style: .continuous)
                        .fill(preview.surface)
                )
                .overlay {
                    if preview.borderWidth > 0 {
                        RoundedRectangle(cornerRadius: min(preview.radiusM, 6), style: .continuous)
                            .strokeBorder(preview.separator, lineWidth: 0.5)
                    }
                }
                .shadow(color: preview.shadowColor, radius: preview.shadowRadius / 3, x: 0, y: 1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(preview.background)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
