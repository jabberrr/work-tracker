import SwiftData
import SwiftUI

// MARK: - Label editor

/// One label of Settings ▸ Labels & Tags: name (no duplicate names among the labels offered here), availability,
/// default, color, symbol, usage, archive, merge and delete (`SettingsDeleteLabelSheet`).
@MainActor
struct SettingsLabelEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profileStore
    @Environment(BackupService.self) private var backups
    @Environment(\.theme) private var theme
    @Bindable var label: WorkLabel
    /// Every live label (all profiles); merge/delete targets are narrowed by `TaxonomyOps.reassignmentTargets`.
    let allLabels: [WorkLabel]
    /// Labels the current profile offers (duplicate-name check).
    let offeredLabels: [WorkLabel]
    let onDeleted: () -> Void
    let onMerged: (WorkLabel) -> Void

    @State private var draftName = ""
    /// Another offered label already has the typed name (the rename was not applied).
    @State private var duplicate: WorkLabel?
    @FocusState private var nameFocused: Bool
    @State private var showsDeleteSheet = false
    @State private var mergeTarget: WorkLabel?
    /// Set while "Make “X” Work only?" is asked (other profiles use the label).
    @State private var pendingLocalProfileID: UUID?
    /// The safety backup before a merge or scope change failed (nothing was changed).
    @State private var safetyError: String?

    /// Merge and delete targets that keep every session's labels offered in its profile.
    private var otherLabels: [WorkLabel] {
        TaxonomyOps.reassignmentTargets(for: label, among: ModelLiveness.live(allLabels))
    }

    private var currentProfile: WorkProfile? { ModelLiveness.live(profileStore.activeProfile) }
    /// "Available in" appears once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.showsProfileScope }
    /// Archive, merge and delete of a global label affect every profile; say so once profiles are shown.
    private var changesAllProfiles: Bool { showsScope && label.isAvailableEverywhere }

    /// "Make “Meetings” Work only?"
    private var makeLocalTitle: String {
        let name: String = profileStore.profile(withID: pendingLocalProfileID)?.displayName ?? "this profile"
        return "Make “\(label.name)” \(name) only?"
    }

    /// "Merge “A” into “B”?"
    private var mergeTitle: String {
        guard let target = mergeTarget, ModelLiveness.isLive(target) else { return "Merge labels?" }
        return "Merge “\(label.name)” into “\(target.name)”?"
    }

    private var mergeMessage: String {
        let name: String = mergeTarget.flatMap { ModelLiveness.live($0)?.name } ?? ""
        return changesAllProfiles
            ? "Moves its sessions in all profiles to “\(name)” and deletes it."
            : "Moves its sessions to “\(name)” and deletes it."
    }

    /// Default label of the current profile.
    private var isDefault: Binding<Bool> {
        Binding(
            get: { currentProfile?.defaultLabelUUID == label.uuid },
            set: { newValue in
                guard let profile = currentProfile else { return }
                if newValue {
                    guard profile.defaultLabelUUID != label.uuid else { return }
                    profile.defaultLabelUUID = label.uuid
                } else {
                    guard profile.defaultLabelUUID == label.uuid else { return }
                    profile.defaultLabelUUID = nil
                }
                profile.touch()
                save()
            }
        )
    }

    private var scopeSelection: Binding<SettingsTaxonomyScope> {
        Binding(
            get: { label.isAvailableEverywhere ? .allProfiles : .thisProfile },
            set: { requestScope($0) }
        )
    }

    var body: some View {
        if !ModelLiveness.isLive(label) {
            // Deleted or merged a moment ago; the pane switches selection on the next update.
            Color.clear
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $draftName)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                if let duplicate, ModelLiveness.isLive(duplicate) {
                    HStack(spacing: theme.spacingS) {
                        Text("A label named “\(duplicate.name)” already exists.")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if otherLabels.contains(where: { $0.persistentModelID == duplicate.persistentModelID }) {
                            Button("Merge Into It…") { mergeTarget = duplicate }
                                .buttonStyle(QuietButtonStyle())
                                .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Preview") {
                    LabelBadge(label: label)
                }
                if let profile = currentProfile {
                    if showsScope {
                        SettingsScopePicker(selection: scopeSelection, profileName: profile.displayName)
                    }
                    Toggle(profileStore.hasMultipleProfiles ? "Default in \(profile.displayName)" : "Default label",
                           isOn: isDefault)
                        .disabled(label.isArchived)
                }
            }

            Section("Color") {
                LabelColorPicker(hex: $label.colorHex)
            }

            Section("Symbol") {
                ScrollView {
                    SymbolPicker(symbolName: $label.symbolName)
                        .padding(theme.spacingXS)
                }
                .frame(height: 150)
            }

            Section("Usage") {
                SettingsFootnote(usageDescription)
            }

            Section {
                HStack(spacing: theme.spacingS) {
                    Button(label.isArchived ? "Unarchive" : "Archive", action: toggleArchive)
                        .buttonStyle(QuietButtonStyle())
                    Menu("Merge Into") {
                        ForEach(otherLabels) { other in
                            Button(other.isArchived ? "\(other.name) (archived)" : other.name) {
                                mergeTarget = other
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(otherLabels.isEmpty)
                    .help("Merge label")
                    Spacer()
                    Button("Delete…") { showsDeleteSheet = true }
                        .buttonStyle(DestructiveButtonStyle())
                }
                if changesAllProfiles {
                    SettingsFootnote("Changes it in all profiles.")
                }
                if let safetyError {
                    InlineBanner(safetyError, style: .error, onDismiss: { self.safetyError = nil })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = label.name }
        .onChange(of: label.name) { _, newName in
            // A rename synced from another Mac: show it unless the user is typing (their commit wins).
            if !nameFocused { draftName = newName }
        }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .onChange(of: draftName) { duplicate = nil }
        .onDisappear {
            commitName()
            // Flush a color change still waiting in the debounce below.
            if ModelLiveness.isLive(label), context.hasChanges { save() }
        }
        .task(id: label.colorHex) {
            // The color wheel reports every drag tick: save once the color settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
        .onChange(of: label.symbolName) { save() }
        .sheet(isPresented: $showsDeleteSheet) {
            SettingsDeleteLabelSheet(label: label, candidates: otherLabels, scope: profileStore.activeScope,
                                     changesAllProfiles: changesAllProfiles) {
                showsDeleteSheet = false
                onDeleted()
            }
        }
        .confirmationDialog(
            mergeTitle,
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                guard let target = mergeTarget, ModelLiveness.isLive(target), ModelLiveness.isLive(label) else {
                    mergeTarget = nil
                    return
                }
                mergeTarget = nil
                guard makeSafetyBackup() else { return }
                TaxonomyOps.mergeLabel(label, into: target, settings: settings, in: context)
                onMerged(target)
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text(mergeMessage)
        }
        .confirmationDialog(
            makeLocalTitle,
            isPresented: Binding(get: { pendingLocalProfileID != nil }, set: { if !$0 { pendingLocalProfileID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Make Local") {
                let profile = profileStore.profile(withID: pendingLocalProfileID)
                pendingLocalProfileID = nil
                guard let profile, ModelLiveness.isLive(label), makeSafetyBackup() else { return }
                TaxonomyOps.setScope(of: label, to: profile, in: context)
            }
            Button("Cancel", role: .cancel) { pendingLocalProfileID = nil }
        } message: {
            Text("Other profiles keep their own copy.")
        }
    }

    /// All profiles: always fine. This profile only: asks first when other profiles use the label (each gets its
    /// own copy).
    private func requestScope(_ scope: SettingsTaxonomyScope) {
        guard ModelLiveness.isLive(label) else { return }
        switch scope {
        case .allProfiles:
            guard !label.isAvailableEverywhere, makeSafetyBackup() else { return }
            TaxonomyOps.setScope(of: label, to: nil, in: context)
        case .thisProfile:
            guard label.isAvailableEverywhere, let profile = currentProfile else { return }
            if case .copiesForOtherProfiles = TaxonomyOps.scopeChangeImpact(of: label, to: profile) {
                pendingLocalProfileID = profile.uuid
            } else {
                guard makeSafetyBackup() else { return }
                TaxonomyOps.setScope(of: label, to: profile, in: context)
            }
        }
    }

    /// "12 sessions · 3 segments · 2 tags", counted in the current profile.
    private var usageDescription: String {
        let scope = profileStore.activeScope
        let usage = SettingsScopedUsage.of(label, in: scope)
        let sessions = usage.sessions
        let segments = usage.segments
        let tags = ModelLiveness.live(label.tags ?? []).filter { scope.offers($0) }.count
        var parts = [
            "\(sessions) \(sessions == 1 ? "session" : "sessions")",
            "\(segments) \(segments == 1 ? "segment" : "segments")",
        ]
        if tags > 0 {
            parts.append("\(tags) \(tags == 1 ? "tag" : "tags")")
        }
        return parts.joined(separator: " · ")
    }

    /// Applies the typed name unless it is empty (restored) or another label offered here already has it
    /// (case/diacritic-insensitive; `duplicate` is shown instead).
    private func commitName() {
        guard ModelLiveness.isLive(label) else { return }
        let trimmed = draftName.trimmed
        guard !trimmed.isEmpty else {
            draftName = label.name
            return
        }
        guard trimmed != label.name else { return }
        if let existing = offeredLabels.first(where: {
            $0.persistentModelID != label.persistentModelID && ModelLiveness.isLive($0)
                && $0.name.trimmed.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            duplicate = existing
            return
        }
        label.name = trimmed
        save()
    }

    private func toggleArchive() {
        guard ModelLiveness.isLive(label) else { return }
        label.isArchived.toggle()
        if label.isArchived {
            TaxonomyOps.clearDefaultLabel(label, in: context)
        }
        save()
    }

    private func save() {
        SafeSave.save(context, source: "Label editor")
    }

    /// L1: a before-change backup first; false (and an error shown) when it failed.
    private func makeSafetyBackup() -> Bool {
        safetyError = backups.backupBeforeChange()
        return safetyError == nil
    }
}

// MARK: - Delete label sheet

/// "Delete “Meetings”? 42 sessions use it. Move them to: ▾ [Unlabeled]" — reassign target, or archive instead.
@MainActor
private struct SettingsDeleteLabelSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(BackupService.self) private var backups
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let label: WorkLabel
    let candidates: [WorkLabel]
    /// Counts are of this profile's sessions.
    let scope: ProfileScope
    /// A global label with profiles shown: deleting or archiving it changes every profile.
    let changesAllProfiles: Bool
    let onDeleted: () -> Void

    @State private var targetID: PersistentIdentifier?
    /// The safety backup failed (nothing was deleted).
    @State private var errorText: String?

    private var sortedCandidates: [WorkLabel] {
        candidates.filter { !$0.isArchived } + candidates.filter { $0.isArchived }
    }

    var body: some View {
        if !ModelLiveness.isLive(label) {
            Color.clear.frame(width: 460, height: 120)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let usage = SettingsScopedUsage.of(label, in: scope)
        let sessions = usage.sessions
        let segments = usage.segments
        let usesText: String = sessions + segments == 0
            ? "No sessions use this label."
            : "\(sessions) \(sessions == 1 ? "session" : "sessions") and \(segments) \(segments == 1 ? "segment" : "segments") use it."
        VStack(alignment: .leading, spacing: theme.spacingL) {
            Text("Delete “\(label.name)”?")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
            Text(usesText)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Move them to", selection: $targetID) {
                Text("Unlabeled").tag(PersistentIdentifier?.none)
                Divider()
                ForEach(sortedCandidates) { candidate in
                    Text(candidate.isArchived ? "\(candidate.name) (archived)" : candidate.name)
                        .tag(Optional(candidate.persistentModelID))
                }
            }

            if (label.tags?.count ?? 0) > 0 {
                SettingsFootnote("Its tags move along, or become global.")
            }
            SettingsFootnote("Archiving only hides it from pickers.")
            if changesAllProfiles {
                SettingsFootnote("Changes it in all profiles.")
            }
            SettingsFootnote("A backup is made first.")
            if let errorText {
                InlineBanner(errorText, style: .error, onDismiss: { self.errorText = nil })
            }

            HStack(spacing: theme.spacingS) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !label.isArchived {
                    Button("Archive Instead") {
                        label.isArchived = true
                        TaxonomyOps.clearDefaultLabel(label, in: context)
                        SafeSave.save(context, source: "Archive label")
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Delete Label", role: .destructive) {
                    if let failure = backups.backupBeforeChange() {
                        errorText = failure
                        return
                    }
                    let target = sortedCandidates.first { $0.persistentModelID == targetID }
                    TaxonomyOps.deleteLabel(label, reassignTo: target, settings: settings, in: context)
                    onDeleted()
                }
                .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 460)
    }
}
