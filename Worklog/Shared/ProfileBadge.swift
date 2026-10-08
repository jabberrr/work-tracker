import SwiftUI
import SwiftData

/// A profile's SF Symbol in the profile color + its name. Deliberately not a chip (no fill, no outline), so it
/// never reads as a `LabelBadge`. `nil` (or a deleted profile) → "No profile" with a dashed-circle symbol.
///
/// Sizes: `.small` (rows, headers, menu bar) = `captionFont`, `textSecondary`, 10 pt symbol; `.regular` =
/// `calloutFont`, `textPrimary`; `.large` = `headlineFont`, `textPrimary`. One line, tail truncation.
/// VoiceOver: label "Profile", value = the name.
struct ProfileBadge: View {
    @Environment(\.theme) private var theme
    private let source: Source
    private let size: BadgeSize

    private enum Source {
        case model(WorkProfile?)
        case values(name: String, colorHex: String, symbolName: String)
    }

    init(profile: WorkProfile?, size: BadgeSize = .small) {
        self.source = .model(profile)
        self.size = size
    }

    /// For value snapshots (overlay data, popovers) that must not hold a model.
    init(name: String, colorHex: String, symbolName: String, size: BadgeSize = .small) {
        self.source = .values(name: name, colorHex: colorHex, symbolName: symbolName)
        self.size = size
    }

    /// (name, tint, symbol); tint nil = no profile. Resolved in `body`, so a deleted profile is never read.
    private var resolved: (name: String, tint: Color?, symbol: String) {
        switch source {
        case .model(let profile):
            guard let profile = ModelLiveness.live(profile) else {
                return ("No profile", nil, "circle.dashed")
            }
            return (profile.displayName, profile.color, ProfileBadge.symbol(profile.symbolName))
        case .values(let name, let colorHex, let symbolName):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? "Untitled profile" : trimmed, Color(hex: colorHex),
                    ProfileBadge.symbol(symbolName))
        }
    }

    var body: some View {
        let info = resolved
        HStack(spacing: iconSpacing) {
            Image(systemName: info.symbol)
                .font(.system(size: iconSize * theme.textScale, weight: .semibold))
                .foregroundStyle(info.tint ?? theme.textTertiary)
                .accessibilityHidden(true)
            Text(verbatim: info.name)
                .font(textFont)
                .foregroundStyle(info.tint == nil || size == .small ? theme.textSecondary : theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile")
        .accessibilityValue(info.name)
    }

    /// A blank symbol name falls back to the default profile symbol.
    private static func symbol(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "briefcase.fill" : name
    }

    private var iconSize: CGFloat {
        switch size {
        case .small: return 10
        case .regular: return 12
        case .large: return 14
        }
    }

    private var textFont: Font {
        switch size {
        case .small: return theme.captionFont
        case .regular: return theme.calloutFont
        case .large: return theme.headlineFont
        }
    }

    private var iconSpacing: CGFloat {
        switch size {
        case .small: return 4
        case .regular: return 5
        case .large: return 6
        }
    }
}

/// (Extra, round 3) The profile "tile": a rounded square (`radiusS`) filled with the profile color at 18 %
/// opacity, the symbol in the profile color. Used by `ProfileSwitcher` and the Settings ▸ Profiles list.
/// Pass values (not a model) so it can live in popovers. Decorative: hidden from VoiceOver.
struct ProfileSymbolTile: View {
    @Environment(\.theme) private var theme
    private let colorHex: String
    private let symbolName: String
    private let side: CGFloat

    init(colorHex: String, symbolName: String, side: CGFloat = 18) {
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.side = side
    }

    /// Convenience for a live profile; a nil/deleted profile draws a neutral dashed tile.
    init(profile: WorkProfile?, side: CGFloat = 18) {
        if let profile = ModelLiveness.live(profile) {
            self.colorHex = profile.colorHex
            self.symbolName = profile.symbolName
        } else {
            self.colorHex = LabelPalette.defaultTagHex
            self.symbolName = "circle.dashed"
        }
        self.side = side
    }

    var body: some View {
        let tint = Color(hex: colorHex)
        let symbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "briefcase.fill" : symbolName
        RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
            .fill(tint.opacity(0.18))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.55, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

#Preview("Profile badges") {
    VStack(alignment: .leading, spacing: 8) {
        ProfileBadge(name: "Work", colorHex: "#5B8DEF", symbolName: "briefcase.fill")
        ProfileBadge(name: "Personal", colorHex: "#27AE60", symbolName: "house.fill", size: .regular)
        ProfileBadge(name: "A very long profile name that truncates", colorHex: "#9B51E0",
                     symbolName: "star.fill", size: .large)
        ProfileBadge(profile: nil)
        HStack {
            ProfileSymbolTile(colorHex: "#5B8DEF", symbolName: "briefcase.fill")
            ProfileSymbolTile(colorHex: "#27AE60", symbolName: "house.fill")
        }
    }
    .padding()
    .frame(width: 220)
}
