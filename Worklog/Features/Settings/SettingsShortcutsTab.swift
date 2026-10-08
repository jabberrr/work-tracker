import SwiftUI

/// Shortcuts: every app-defined shortcut (`ShortcutAction`), grouped, each with a recorder and a reset button.
/// Changes apply immediately (menus and in-view shortcuts read `ShortcutStore`).
@MainActor
struct SettingsShortcutsTab: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(\.theme) private var theme

    /// The last rejected recording per action. `id` restarts the 4 s auto-clear for a repeated message.
    @State private var errors: [ShortcutAction: SettingsShortcutError] = [:]
    @State private var confirmsResetAll = false

    var body: some View {
        Form {
            ForEach(ShortcutGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action)
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset All") { confirmsResetAll = true }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!shortcuts.hasCustomizations)
                    Spacer()
                }
                SettingsFootnote("⌘, ⌘Q, ⌘W, Esc, Return and ⌫ are fixed.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all shortcuts?", isPresented: $confirmsResetAll, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) {
                shortcuts.resetAll()
                errors = [:]
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(spacing: theme.spacingS) {
                Text(action.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: theme.spacingS)
                ShortcutRecorder(
                    shortcut: shortcuts.stored(for: action),
                    accessibilityName: action.title,
                    onRecord: { recorded in
                        let result = shortcuts.set(recorded, for: action)
                        errors[action] = result.message.map { SettingsShortcutError(message: $0) }
                    },
                    onClear: {
                        shortcuts.set(nil, for: action)
                        errors[action] = nil
                    }
                )
                ResetToDefaultButton(isDefault: shortcuts.isDefault(action),
                                     accessibilityLabel: "Reset \(action.title)") {
                    shortcuts.reset(action)
                    errors[action] = nil
                }
            }
            if let error = errors[action] {
                Text(error.message)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .task(id: error.id) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, errors[action]?.id == error.id else { return }
                        errors[action] = nil
                    }
            }
        }
    }
}

/// A rejected recording's message ("Used by Show Today.").
private struct SettingsShortcutError: Equatable {
    let id = UUID()
    let message: String
}
