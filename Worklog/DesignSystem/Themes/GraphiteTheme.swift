import SwiftUI

/// Graphite — a precise instrument (the default theme).
/// Crisp neutral white panels on a barely-grey ground (light) or near-black anodised panels (dark),
/// SF Pro for all running text, SF Mono only for readouts (timers, small uppercase section labels on
/// a rule), one teal signal accent that the running timer also uses, tight radii, hairline borders,
/// no shadows, solid (non-translucent) panels for deterministic contrast.
extension Theme {
    static func graphite(_ scheme: ColorScheme) -> Theme {
        var t = Theme(id: .graphite, colorScheme: scheme)
        let dark = scheme == .dark

        if dark {
            t.background = Color(hex: "#121315")
            t.sidebarBackground = Color(hex: "#0D0E10")
            t.surface = Color(hex: "#1A1C1F")
            t.elevatedSurface = Color(hex: "#202327")
            t.insetSurface = Color(hex: "#0A0B0D")
            t.textPrimary = Color(hex: "#E6E8EB")
            t.textSecondary = Color(hex: "#9DA3AB")
            t.textTertiary = Color(hex: "#676D75")
            t.accent = Color(hex: "#35C6D4")
            t.onAccent = Color(hex: "#03181B")
            t.separator = Color(hex: "#2A2D32")
            t.success = Color(hex: "#5BD08A")
            t.warning = Color(hex: "#E3B341")
            t.danger = Color(hex: "#FF6B5E")
            t.timerPaused = Color(hex: "#E3B341")
        } else {
            // Crisp neutral: white cards on a barely-grey ground, cool hairlines.
            t.background = Color(hex: "#F6F7F8")
            t.sidebarBackground = Color(hex: "#EEF0F2")
            t.surface = Color(hex: "#FFFFFF")
            t.elevatedSurface = Color(hex: "#FFFFFF")
            t.insetSurface = Color(hex: "#F0F2F4")
            t.textPrimary = Color(hex: "#15171A")
            t.textSecondary = Color(hex: "#4E545C")
            t.textTertiary = Color(hex: "#6B7179")
            t.accent = Color(hex: "#0B6C78")
            t.onAccent = .white
            t.separator = Color(hex: "#DADDE1")
            t.success = Color(hex: "#22703A")
            t.warning = Color(hex: "#8A5700")
            t.danger = Color(hex: "#B42318")
            t.timerPaused = Color(hex: "#8A5700")
        }
        t.timerUsesAccent = true
        t.timerRunning = t.accent
        t.shadowColor = .clear

        // Signal set: mid-tone, high separation, readable on both panels.
        t.chartPalette = [
            Color(hex: dark ? "#35C6D4" : "#0B6C78"),   // signal teal
            Color(hex: "#D9A441"),                        // amber
            Color(hex: "#7C8CF0"),                        // periwinkle
            Color(hex: "#5BB974"),                        // green
            Color(hex: "#E06C75"),                        // soft red
            Color(hex: "#B48EAD"),                        // mauve
            Color(hex: "#8FA1B3"),                        // steel
            Color(hex: "#C8B560"),                        // khaki
            Color(hex: "#4FA3E0"),                        // blue
            Color(hex: "#A3BE8C")                         // sage
        ]

        t.panelMaterial = .thick
        t.usesMaterials = false

        t.radiusS = 3
        t.radiusM = 5
        t.radiusL = 8
        t.borderWidth = 1
        t.shadowRadius = 0
        t.shadowY = 0
        t.chipRadius = 3
        t.tintOpacity = dark ? 0.16 : 0.12

        t.sectionHeaderUppercased = true
        t.sectionHeaderRuled = true

        t.fontRecipe = ThemeFontRecipe(
            displayDesign: .default, largeTitleWeight: .semibold, titleWeight: .semibold,
            textDesign: .default, labelDesign: .default, labelWeight: .medium,
            sectionDesign: .monospaced, sectionWeight: .semibold, sectionSize: 10.5,
            timerDesign: .monospaced, timerHeroWeight: .light, timerWeight: .regular, timerCompactWeight: .medium,
            timerHeroSize: 60, timerSize: 30)
        t.applyFonts(scale: 1)
        return t
    }
}
