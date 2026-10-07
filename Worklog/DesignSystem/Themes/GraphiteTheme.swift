import SwiftUI

/// Graphite — an instrument panel.
/// Cool aluminium greys (light) or near-black anodised panels (dark), one signal-cyan accent that
/// the running timer also uses, SF Mono readouts, uppercase tracked section labels on a rule,
/// tight radii, solid (non-translucent) panels for deterministic contrast.
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
            t.background = Color(hex: "#E8E9EB")
            t.sidebarBackground = Color(hex: "#DEE0E3")
            t.surface = Color(hex: "#F3F4F5")
            t.elevatedSurface = Color(hex: "#F8F9FA")
            t.insetSurface = Color(hex: "#E0E2E5")
            t.textPrimary = Color(hex: "#16181B")
            t.textSecondary = Color(hex: "#4C5158")
            t.textTertiary = Color(hex: "#71767E")
            t.accent = Color(hex: "#08707C")
            t.onAccent = .white
            t.separator = Color(hex: "#C6C9CE")
            t.success = Color(hex: "#246B34")
            t.warning = Color(hex: "#805400")
            t.danger = Color(hex: "#AC2D24")
            t.timerPaused = Color(hex: "#805400")
        }
        t.timerUsesAccent = true
        t.timerRunning = t.accent
        t.shadowColor = .clear

        // Signal set: mid-tone, high separation, readable on both panels.
        t.chartPalette = [
            Color(hex: dark ? "#35C6D4" : "#08707C"),   // signal cyan
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
            textDesign: .default, labelDesign: .monospaced, labelWeight: .medium,
            sectionDesign: .monospaced, sectionWeight: .semibold, sectionSize: 10.5,
            timerDesign: .monospaced, timerHeroWeight: .light, timerWeight: .regular, timerCompactWeight: .medium,
            timerHeroSize: 60, timerSize: 30)
        t.applyFonts(scale: 1)
        return t
    }
}
