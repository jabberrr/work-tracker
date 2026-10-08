import SwiftUI

/// Shortcuts: every app-defined shortcut (`ShortcutAction`), grouped, each with a recorder and a reset button.
/// Changes apply immediately (menus and in-view shortcuts read `ShortcutStore`).
@MainActor
struct SettingsShortcutsTab: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(\.theme) private var theme

    /// The last message per action: a rejected recording (error) or "Removed from X." after a reset took that
    /// action's default from X (notice). `id` restarts the 4 s auto-clear for a repeated message.
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
                        errors[action] = result.message.map { SettingsShortcutError(message: $0, isError: true) }
                    },
                    onClear: {
                        shortcuts.set(nil, for: action)
                        errors[action] = nil
                    }
                )
                ResetToDefaultButton(isDefault: shortcuts.isDefault(action),
                                     accessibilityLabel: "Reset \(action.title)") {
                    if let other = shortcuts.reset(action) {
                        errors[other] = nil
                        errors[action] = SettingsShortcutError(message: "Removed from \(other.title).", isError: false)
                    } else {
                        errors[action] = nil
                    }
                }
            }
            if let error = errors[action] {
                Text(error.message)
                    .font(theme.captionFont)
                    .foregroundStyle(error.isError ? theme.danger : theme.textSecondary)
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

/// A row's message: a rejected recording ("Used by Show Today.", isError) or a reset notice ("Removed from Show Today.").
private struct SettingsShortcutError: Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}
