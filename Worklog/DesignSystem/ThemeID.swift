import SwiftUI
import AppKit

// MARK: - ThemeID

/// The selectable visual styles. Add a new style by adding a case here, a factory in `Themes/`,
/// and one line in `Theme.make` (see docs/DESIGN.md, "Adding a theme").
enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case paper, graphite, meadow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .graphite: return "Graphite"
        case .meadow: return "Meadow"
        }
    }

    /// One-line description for Settings.
    var summary: String {
        switch self {
        case .paper: return "Ink on paper. Serif headings, hairline rules, no shadows."
        case .graphite: return "An instrument panel. Monospaced readouts and a signal-cyan accent."
        case .meadow: return "Soft greens and rounded type. Gentle depth for long days."
        }
    }

    /// (Extra) SF Symbol that represents the theme in compact UI.
    var systemImage: String {
        switch self {
        case .paper: return "doc.plaintext"
        case .graphite: return "gauge.with.dots.needle.33percent"
        case .meadow: return "leaf"
        }
    }
}

// MARK: - AppearanceMode

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// (Extra) SF Symbol for segmented pickers.
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

// MARK: - AccentChoice

enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case themeDefault, blue, purple, pink, red, orange, yellow, green, graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .themeDefault: return "Theme Default"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .graphite: return "Graphite"
        }
    }

    /// nil for `.themeDefault`. These are the dynamic system colors, so they adapt to light/dark.
    var color: Color? {
        nsColor.map { Color(nsColor: $0) }
    }

    /// (Extra) The AppKit color behind `color`; nil for `.themeDefault`.
    var nsColor: NSColor? {
        switch self {
        case .themeDefault: return nil
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }

    /// (Extra) True when text/icons on this accent should be dark rather than white
    /// (white on these system colors is below 3:1 in light and dark appearance).
    var prefersDarkForeground: Bool {
        switch self {
        case .orange, .yellow, .green, .graphite: return true
        case .themeDefault, .blue, .purple, .pink, .red: return false
        }
    }
}

// MARK: - ThemeTextSize (extra)

/// (Extra) In-app text size. macOS has no Dynamic Type, so every theme font is built from a
/// base size multiplied by `scale`. Owned by `ThemeManager.textSize` (key "appearance.textSize").
enum ThemeTextSize: String, CaseIterable, Identifiable, Codable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.92
        case .standard: return 1.0
        case .large: return 1.12
        case .extraLarge: return 1.25
        }
    }
}
