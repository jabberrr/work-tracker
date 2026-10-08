import SwiftUI

/// Appearance: theme style (live swatches), light/dark/system, accent, in-app text size, reset.
@MainActor
struct SettingsAppearanceTab: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var themeManager = themeManager

        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 210), spacing: theme.spacingM, alignment: .top)],
                          alignment: .leading, spacing: theme.spacingM) {
                    ForEach(ThemeID.allCases) { id in
                        Button {
                            themeManager.themeID = id
                        } label: {
                            ThemePreviewSwatch(themeID: id, isSelected: themeManager.themeID == id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, theme.spacingXS)
            }

            Section {
                Picker("Appearance", selection: $themeManager.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent") {
                    SettingsAccentPicker(selection: $themeManager.accent, themeID: themeManager.themeID)
                }

                Picker("Text size", selection: $themeManager.textSize) {
                    ForEach(ThemeTextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Appearance") { themeManager.resetToDefaults() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Row of 16 pt accent circles. The first is the theme's own accent (marked "A"); the selected one has a ring.
private struct SettingsAccentPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: AccentChoice
    let themeID: ThemeID

    private func color(for choice: AccentChoice) -> Color {
        choice.color ?? Theme.make(themeID, colorScheme: colorScheme, accent: .themeDefault).accent
    }

    var body: some View {
        HStack(spacing: theme.spacingS) {
            ForEach(AccentChoice.allCases) { choice in
                let isSelected = choice == selection
                Button {
                    selection = choice
                } label: {
                    Circle()
                        .fill(color(for: choice))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if choice == .themeDefault {
                                Text("A")
                                    .font(.system(size: 9 * theme.textScale, weight: .bold))
                                    .foregroundStyle(Theme.make(themeID, colorScheme: colorScheme).onAccent)
                            }
                        }
                        .padding(3)
                        .overlay {
                            Circle()
                                .strokeBorder(isSelected ? theme.textPrimary : Color.clear, lineWidth: 1.5)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.displayName)
                .accessibilityLabel("\(choice.displayName) accent")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Text(selection.displayName)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .frame(minWidth: 90, alignment: .leading)
        }
    }
}
