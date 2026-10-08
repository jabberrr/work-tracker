import SwiftUI

/// App menu "Settings…", the "Session" menu and sidebar navigation (View menu). Titles are static (Commands don't
/// reliably observe state); actions do nothing when they don't apply. Customizable shortcuts come from
/// `ShortcutStore`, read inside `ShortcutCommandButton` so a change applies to the menus immediately.
@MainActor
struct WorklogCommands: Commands {
    let services: AppServices

    var body: some Commands {
        // There is no Settings scene: Settings is a page of the main window. Replacing the group keeps the
        // standard "Settings…" item and its fixed ⌘, shortcut.
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") {
                services.router.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Session") {
            ShortcutCommandButton(title: "Start / Stop Session", action: .startStop, store: services.shortcuts) {
                let engine = services.engine
                if engine.isActive {
                    engine.stop()
                    services.router.showMainWindow()
                } else {
                    engine.start(label: engine.defaultLabel())
                }
            }

            ShortcutCommandButton(title: "Pause / Resume", action: .pauseResume, store: services.shortcuts) {
                services.engine.togglePause()
            }

            Divider()

            ShortcutCommandButton(title: "Add Note\u{2026}", action: .addNote, store: services.shortcuts) {
                services.router.requestNoteFocus()
            }

            ShortcutCommandButton(title: "Split Segment\u{2026}", action: .splitSegment, store: services.shortcuts) {
                services.router.requestSplit()
            }

            Divider()

            ShortcutCommandButton(title: "Toggle Overlay", action: .toggleOverlay, store: services.shortcuts) {
                services.overlay.toggle()
            }

            Divider()

            ShortcutCommandButton(title: "Discard Session\u{2026}", action: .discardSession, store: services.shortcuts) {
                guard services.engine.isActive else { return }
                services.router.requestDiscard()
            }
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ShortcutCommandButton(title: "Today", action: .showToday, store: services.shortcuts) {
                services.router.show(.today)
            }
            ShortcutCommandButton(title: "History", action: .showHistory, store: services.shortcuts) {
                services.router.show(.history)
            }
            ShortcutCommandButton(title: "Learning", action: .showLearning, store: services.shortcuts) {
                services.router.show(.learning)
            }
            ShortcutCommandButton(title: "Stats", action: .showStats, store: services.shortcuts) {
                services.router.show(.stats)
            }
        }
    }
}

/// A menu item whose shortcut follows `ShortcutStore` (nil = no shortcut). A View, not inline in the Commands body,
/// because only a View body reliably re-renders when the observed store changes.
private struct ShortcutCommandButton: View {
    let title: String
    let action: ShortcutAction
    let store: ShortcutStore
    let perform: () -> Void

    var body: some View {
        Button(title, action: perform)
            .keyboardShortcut(store.shortcut(for: action))
    }
}
