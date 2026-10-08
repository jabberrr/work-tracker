import SwiftData
import SwiftUI

/// Profiles: "Quick start in **Current profile**", then a two-column list / editor like Labels & Tags.
///
/// List: non-archived profiles (✓ marks the current one, drag to reorder), archived ones below, [+] for a new
/// profile. Editor: name, color, symbol, the profile's default label, usage, and Switch To / Archive / Delete….
/// Delete asks where the sessions go (another profile, or deleted after a second confirmation).
@MainActor
struct SettingsProfilesTab: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    @State private var selectedID: PersistentIdentifier?
    @State private var showsCreateSheet = false
    /// Profiles that existed when the create sheet opened; the new one is selected when the sheet closes.
    @State private var idsBeforeCreate: Set<PersistentIdentifier>?

    private var activeProfiles: [WorkProfile] { ModelLiveness.live(profileStore.profiles) }
    private var archivedProfiles: [WorkProfile] { ModelLiveness.live(profileStore.archivedProfiles) }

    private var selectedProfile: WorkProfile? {
        guard let selectedID else { return nil }
        return (activeProfiles + archivedProfiles).first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: theme.spacingXS) {
                ProfileValuePicker("Quick start in", selection: $settings.quickStartProfileID,
                                   nilTitle: "Current profile")
                SettingsFootnote("Used by the menu bar and the overlay.")
            }
            .padding(.horizontal, theme.spacingXL)
            .padding(.vertical, theme.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if activeProfiles.isEmpty && archivedProfiles.isEmpty {
                EmptyStateView(title: "No profiles", systemImage: "person.crop.rectangle.stack",
                               actionTitle: "New Profile", action: presentCreateSheet)
            } else {
                HStack(spacing: 0) {
                    profileList
                        .frame(width: 230)
                    Divider()
                    Group {
                        if let profile = selectedProfile {
                            SettingsProfileEditor(profile: profile, onDeleted: selectCurrent)
                                .id(profile.persistentModelID)
                        } else {
                            EmptyStateView(title: "Select a profile", systemImage: "person.crop.rectangle.stack")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selectedProfile == nil { selectCurrent() }
        }
        .sheet(isPresented: $showsCreateSheet, onDismiss: selectCreatedProfile) {
            ProfileCreateSheet(selectsNewProfile: false)
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Profiles") {
                    ForEach(activeProfiles) { profile in
                        row(profile)
                            .tag(profile.persistentModelID)
                    }
                    .onMove(perform: moveProfiles)
                }
                if !archivedProfiles.isEmpty {
                    Section("Archived") {
                        ForEach(archivedProfiles) { profile in
                            row(profile)
                                .tag(profile.persistentModelID)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: theme.spacingS) {
                Button(action: presentCreateSheet) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("New profile")
                .accessibilityLabel("New profile")
                Spacer()
                if activeProfiles.count > 1 {
                    Text("Drag to reorder")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS)
        }
        .themedBackground(.sidebar)
    }

    private func row(_ profile: WorkProfile) -> some View {
        let isCurrent = profileStore.activeProfileID == profile.uuid
        let count = profile.sessionCount
        return HStack(spacing: theme.spacingS) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .fontWeight(.semibold)
                .foregroundStyle(theme.accent)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 12)
                .accessibilityHidden(true)
            ProfileSymbolTile(profile: profile)
                .accessibilityHidden(true)
            Text(profile.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(profile.isArchived ? theme.textSecondary : theme.textPrimary)
            Spacer(minLength: theme.spacingXS)
            Text("\(count)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Sessions")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(count) \(count == 1 ? "session" : "sessions")"
                            + (isCurrent ? ", current" : "") + (profile.isArchived ? ", archived" : ""))
    }

    // MARK: Actions

    private func moveProfiles(from source: IndexSet, to destination: Int) {
        var ordered = activeProfiles
        ordered.move(fromOffsets: source, toOffset: destination)
        profileStore.reorder(ordered + archivedProfiles)
    }

    private func presentCreateSheet() {
        idsBeforeCreate = Set((activeProfiles + archivedProfiles).map(\.persistentModelID))
        showsCreateSheet = true
    }

    private func selectCreatedProfile() {
        guard let before = idsBeforeCreate else { return }
        idsBeforeCreate = nil
        if let created = activeProfiles.first(where: { !before.contains($0.persistentModelID) }) {
            selectedID = created.persistentModelID
        }
    }

    /// Selects the current profile (else the first one).
    private func selectCurrent() {
        selectedID = (ModelLiveness.live(profileStore.activeProfile) ?? activeProfiles.first)?.persistentModelID
    }
}

// MARK: - Profile editor

@MainActor
private struct SettingsProfileEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]
    @Bindable var profile: WorkProfile
    let onDeleted: () -> Void

    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var showsDeleteSheet = false
    /// Why the last archive attempt was refused ("Keep at least one profile.").
    @State private var refusal: String?

    private var isCurrent: Bool { profileStore.activeProfileID == profile.uuid }

    /// The only non-archived profile can't be archived or deleted.
    private var isLastActive: Bool {
        !profile.isArchived && !ModelLiveness.live(profileStore.profiles).contains {
            $0.persistentModelID != profile.persistentModelID
        }
    }

    /// `profile.defaultLabelUUID` ⇄ the label object for `LabelValuePicker`.
    private var defaultLabel: Binding<WorkLabel?> {
        Binding(
            get: {
                guard let id = profile.defaultLabelUUID else { return nil }
                return ModelLiveness.live(labels).first { $0.uuid == id }
            },
            set: { newValue in
                guard ModelLiveness.isLive(profile), profile.defaultLabelUUID != newValue?.uuid else { return }
                profile.defaultLabelUUID = newValue?.uuid
                profile.touch()
                save()
            }
        )
    }

    var body: some View {
        if ModelLiveness.isLive(profile) {
            form
        } else {
            // Deleted a moment ago; the tab switches selection on the next update.
            Color.clear
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $draftName)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                LabeledContent("Preview") {
                    ProfileBadge(profile: profile, size: .regular)
                }
            }

            Section("Color") {
                LabelColorPicker(hex: $profile.colorHex)
            }

            Section("Symbol") {
                ScrollView {
                    SymbolPicker(symbolName: $profile.symbolName, symbols: LabelPalette.profileSymbolChoices)
                        .padding(theme.spacingXS)
                }
                .frame(height: 240)
            }

            Section("New sessions") {
                LabelValuePicker("Default label", selection: defaultLabel, profileID: profile.uuid)
                SettingsFootnote("“None” uses your first label.")
            }

            Section("Usage") {
                SettingsFootnote(usageDescription)
            }

            Section {
                HStack(spacing: theme.spacingS) {
                    Button("Switch To") { profileStore.select(profile) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(isCurrent || profile.isArchived)
                        .help("Switch profile")
                    Button(profile.isArchived ? "Unarchive" : "Archive", action: toggleArchive)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(isLastActive)
                        .help(isLastActive ? "Keep at least one profile"
                                           : (profile.isArchived ? "Unarchive profile" : "Archive profile"))
                    Spacer()
                    Button("Delete…") {
                        refusal = nil
                        showsDeleteSheet = true
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(isLastActive)
                    .help(isLastActive ? "Keep at least one profile" : "Delete profile")
                }
                if let refusal {
                    Text(refusal)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if profile.isArchived {
                    SettingsFootnote("Hidden from the switcher. Its sessions are kept.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = profile.name }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .onDisappear {
            commitName()
            // Flush a color change still waiting in the debounce below.
            if ModelLiveness.isLive(profile), context.hasChanges { save() }
        }
        .onChange(of: profile.colorHex) { profile.touch() }
        .task(id: profile.colorHex) {
            // The color wheel reports every drag tick: save once the color settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, context.hasChanges { save() }
        }
        .onChange(of: profile.symbolName) {
            profile.touch()
            save()
        }
        .sheet(isPresented: $showsDeleteSheet) {
            SettingsDeleteProfileSheet(profile: profile) {
                showsDeleteSheet = false
                onDeleted()
            }
        }
    }

    /// "12 sessions · 2 own labels · 1 own tag".
    private var usageDescription: String {
        let sessions = profile.sessionCount
        let ownLabels = ModelLiveness.live(profile.labels ?? []).count
        let ownTags = ModelLiveness.live(profile.tags ?? []).count
        var parts = ["\(sessions) \(sessions == 1 ? "session" : "sessions")"]
        if ownLabels > 0 { parts.append("\(ownLabels) own \(ownLabels == 1 ? "label" : "labels")") }
        if ownTags > 0 { parts.append("\(ownTags) own \(ownTags == 1 ? "tag" : "tags")") }
        return parts.joined(separator: " · ")
    }

    private func commitName() {
        guard ModelLiveness.isLive(profile) else { return }
        let trimmed = draftName.trimmed
        if trimmed.isEmpty {
            draftName = profile.name
        } else if trimmed != profile.name {
            profile.name = trimmed
            profile.touch()
            save()
        }
    }

    private func toggleArchive() {
        guard ModelLiveness.isLive(profile) else { return }
        let result = profileStore.setArchived(profile, !profile.isArchived)
        refusal = result.message
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Delete profile sheet

/// "Delete “Personal”? 12 sessions use it. Move sessions to ▾ [Work]" — another profile, or "Delete sessions"
/// (confirmed a second time when there are sessions).
@MainActor
private struct SettingsDeleteProfileSheet: View {
    private enum Choice: Hashable {
        case move(UUID)
        case deleteSessions
    }

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let profile: WorkProfile
    let onDeleted: () -> Void

    @State private var choice: Choice?
    @State private var errorText: String?
    @State private var confirmsDeleteSessions = false

    /// Where the sessions can go: the other non-archived profiles.
    private var targets: [WorkProfile] {
        ModelLiveness.live(profileStore.profiles).filter { $0.persistentModelID != profile.persistentModelID }
    }

    /// The picked choice while still valid; else the first other profile; else "Delete sessions".
    private var effectiveChoice: Choice {
        let targets = targets
        if let choice {
            switch choice {
            case .deleteSessions:
                return choice
            case .move(let id):
                if targets.contains(where: { $0.uuid == id }) { return choice }
            }
        }
        if let first = targets.first { return .move(first.uuid) }
        return .deleteSessions
    }

    private var hasOwnTaxonomy: Bool {
        !ModelLiveness.live(profile.labels ?? []).isEmpty || !ModelLiveness.live(profile.tags ?? []).isEmpty
    }

    var body: some View {
        if ModelLiveness.isLive(profile) {
            content
        } else {
            Color.clear.frame(width: 460, height: 120)
        }
    }

    private var content: some View {
        let count = profile.sessionCount
        let selected = effectiveChoice
        return VStack(alignment: .leading, spacing: theme.spacingL) {
            Text("Delete “\(profile.displayName)”?")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Text(count == 0 ? "No sessions use it." : "\(count) \(count == 1 ? "session uses" : "sessions use") it.")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Move sessions to", selection: Binding(
                get: { effectiveChoice },
                set: { newValue in
                    choice = newValue
                    errorText = nil
                }
            )) {
                ForEach(targets) { target in
                    Text(target.displayName)
                        .tag(Choice.move(target.uuid))
                }
                if !targets.isEmpty {
                    Divider()
                }
                Text("Delete sessions")
                    .tag(Choice.deleteSessions)
            }

            if case .move = selected, hasOwnTaxonomy {
                SettingsFootnote("Its own labels and tags move too.")
            }
            if let errorText {
                Text(errorText)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: theme.spacingS) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete", role: .destructive) {
                    if selected == .deleteSessions && count > 0 {
                        confirmsDeleteSessions = true
                    } else {
                        perform(selected)
                    }
                }
                .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 460)
        .confirmationDialog("Delete \(count) \(count == 1 ? "session" : "sessions")?",
                            isPresented: $confirmsDeleteSessions, titleVisibility: .visible) {
            Button("Delete Sessions", role: .destructive) { perform(.deleteSessions) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func perform(_ choice: Choice) {
        guard ModelLiveness.isLive(profile) else { return }
        let deletion: ProfileDeletion
        switch choice {
        case .move(let id): deletion = .moveSessions(toProfileID: id)
        case .deleteSessions: deletion = .deleteSessions
        }
        let result = profileStore.delete(profile, deletion)
        if result == .ok {
            onDeleted()
            dismiss()
        } else {
            errorText = result.message
        }
    }
}
