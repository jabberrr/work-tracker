import SwiftData
import SwiftUI

/// General: session defaults, automatic pausing, the "still working?" warning, daily goal and week start.
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
                SettingsFootnote("Used when you start from the menu bar, the overlay or ⌘⇧S. “None” uses the first label in your list.")
                Toggle("Show the review sheet when a session ends", isOn: $settings.showEndSessionSheet)
                Toggle("Ask before discarding a running session", isOn: $settings.confirmBeforeDiscard)
            }

            Section("Automatic pausing") {
                Toggle("Pause when the Mac goes to sleep", isOn: $settings.pauseOnSleep)
                Toggle("Pause when Worklog quits", isOn: $settings.pauseOnQuit)
                SettingsFootnote("A running session keeps counting while Worklog is closed unless it is paused when you quit. Worklog never resumes on its own.")
                Stepper(value: $settings.longSessionWarningHours, in: 1...24, step: 1) {
                    LabeledContent("Ask “Still working?” after") {
                        Text(Self.hoursPhrase(settings.longSessionWarningHours))
                            .monospacedDigit()
                    }
                }
            }

            Section("Goals and calendar") {
                Stepper(value: $settings.dailyGoalHours, in: 0...16, step: 0.5) {
                    LabeledContent("Daily goal") {
                        Text(settings.dailyGoalHours > 0 ? StatsView.hoursText(settings.dailyGoalHours) : "Off")
                            .monospacedDigit()
                    }
                }
                Picker("Week starts on", selection: $settings.weekStartsOnMonday) {
                    Text("Monday").tag(true)
                    Text("Sunday").tag(false)
                }
                SettingsFootnote("Used by Today, Stats and the Learning page.")
            }
        }
        .formStyle(.grouped)
    }

    private static func hoursPhrase(_ hours: Double) -> String {
        let whole = Int(hours.rounded())
        return "\(whole) \(whole == 1 ? "hour" : "hours")"
    }
}
