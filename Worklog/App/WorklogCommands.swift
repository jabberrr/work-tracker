import SwiftUI

/// "Session" menu + sidebar navigation shortcuts. Titles are static (Commands don't reliably observe state);
/// actions do nothing when they don't apply.
@MainActor
struct WorklogCommands: Commands {
    let services: AppServices

    var body: some Commands {
        CommandMenu("Session") {
            Button("Start / Stop Session") {
                let engine = services.engine
                if engine.isActive {
                    engine.stop()
                    services.router.showMainWindow()
                } else {
                    engine.start(label: engine.defaultLabel())
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Pause / Resume") {
                services.engine.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Add Note…") {
                services.router.requestNoteFocus()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Split Segment…") {
                services.router.requestSplit()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Overlay") {
                services.overlay.toggle()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Discard Session…") {
                services.router.show(.today)
            }
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Today") { services.router.show(.today) }
                .keyboardShortcut("1", modifiers: .command)
            Button("History") { services.router.show(.history) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Learning") { services.router.show(.learning) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Stats") { services.router.show(.stats) }
                .keyboardShortcut("4", modifiers: .command)
        }
    }
}
