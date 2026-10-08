import SwiftData
import SwiftUI

/// General: session defaults, takeaway lifetime, automatic pausing, the "still working?" warning, daily goal,
/// week start, the menu bar item and the Dock icon.
@MainActor
struct SettingsGeneralTab: View {
    @Environment(AppSettings.self) private var settings
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    /// Maps `settings.defaultLabelID` ⇄ the label object for `LabelPicker`.
    private var defaultLabel: Binding<WorkLabel?> {
        Binding(
            get: {
                guard let id = settings.defaultLabelID else { return nil }
                return labels.first { $0.uuid == id }
            },
            set: { settings.defaultLabelID = $0?.uuid }
        )
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("New sessions") {
                LabelPicker(selection: defaultLabel, includeNone: true, title: "Default label")
                SettingsFootnote("“None” uses your first label.")
                Toggle("Review when a session ends", isOn: $settings.showEndSessionSheet)
                Toggle("Ask before discarding", isOn: $settings.confirmBeforeDiscard)
            }

            Section("Takeaway") {
                Toggle("Show only in the next session", isOn: $settings.takeawayNextSessionOnly)
                SettingsFootnote(settings.takeawayNextSessionOnly
                                 ? "Shown until the next session’s review."
                                 : "Shown until replaced or marked done.")
            }

            Section("Automatic pausing") {
                Toggle("Pause when the Mac sleeps", isOn: $settings.pauseOnSleep)
                Toggle("Pause when Worklog quits", isOn: $settings.pauseOnQuit)
                SettingsFootnote("Worklog never resumes on its own.")
                ValueStepper("Ask “Still working?” after", value: $settings.longSessionWarningHours,
                             in: 1...24, step: 1, format: Self.hoursPhrase)
            }

            Section("Goals & calendar") {
                ValueStepper("Daily goal", value: $settings.dailyGoalHours, in: 0...16, step: 0.5,
                             format: { $0 > 0 ? StatsView.hoursText($0) : "Off" })
                ValuePicker("Week starts on", selection: $settings.weekStartsOnMonday, options: [true, false],
                            title: { $0 ? "Monday" : "Sunday" })
            }

            Section("Menu bar") {
                Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)
                Toggle("Show timer", isOn: $settings.menuBarShowsTimer)
                    .disabled(!settings.showMenuBarExtra)
                Toggle("Show takeaway", isOn: $settings.menuBarShowLastTakeaway)
                    .disabled(!settings.showMenuBarExtra)
            }

            Section("Dock") {
                Toggle("Hide Dock icon when the window closes", isOn: $settings.hideDockIconWhenClosed)
                if settings.hideDockIconWhenClosed {
                    SettingsFootnote(settings.showMenuBarExtra
                                     ? "Reopen the window from the menu bar."
                                     : "Reopen Worklog from Applications or Spotlight.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "10 hours". Nonisolated so it can be passed as `ValueStepper`'s format.
    nonisolated private static func hoursPhrase(_ hours: Double) -> String {
        let whole = Int(hours.rounded())
        return "\(whole) \(whole == 1 ? "hour" : "hours")"
    }
}
