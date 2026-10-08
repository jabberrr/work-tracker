import SwiftUI

/// Settings ▸ Overlay: visibility, the layout editor (live preview + edit mode) and the panel's window options.
/// Wraps itself in a `SettingsPage` (760 pt, so the real-size preview has room).
@MainActor
struct SettingsOverlayTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(OverlayPanelController.self) private var overlay
    @Environment(SessionEngine.self) private var engine

    init() {}

    private var visibilityStatus: String {
        if !settings.overlayEnabled { return "Hidden" }
        if overlay.isVisible { return "Showing" }
        if settings.overlayHideWhenIdle && !engine.isActive { return "Appears when a session starts" }
        return "Showing"
    }

    var body: some View {
        @Bindable var settings = settings

        SettingsPage(maxWidth: 760) {
            Form {
                Section("Overlay") {
                    Toggle("Show overlay", isOn: $settings.overlayEnabled)
                    SettingsFootnote(visibilityStatus)
                    Toggle("Hide when idle", isOn: $settings.overlayHideWhenIdle)
                }

                Section("Layout") {
                    OverlayLayoutEditor()
                }

                Section("Window") {
                    Toggle("Compact", isOn: $settings.overlayCompact)
                    ValueSlider("Opacity", value: $settings.overlayOpacity, in: 0.4...1.0, step: 0.05,
                                format: { "\(Int(($0 * 100).rounded()))%" })
                    Toggle("Keep on top", isOn: $settings.overlayAlwaysOnTop)
                    Toggle("Show on all Spaces", isOn: $settings.overlayShowOnAllSpaces)
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { settings.resetOverlayDefaults() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
