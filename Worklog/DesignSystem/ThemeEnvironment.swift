import SwiftUI

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .fallback
}

extension EnvironmentValues {
    /// The active theme. Default `Theme.fallback`. Injected by `worklogThemed(_:)`.
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

/// Which fill from the theme a background uses.
enum SurfaceLevel {
    case background, sidebar, surface, elevated, inset
}

// MARK: - View API

extension View {
    /// Reads @Environment(\.colorScheme), injects \.theme = manager.theme(for:), applies .tint(theme.accent)
    /// and the theme's body font as the default font.
    func worklogThemed(_ manager: ThemeManager) -> some View {
        WorklogThemeHost(manager: manager, content: self)
    }

    /// Fills the area behind the view (ignoring safe areas) with a theme surface.
    /// For `.background` and `.sidebar`, descendant List/Form/ScrollView backgrounds are hidden
    /// (`.scrollContentBackground(.hidden)`) so the theme shows through; opt a specific list back in
    /// with `.scrollContentBackground(.visible)`.
    func themedBackground(_ level: SurfaceLevel = .background) -> some View {
        modifier(ThemedBackgroundModifier(level: level))
    }

    /// surface fill + radiusM + border + shadow + padding(spacingL)
    func cardStyle() -> some View {
        modifier(CardSurfaceModifier(padding: nil))
    }

    /// (Extra) Background for the menu bar panel and the overlay: `theme.panelMaterial` when the theme
    /// uses materials (and Reduce Transparency is off), else `elevatedSurface`. Pass a corner radius for a floating rounded panel
    /// (overlay: `theme.radiusL`); nil fills a plain rectangle (menu bar window, which the system clips).
    func themedPanelBackground(cornerRadius: CGFloat? = nil) -> some View {
        modifier(PanelBackgroundModifier(cornerRadius: cornerRadius))
    }

    /// (Extra) Inset "well" look for text fields and composers: padding, insetSurface fill, radiusS,
    /// hairline border that turns accent while `isFocused`.
    func insetField(isFocused: Bool = false) -> some View {
        modifier(InsetFieldModifier(isFocused: isFocused))
    }
}

// MARK: - Implementation

private struct WorklogThemeHost<Content: View>: View {
    let manager: ThemeManager
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(manager: ThemeManager, content: Content) {
        self.manager = manager
        self.content = content
    }

    var body: some View {
        let theme = manager.theme(for: colorScheme)
        content
            .font(theme.bodyFont)
            .tint(theme.accent)
            .environment(\.theme, theme)
    }
}

private struct ThemedBackgroundModifier: ViewModifier {
    let level: SurfaceLevel
    @Environment(\.theme) private var theme

    init(level: SurfaceLevel) {
        self.level = level
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if level == .background || level == .sidebar {
                content.scrollContentBackground(.hidden)
            } else {
                content
            }
        }
        .background(theme.color(for: level).ignoresSafeArea())
    }
}

/// Shared by `Card` and `cardStyle()`.
struct CardSurfaceModifier: ViewModifier {
    var padding: CGFloat?
    @Environment(\.theme) private var theme

    init(padding: CGFloat?) {
        self.padding = padding
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        content
            .padding(padding ?? theme.spacingL)
            .background(shape.fill(theme.surface))
            .overlay {
                if theme.borderWidth > 0 {
                    shape.strokeBorder(theme.separator, lineWidth: theme.borderWidth)
                }
            }
            .shadow(color: theme.shadowColor, radius: theme.shadowRadius, x: 0, y: theme.shadowY)
    }
}

private struct PanelBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(cornerRadius: CGFloat?) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? 0, style: .continuous)
        content
            .background {
                if theme.usesMaterials && !reduceTransparency {
                    shape.fill(theme.panelMaterial)
                } else {
                    shape.fill(theme.elevatedSurface)
                }
            }
            .overlay {
                if cornerRadius != nil {
                    shape.strokeBorder(theme.separator.opacity(0.8), lineWidth: 1)
                }
            }
            .clipShape(shape)
    }
}

private struct InsetFieldModifier: ViewModifier {
    let isFocused: Bool
    @Environment(\.theme) private var theme

    init(isFocused: Bool) {
        self.isFocused = isFocused
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        content
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS + 2)
            .background(shape.fill(theme.insetSurface))
            .overlay {
                shape.strokeBorder(isFocused ? theme.accent.opacity(0.8) : theme.separator,
                                   lineWidth: isFocused ? 1.5 : 1)
            }
    }
}
