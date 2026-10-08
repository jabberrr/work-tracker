import SwiftUI

/// "New profile" sheet (width 420): Name (focused), color swatches, symbol grid, ( Cancel ) [ Create ].
/// The color defaults to the first palette color no other profile uses; the symbol to `briefcase.fill`.
/// Create (default action, disabled while the name is blank) calls
/// `ProfileStore.createProfile(name:colorHex:symbolName:select:)` and dismisses.
///
/// Presented from `ProfileSwitcher` (selects the new profile; the switcher reports it to `WindowRouter` as a child
/// sheet so the end-of-session review waits) and Settings ▸ Profiles (`selectsNewProfile: false`).
/// Reads `ProfileStore` from the environment.
@MainActor
struct ProfileCreateSheet: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let selectsNewProfile: Bool

    @State private var name = ""
    @State private var colorHex = LabelPalette.hexColors.first ?? "#5B8DEF"
    @State private var symbolName = "briefcase.fill"
    @State private var didPickDefaults = false
    /// Set by the first Create: Return + click (or a double click) before the sheet closes must not create twice.
    @State private var didCreate = false
    @FocusState private var nameFocused: Bool

    init(selectsNewProfile: Bool = true) {
        self.selectsNewProfile = selectsNewProfile
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingL) {
            Text("New profile")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            TextField("Name", text: $name, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .insetField(isFocused: nameFocused)
                .focused($nameFocused)
                .onSubmit(create)

            VStack(alignment: .leading, spacing: theme.spacingS) {
                fieldTitle("Color")
                LabelColorPicker(hex: $colorHex)
            }

            VStack(alignment: .leading, spacing: theme.spacingS) {
                fieldTitle("Symbol")
                ScrollView(.vertical) {
                    SymbolPicker(symbolName: $symbolName, symbols: LabelPalette.profileSymbolChoices)
                        .padding(2)
                }
                .frame(height: 160)
            }

            HStack(spacing: theme.spacingS) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Create", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || didCreate)
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 420)
        .onAppear {
            pickDefaultColor()
            // Let the sheet become key before focusing the field.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                nameFocused = true
            }
        }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(theme.captionFont.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// First palette color no other profile (archived included) uses; else the first palette color.
    private func pickDefaultColor() {
        guard !didPickDefaults else { return }
        didPickDefaults = true
        let used = Set(ModelLiveness.live(profiles.profiles + profiles.archivedProfiles)
            .map { LabelPalette.normalized($0.colorHex) })
        if let free = LabelPalette.hexColors.first(where: { !used.contains(LabelPalette.normalized($0)) }) {
            colorHex = free
        }
    }

    private func create() {
        guard !trimmedName.isEmpty, !didCreate else { return }
        didCreate = true
        profiles.createProfile(name: trimmedName, colorHex: colorHex, symbolName: symbolName,
                               select: selectsNewProfile)
        dismiss()
    }
}
