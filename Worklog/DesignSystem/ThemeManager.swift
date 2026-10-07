import SwiftUI
import AppKit
import Observation

/// Owns the user's visual preferences (theme, appearance, accent, text size) and builds `Theme`s.
/// Injected by `withAppServices`; read with `@Environment(ThemeManager.self)`.
@MainActor @Observable
final class ThemeManager {
    private enum Keys {
        static let themeID = "appearance.themeID"
        static let mode = "appearance.mode"
        static let accent = "appearance.accent"
        static let textSize = "appearance.textSize"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Key "appearance.themeID", default `ThemeID.default` (`.graphite`).
    var themeID: ThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Keys.themeID) }
    }

    /// Key "appearance.mode", default `.system`. Setting it applies the appearance app-wide.
    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.mode)
            applyAppearance()
        }
    }

    /// Key "appearance.accent", default `.themeDefault`.
    var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    /// (Extra) Key "appearance.textSize", default `.standard`. Scales every theme font.
    var textSize: ThemeTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Keys.textSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themeID = defaults.string(forKey: Keys.themeID).flatMap(ThemeID.init(rawValue:)) ?? .default
        self.appearance = defaults.string(forKey: Keys.mode).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.accent = defaults.string(forKey: Keys.accent).flatMap(AccentChoice.init(rawValue:)) ?? .themeDefault
        self.textSize = defaults.string(forKey: Keys.textSize).flatMap(ThemeTextSize.init(rawValue:)) ?? .standard
    }

    /// The fully resolved theme (accent + text size applied) for a color scheme.
    func theme(for colorScheme: ColorScheme) -> Theme {
        Theme.make(themeID, colorScheme: colorScheme, accent: accent, textSize: textSize)
    }

    /// NSApplication.shared.appearance = appearance.nsAppearance (affects all windows, menu bar panel, overlay).
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// (Extra) Restores theme, appearance, accent and text size to their defaults.
    func resetToDefaults() {
        themeID = .default
        appearance = .system
        accent = .themeDefault
        textSize = .standard
    }
}
