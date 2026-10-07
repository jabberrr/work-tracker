import SwiftUI

/// Meadow — soft, natural, unhurried.
/// Pale sage paper (light) or deep forest (dark), moss-green accent, SF Pro Rounded for display
/// type and timers, larger radii, borderless cards lifted by a very soft shadow, capsule chips.
extension Theme {
    static func meadow(_ scheme: ColorScheme) -> Theme {
        var t = Theme(id: .meadow, colorScheme: scheme)
        let dark = scheme == .dark

        if dark {
            t.background = Color(hex: "#111612")
            t.sidebarBackground = Color(hex: "#0D110E")
            t.surface = Color(hex: "#182019")
            t.elevatedSurface = Color(hex: "#1E2720")
            t.insetSurface = Color(hex: "#0C100D")
            t.textPrimary = Color(hex: "#E4EBE5")
            t.textSecondary = Color(hex: "#A2B0A6")
            t.textTertiary = Color(hex: "#6D7B71")
            t.accent = Color(hex: "#7DC79B")
            t.onAccent = Color(hex: "#0A1E12")
            t.separator = Color(hex: "#27322A")
            t.success = Color(hex: "#7DC79B")
            t.warning = Color(hex: "#DCC274")
            t.danger = Color(hex: "#F07A86")
            t.timerRunning = Color(hex: "#CFE9D8")
            t.timerPaused = Color(hex: "#6D7B71")
            t.shadowColor = Color.black.opacity(0.35)
        } else {
            t.background = Color(hex: "#F3F6F2")
            t.sidebarBackground = Color(hex: "#E8EEE7")
            t.surface = Color(hex: "#FCFDFB")
            t.elevatedSurface = Color(hex: "#FFFFFF")
            t.insetSurface = Color(hex: "#ECF0EB")
            t.textPrimary = Color(hex: "#18221C")
            t.textSecondary = Color(hex: "#4E5C53")
            t.textTertiary = Color(hex: "#738078")
            t.accent = Color(hex: "#346E4E")
            t.onAccent = .white
            t.separator = Color(hex: "#D6DFD7")
            t.success = Color(hex: "#277443")
            t.warning = Color(hex: "#79600F")
            t.danger = Color(hex: "#B42D3C")
            t.timerRunning = Color(hex: "#21492F")
            t.timerPaused = Color(hex: "#738078")
            t.shadowColor = Color(hex: "#1E3A28").opacity(0.07)
        }

        // Field-guide set: natural pigments, calm saturation.
        t.chartPalette = [
            Color(hex: dark ? "#7DC79B" : "#346E4E"),   // moss
            Color(hex: "#5B8FB9"),                        // lake
            Color(hex: "#C9A227"),                        // pollen
            Color(hex: "#8C6BB1"),                        // heather
            Color(hex: "#4FA39A"),                        // teal
            Color(hex: "#C25B6E"),                        // rosehip
            Color(hex: "#A3B86C"),                        // lichen
            Color(hex: "#7A8F9E"),                        // slate
            Color(hex: "#B08D57"),                        // bark
            Color(hex: "#6E9FD0")                         // sky
        ]

        t.panelMaterial = .regular
        t.usesMaterials = true

        t.radiusS = 6
        t.radiusM = 12
        t.radiusL = 18
        t.borderWidth = 0
        t.shadowRadius = 10
        t.shadowY = 2
        t.chipRadius = nil   // capsules
        t.tintOpacity = dark ? 0.18 : 0.13

        t.sectionHeaderUppercased = false
        t.sectionHeaderRuled = false
        t.timerUsesAccent = false

        t.fontRecipe = ThemeFontRecipe(
            displayDesign: .rounded, largeTitleWeight: .semibold, titleWeight: .semibold,
            textDesign: .default, labelDesign: .rounded, labelWeight: .medium,
            sectionDesign: .rounded, sectionWeight: .semibold, sectionSize: 14,
            timerDesign: .rounded, timerHeroWeight: .light, timerWeight: .regular, timerCompactWeight: .medium,
            timerHeroSize: 64, timerSize: 32)
        t.applyFonts(scale: 1)
        return t
    }
}
