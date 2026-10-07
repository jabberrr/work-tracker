import SwiftUI

/// Paper — editorial, ink on paper.
/// Near-white neutral paper (never cream), blue-black ink, a fountain-pen blue accent.
/// New York (serif) for display type and timers, SF Pro for running text. Hairline borders
/// instead of shadows; section headers sit on a thin rule like a printed page.
extension Theme {
    static func paper(_ scheme: ColorScheme) -> Theme {
        var t = Theme(id: .paper, colorScheme: scheme)
        let dark = scheme == .dark

        if dark {
            // Ink-dark "reading mode": neutral charcoal, never pure black.
            t.background = Color(hex: "#141517")
            t.sidebarBackground = Color(hex: "#101113")
            t.surface = Color(hex: "#1B1C1F")
            t.elevatedSurface = Color(hex: "#222428")
            t.insetSurface = Color(hex: "#0F1012")
            t.textPrimary = Color(hex: "#ECECEA")
            t.textSecondary = Color(hex: "#A5A9AF")
            t.textTertiary = Color(hex: "#71767D")
            t.accent = Color(hex: "#93A6FF")
            t.onAccent = Color(hex: "#0D1330")
            t.separator = Color(hex: "#2D3034")
            t.success = Color(hex: "#6CC28F")
            t.warning = Color(hex: "#E2B553")
            t.danger = Color(hex: "#F2766B")
            t.timerRunning = Color(hex: "#F2F2F0")
            t.timerPaused = Color(hex: "#71767D")
            t.shadowColor = .clear
        } else {
            t.background = Color(hex: "#FBFBFA")
            t.sidebarBackground = Color(hex: "#F1F2F3")
            t.surface = Color(hex: "#FFFFFF")
            t.elevatedSurface = Color(hex: "#FFFFFF")
            t.insetSurface = Color(hex: "#F3F4F5")
            t.textPrimary = Color(hex: "#15171A")
            t.textSecondary = Color(hex: "#555A62")
            t.textTertiary = Color(hex: "#7E838B")
            t.accent = Color(hex: "#2C44B8")
            t.onAccent = .white
            t.separator = Color(hex: "#E1E3E6")
            t.success = Color(hex: "#2F7D4F")
            t.warning = Color(hex: "#9A6400")
            t.danger = Color(hex: "#B3261E")
            t.timerRunning = Color(hex: "#15171A")
            t.timerPaused = Color(hex: "#7E838B")
            t.shadowColor = .clear
        }

        // Ink set: muted, distinguishable, holds up on both paper colors.
        t.chartPalette = [
            Color(hex: dark ? "#93A6FF" : "#2C44B8"),   // ink blue
            Color(hex: "#3F8F7E"),                        // verdigris
            Color(hex: "#C49A2E"),                        // ochre
            Color(hex: "#8062B3"),                        // violet ink
            Color(hex: "#4F8CC2"),                        // steel blue
            Color(hex: "#A4506F"),                        // plum
            Color(hex: "#7A8A3A"),                        // olive
            Color(hex: dark ? "#9AA1AA" : "#5E6670"),   // slate
            Color(hex: "#2F9AA0"),                        // cyan ink
            Color(hex: "#B0605A")                         // madder
        ]

        t.panelMaterial = .thick
        t.usesMaterials = true

        t.radiusS = 4
        t.radiusM = 6
        t.radiusL = 10
        t.borderWidth = 1
        t.shadowRadius = 0
        t.shadowY = 0
        t.chipRadius = 4
        t.tintOpacity = dark ? 0.18 : 0.10

        t.sectionHeaderUppercased = false
        t.sectionHeaderRuled = true
        t.timerUsesAccent = false

        t.fontRecipe = ThemeFontRecipe(
            displayDesign: .serif, largeTitleWeight: .medium, titleWeight: .medium,
            textDesign: .default, labelDesign: .default, labelWeight: .medium,
            sectionDesign: .serif, sectionWeight: .semibold, sectionSize: 15,
            timerDesign: .serif, timerHeroWeight: .light, timerWeight: .regular, timerCompactWeight: .medium,
            timerHeroSize: 68, timerSize: 34)
        t.applyFonts(scale: 1)
        return t
    }
}
