import SwiftUI
import AppKit

// MARK: - Font recipe (extra)

/// (Extra) The typographic personality of a theme: which `Font.Design` and weights each role uses,
/// plus the base sizes at text size `.standard`. `Theme.applyFonts(scale:)` turns a recipe into fonts.
/// Only system faces are used: SF Pro (`.default`), New York (`.serif`), SF Pro Rounded (`.rounded`)
/// and SF Mono (`.monospaced`).
struct ThemeFontRecipe {
    /// Large titles, titles, display numbers in stat tiles.
    var displayDesign: Font.Design
    var largeTitleWeight: Font.Weight
    var titleWeight: Font.Weight
    /// Headline, body, callout, caption.
    var textDesign: Font.Design
    /// Chips and badges.
    var labelDesign: Font.Design
    var labelWeight: Font.Weight
    /// Section headers.
    var sectionDesign: Font.Design
    var sectionWeight: Font.Weight
    var sectionSize: CGFloat
    /// Timers. Digits are always tabular (`monospacedDigit`).
    var timerDesign: Font.Design
    var timerHeroWeight: Font.Weight
    var timerWeight: Font.Weight
    var timerCompactWeight: Font.Weight
    var timerHeroSize: CGFloat
    var timerSize: CGFloat

    // Base sizes shared by all themes (macOS body = 13 pt).
    static let largeTitleSize: CGFloat = 28
    static let titleSize: CGFloat = 20
    static let headlineSize: CGFloat = 13
    static let bodySize: CGFloat = 13
    static let calloutSize: CGFloat = 12
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 11
    static let monoSize: CGFloat = 12
    static let timerMediumSize: CGFloat = 20
    static let timerCompactSize: CGFloat = 13
}

// MARK: - Theme

/// Every visual value used by the app. Read it with `@Environment(\.theme) private var theme`.
/// Build one with `Theme.make(_:colorScheme:accent:)`; never construct colors or fonts in feature code.
struct Theme {
    var id: ThemeID
    var colorScheme: ColorScheme

    // Surfaces
    var background: Color = Color(nsColor: .windowBackgroundColor)
    var sidebarBackground: Color = Color(nsColor: .underPageBackgroundColor)
    var surface: Color = Color(nsColor: .controlBackgroundColor)
    var elevatedSurface: Color = Color(nsColor: .windowBackgroundColor)
    var insetSurface: Color = Color(nsColor: .textBackgroundColor)

    // Text
    var textPrimary: Color = .primary
    var textSecondary: Color = .secondary
    var textTertiary: Color = Color(nsColor: .tertiaryLabelColor)

    // Accent & status
    var accent: Color = .accentColor
    var onAccent: Color = .white
    var separator: Color = Color(nsColor: .separatorColor)
    var success: Color = .green
    var warning: Color = .yellow
    var danger: Color = .red
    var timerRunning: Color = .primary
    var timerPaused: Color = .secondary
    var chartPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .gray]

    // Materials
    var panelMaterial: Material = .regular
    var usesMaterials: Bool = true

    // Typography
    var largeTitleFont: Font = .largeTitle
    var titleFont: Font = .title2
    var headlineFont: Font = .headline
    var bodyFont: Font = .body
    var calloutFont: Font = .callout
    var captionFont: Font = .caption
    var labelFont: Font = .caption
    var monoFont: Font = .system(.body, design: .monospaced)
    var timerHeroFont: Font = .system(size: 64, weight: .light).monospacedDigit()
    var timerFont: Font = .system(size: 32, weight: .regular).monospacedDigit()
    var timerCompactFont: Font = .system(size: 13, weight: .medium).monospacedDigit()

    // Shape
    var radiusS: CGFloat = 5
    var radiusM: CGFloat = 8
    var radiusL: CGFloat = 12
    var borderWidth: CGFloat = 1
    var shadowColor: Color = .clear
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0

    // Spacing
    var spacingXS: CGFloat = 4
    var spacingS: CGFloat = 8
    var spacingM: CGFloat = 12
    var spacingL: CGFloat = 16
    var spacingXL: CGFloat = 24
    var spacingXXL: CGFloat = 32

    // MARK: Extras (beyond the contract)

    /// (Extra) Font for `SectionHeader` titles.
    var sectionHeaderFont: Font = .headline
    /// (Extra) `SectionHeader` renders its title uppercased with tracking (instrument-label look).
    var sectionHeaderUppercased: Bool = false
    /// (Extra) `SectionHeader` draws a hairline rule after the title (editorial look).
    var sectionHeaderRuled: Bool = false
    /// (Extra) Timer between `timerFont` and `timerCompactFont` (TimerTextStyle.medium; ~20 pt).
    var timerMediumFont: Font = .system(size: 20, weight: .regular).monospacedDigit()
    /// (Extra) Display font for big numbers (StatTile values).
    var displayNumberFont: Font = .system(size: 22, weight: .semibold).monospacedDigit()
    /// (Extra) Corner radius of chips/badges; nil = capsule.
    var chipRadius: CGFloat? = nil
    /// (Extra) When true, `timerRunning` tracks the accent (also when the user overrides the accent).
    var timerUsesAccent: Bool = false
    /// (Extra) Opacity used to tint backgrounds with a label/status color (badges, banners).
    var tintOpacity: Double = 0.12
    /// (Extra) Recipe the fonts were built from; kept so text size can be re-applied.
    var fontRecipe: ThemeFontRecipe = ThemeFontRecipe(
        displayDesign: .default, largeTitleWeight: .semibold, titleWeight: .semibold,
        textDesign: .default, labelDesign: .default, labelWeight: .medium,
        sectionDesign: .default, sectionWeight: .semibold, sectionSize: 13,
        timerDesign: .default, timerHeroWeight: .light, timerWeight: .regular, timerCompactWeight: .medium,
        timerHeroSize: 64, timerSize: 32)
    /// (Extra) Text scale the fonts were built with (1 = standard).
    var textScale: CGFloat = 1

    /// Base theme with neutral system defaults. Theme factories start here and override everything.
    init(id: ThemeID, colorScheme: ColorScheme) {
        self.id = id
        self.colorScheme = colorScheme
    }

    // MARK: Factory

    static func make(_ id: ThemeID, colorScheme: ColorScheme, accent: AccentChoice = .themeDefault) -> Theme {
        make(id, colorScheme: colorScheme, accent: accent, textSize: .standard)
    }

    /// (Extra) Same as `make(_:colorScheme:accent:)` with an in-app text size applied.
    static func make(_ id: ThemeID, colorScheme: ColorScheme, accent: AccentChoice,
                     textSize: ThemeTextSize) -> Theme {
        var theme: Theme
        switch id {
        case .paper: theme = Theme.paper(colorScheme)
        case .graphite: theme = Theme.graphite(colorScheme)
        case .meadow: theme = Theme.meadow(colorScheme)
        }
        theme.applyAccent(accent)
        if textSize != .standard {
            theme.applyFonts(scale: textSize.scale)
        }
        return theme
    }

    static let fallback: Theme = .make(.paper, colorScheme: .light)
}

// MARK: - Helpers (extra)

extension Theme {
    var isDark: Bool { colorScheme == .dark }

    /// Fill for a `SurfaceLevel`.
    func color(for level: SurfaceLevel) -> Color {
        switch level {
        case .background: return background
        case .sidebar: return sidebarBackground
        case .surface: return surface
        case .elevated: return elevatedSurface
        case .inset: return insetSurface
        }
    }

    /// Shape used by chips, badges and pills (capsule when `chipRadius == nil`).
    var chipShape: AnyShape {
        if let r = chipRadius {
            return AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        }
        return AnyShape(Capsule(style: .continuous))
    }

    /// Color for chart series `index` (wraps around `chartPalette`).
    func chartColor(_ index: Int) -> Color {
        guard !chartPalette.isEmpty else { return accent }
        let i = ((index % chartPalette.count) + chartPalette.count) % chartPalette.count
        return chartPalette[i]
    }

    /// Rebuilds every font from `fontRecipe` at `scale` (1 = standard).
    mutating func applyFonts(scale: CGFloat) {
        let r = fontRecipe
        func s(_ size: CGFloat) -> CGFloat { (size * scale * 2).rounded() / 2 }
        typealias R = ThemeFontRecipe
        largeTitleFont = .system(size: s(R.largeTitleSize), weight: r.largeTitleWeight, design: r.displayDesign)
        titleFont = .system(size: s(R.titleSize), weight: r.titleWeight, design: r.displayDesign)
        headlineFont = .system(size: s(R.headlineSize), weight: .semibold, design: r.textDesign)
        bodyFont = .system(size: s(R.bodySize), weight: .regular, design: r.textDesign)
        calloutFont = .system(size: s(R.calloutSize), weight: .regular, design: r.textDesign)
        captionFont = .system(size: s(R.captionSize), weight: .regular, design: r.textDesign)
        labelFont = .system(size: s(R.labelSize), weight: r.labelWeight, design: r.labelDesign)
        monoFont = .system(size: s(R.monoSize), weight: .regular, design: .monospaced)
        sectionHeaderFont = .system(size: s(r.sectionSize), weight: r.sectionWeight, design: r.sectionDesign)
        timerHeroFont = .system(size: s(r.timerHeroSize), weight: r.timerHeroWeight, design: r.timerDesign).monospacedDigit()
        timerFont = .system(size: s(r.timerSize), weight: r.timerWeight, design: r.timerDesign).monospacedDigit()
        timerMediumFont = .system(size: s(R.timerMediumSize), weight: r.timerWeight, design: r.timerDesign).monospacedDigit()
        timerCompactFont = .system(size: s(R.timerCompactSize), weight: r.timerCompactWeight, design: r.timerDesign).monospacedDigit()
        displayNumberFont = .system(size: s(22), weight: r.titleWeight, design: r.displayDesign).monospacedDigit()
        textScale = scale
    }

    /// Applies a user accent override (no-op for `.themeDefault`). `onAccent` is white, or near-black for
    /// the light system accents (orange, yellow, green, graphite) where white text fails contrast.
    mutating func applyAccent(_ choice: AccentChoice) {
        guard let color = choice.color else { return }
        accent = color
        onAccent = choice.prefersDarkForeground ? Color(hex: "#111214") : .white
        if timerUsesAccent { timerRunning = color }
    }
}
