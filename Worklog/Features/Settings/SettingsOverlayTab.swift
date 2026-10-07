import SwiftUI

/// Overlay & Menu Bar: every overlay content/appearance option, visibility, and the menu bar extra options.
struct SettingsOverlayTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(OverlayPanelController.self) private var overlay
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    private var visibilityStatus: String {
        if !settings.overlayEnabled { return "Hidden. Turn it on here, from the menu bar panel or with ⌘⇧O." }
        if overlay.isVisible { return "Showing now. Drag it by its background to move it." }
        if settings.overlayHideWhenIdle && !engine.isActive { return "Turned on — it appears when a session starts." }
        return "Turned on."
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Floating overlay") {
                Toggle("Show floating overlay", isOn: $settings.overlayEnabled)
                    .help("Takes effect immediately (⌘⇧O)")
                SettingsFootnote(visibilityStatus)
                Toggle("Hide while no session is running", isOn: $settings.overlayHideWhenIdle)
            }

            Section("Overlay shows") {
                Toggle("Timer", isOn: $settings.overlayShowTimer)
                Toggle("Label", isOn: $settings.overlayShowLabel)
                Toggle("Segment focus", isOn: $settings.overlayShowSegmentFocus)
                Toggle("Start, pause and stop buttons", isOn: $settings.overlayShowControls)
                Toggle("Split button", isOn: $settings.overlayShowSplitButton)
                    .disabled(!settings.overlayShowControls)
                    .padding(.leading, theme.spacingL)
                Toggle("Quick note field", isOn: $settings.overlayShowNoteField)
                Toggle("Last takeaway", isOn: $settings.overlayShowLastTakeaway)
                Toggle("Today’s total", isOn: $settings.overlayShowTodayTotal)
            }

            Section("Overlay window") {
                Toggle("Compact layout", isOn: $settings.overlayCompact)
                LabeledContent("Opacity") {
                    HStack(spacing: theme.spacingS) {
                        Slider(value: $settings.overlayOpacity, in: 0.4...1.0, step: 0.05) {
                            Text("Opacity")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .accessibilityValue(Self.percent(settings.overlayOpacity))
                        Text(Self.percent(settings.overlayOpacity))
                            .font(theme.monoFont)
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                Toggle("Keep above other windows", isOn: $settings.overlayAlwaysOnTop)
                Toggle("Show on all Spaces and over full-screen apps", isOn: $settings.overlayShowOnAllSpaces)
                HStack {
                    Spacer()
                    Button("Restore Overlay Defaults") { settings.resetOverlayDefaults() }
                        .buttonStyle(QuietButtonStyle())
                        .help("Resets what the overlay shows and how it looks. Visibility is unchanged.")
                }
            }

            Section("Menu bar") {
                Toggle("Show Worklog in the menu bar", isOn: $settings.showMenuBarExtra)
                Toggle("Show the running timer next to the icon", isOn: $settings.menuBarShowsTimer)
                    .disabled(!settings.showMenuBarExtra)
                Toggle("Show the last takeaway in the menu bar panel", isOn: $settings.menuBarShowLastTakeaway)
                    .disabled(!settings.showMenuBarExtra)
                if !settings.showMenuBarExtra {
                    SettingsFootnote("Without the menu bar item, use the main window, the overlay or the Session menu (⌘⇧S, ⌘⇧P).")
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
