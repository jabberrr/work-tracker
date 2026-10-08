import SwiftData
import SwiftUI

/// Labels & Tags: manage the label list (create, rename, color, symbol, reorder, archive, merge, delete with
/// reassignment) and tags (create, rename, color, parent label, archive, merge, delete).
///
/// Both lists show what the current profile offers: global items (trailing globe) plus its own. New items are
/// local to the current profile; "Available in" switches an item between all profiles and this profile only.
@MainActor
struct SettingsLabelsTab: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case labels, tags
        var id: String { rawValue }
        var title: String { self == .labels ? "Labels" : "Tags" }
    }

    @Environment(\.theme) private var theme
    @Environment(ProfileStore.self) private var profileStore
    @State private var pane: Pane = .labels

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Labels or tags")
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                // Whose labels these are, when there is more than one profile.
                if profileStore.hasMultipleProfiles {
                    ProfileBadge(profile: profileStore.activeProfile, size: .small)
                        .padding(.leading, theme.spacingL)
                }
            }
            .padding(.vertical, theme.spacingM)

            Divider()

            switch pane {
            case .labels: SettingsLabelsPane()
            case .tags: SettingsTagsPane()
            }
        }
    }
}

// MARK: - Labels pane

@MainActor
struct SettingsLabelsPane: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]
    @State private var selectedID: PersistentIdentifier?

    /// Every live label (all profiles). The query can briefly include labels deleted or merged a moment ago;
    /// never read those.
    private var allLiveLabels: [WorkLabel] { ModelLiveness.live(labels) }
    /// Labels the current profile offers (global + its own), in sortIndex order.
    private var liveLabels: [WorkLabel] {
        let scope = profileStore.activeScope
        return allLiveLabels.filter { scope.offers($0) }
    }
    private var activeLabels: [WorkLabel] { liveLabels.filter { !$0.isArchived } }
    /// Scope marks and controls appear once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.profiles.count + profileStore.archivedProfiles.count > 1 }
    private var archivedLabels: [WorkLabel] { liveLabels.filter { $0.isArchived } }
    private var selectedLabel: WorkLabel? {
        guard let selectedID else { return nil }
        return liveLabels.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        if allLiveLabels.isEmpty {
            VStack(spacing: theme.spacingM) {
                EmptyStateView(title: "No labels", systemImage: "tag",
                               actionTitle: "Restore defaults", action: restoreDefaults)
                Button("New Label", action: addLabel)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.bottom, theme.spacingXL)
            }
        } else if liveLabels.isEmpty {
            // Labels exist, but all belong to other profiles (a new profile).
            EmptyStateView(title: "No labels", systemImage: "tag",
                           actionTitle: "New Label", action: addLabel)
        } else {
            HStack(spacing: 0) {
                labelList
                    .frame(width: 230)
                Divider()
                Group {
                    if let label = selectedLabel {
                        SettingsLabelEditor(label: label, allLabels: allLiveLabels, onDeleted: { selectedID = nil },
                                            onMerged: { target in selectedID = target.persistentModelID })
                            .id(label.persistentModelID)
                    } else {
                        EmptyStateView(title: "Select a label", systemImage: "tag")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                if selectedID == nil { selectedID = activeLabels.first?.persistentModelID }
            }
            .onChange(of: profileStore.activeProfileID) {
                selectedID = activeLabels.first?.persistentModelID
            }
        }
    }

    private var labelList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Labels") {
                    ForEach(activeLabels) { label in
                        row(label)
                            .tag(label.persistentModelID)
                    }
                    .onMove(perform: moveLabels)
                }
                if !archivedLabels.isEmpty {
                    Section("Archived") {
                        ForEach(archivedLabels) { label in
                            row(label)
                                .tag(label.persistentModelID)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: theme.spacingS) {
                Button(action: addLabel) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("New label")
                .accessibilityLabel("New label")
                Spacer()
                Text("Drag to reorder")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS)
        }
        .themedBackground(.sidebar)
    }

    private func row(_ label: WorkLabel) -> some View {
        HStack(spacing: theme.spacingS) {
            Image(systemName: label.symbolName)
                .foregroundStyle(label.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(label.isArchived ? theme.textSecondary : theme.textPrimary)
            if let profile = ModelLiveness.live(profileStore.activeProfile), profile.defaultLabelUUID == label.uuid {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(theme.textTertiary)
                    .help("Default label")
                    .accessibilityLabel("Default")
            }
            Spacer(minLength: theme.spacingXS)
            if showsScope && label.isAvailableEverywhere {
                SettingsGlobalMark()
            }
            Text("\(label.usageCount)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Times used")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(label.usageCount) uses\(label.isArchived ? ", archived" : "")"
                            + (showsScope && label.isAvailableEverywhere ? ", all profiles" : ""))
    }

    // MARK: Actions

    /// Reorders the visible labels within the slots they already hold in the full list, so labels of other
    /// profiles keep their place, then renumbers everything.
    private func moveLabels(from source: IndexSet, to destination: Int) {
        var ordered = activeLabels
        ordered.move(fromOffsets: source, toOffset: destination)
        let visible = ordered + archivedLabels
        let visibleIDs = Set(visible.map(\.persistentModelID))
        var next = visible.makeIterator()
        let merged = allLiveLabels.map { label in
            visibleIDs.contains(label.persistentModelID) ? (next.next() ?? label) : label
        }
        TaxonomyOps.reorderLabels(merged)
    }

    private func addLabel() {
        let labels = liveLabels
        let usedColors = Set(labels.map { LabelPalette.normalized($0.colorHex) })
        let palette = LabelPalette.hexColors
        let color = palette.first { !usedColors.contains(LabelPalette.normalized($0)) }
            ?? (palette.isEmpty ? "#5B8DEF" : palette[labels.count % palette.count])
        let existingNames = Set(labels.map { $0.name.lowercased() })
        var name = "New label"
        var counter = 2
        while existingNames.contains(name.lowercased()) {
            name = "New label \(counter)"
            counter += 1
        }
        let label = TaxonomyOps.createLabel(name: name, colorHex: color, symbolName: "circle.fill",
                                            profile: ModelLiveness.live(profileStore.activeProfile), in: context)
        selectedID = label.persistentModelID
    }

    private func restoreDefaults() {
        UserDefaults.standard.set(false, forKey: SeedData.didSeedDefaultsKey)
        SeedData.seedIfNeeded(in: context)
        selectedID = nil
    }
}

// MARK: - Label editor

@MainActor
private struct SettingsLabelEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Bindable var label: WorkLabel
    /// Every live label (all profiles); merge/delete targets are narrowed by `TaxonomyOps.reassignmentTargets`.
    let allLabels: [WorkLabel]
    let onDeleted: () -> Void
    let onMerged: (WorkLabel) -> Void

    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var showsDeleteSheet = false
    @State private var mergeTarget: WorkLabel?
    /// Set while "Make “X” Work only?" is asked (other profiles use the label).
    @State private var pendingLocalProfileID: UUID?

    /// Merge and delete targets that keep every session's labels offered in its profile.
    private var otherLabels: [WorkLabel] {
        TaxonomyOps.reassignmentTargets(for: label, among: ModelLiveness.live(allLabels))
    }

    private var currentProfile: WorkProfile? { ModelLiveness.live(profileStore.activeProfile) }
    /// "Available in" appears once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.profiles.count + profileStore.archivedProfiles.count > 1 }

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
        if label.isDeleted || label.modelContext == nil {
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
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = label.name }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .onDisappear {
            commitName()
            // Flush a color change still waiting in the debounce below.
            if !label.isDeleted, label.modelContext != nil, context.hasChanges { save() }
        }
        .task(id: label.colorHex) {
            // The color wheel reports every drag tick: save once the color settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
        .onChange(of: label.symbolName) { save() }
        .sheet(isPresented: $showsDeleteSheet) {
            SettingsDeleteLabelSheet(label: label, candidates: otherLabels) {
                showsDeleteSheet = false
                onDeleted()
            }
        }
        .confirmationDialog(
            mergeTarget.map { "Merge “\(label.name)” into “\($0.name)”?" } ?? "Merge labels?",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                guard let target = mergeTarget else { return }
                mergeTarget = nil
                TaxonomyOps.mergeLabel(label, into: target, settings: settings, in: context)
                onMerged(target)
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("Moves its sessions to “\(mergeTarget?.name ?? "")” and deletes it.")
        }
        .confirmationDialog(
            "Make “\(label.name)” \(profileStore.profile(withID: pendingLocalProfileID)?.displayName ?? "this profile") only?",
            isPresented: Binding(get: { pendingLocalProfileID != nil }, set: { if !$0 { pendingLocalProfileID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Make Local") {
                let profile = profileStore.profile(withID: pendingLocalProfileID)
                pendingLocalProfileID = nil
                guard let profile, ModelLiveness.isLive(label) else { return }
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
            guard !label.isAvailableEverywhere else { return }
            TaxonomyOps.setScope(of: label, to: nil, in: context)
        case .thisProfile:
            guard label.isAvailableEverywhere, let profile = currentProfile else { return }
            if case .copiesForOtherProfiles = TaxonomyOps.scopeChangeImpact(of: label, to: profile) {
                pendingLocalProfileID = profile.uuid
            } else {
                TaxonomyOps.setScope(of: label, to: profile, in: context)
            }
        }
    }

    private var usageDescription: String {
        let sessions = label.sessions?.count ?? 0
        let segments = label.segments?.count ?? 0
        let tags = label.tags?.count ?? 0
        var parts = [
            "\(sessions) \(sessions == 1 ? "session" : "sessions")",
            "\(segments) \(segments == 1 ? "segment" : "segments")",
        ]
        if tags > 0 {
            parts.append("\(tags) \(tags == 1 ? "tag" : "tags")")
        }
        return parts.joined(separator: " · ")
    }

    private func commitName() {
        guard !label.isDeleted, label.modelContext != nil else { return }
        let trimmed = draftName.trimmed
        if trimmed.isEmpty {
            draftName = label.name
        } else if trimmed != label.name {
            label.name = trimmed
            save()
        }
    }

    private func toggleArchive() {
        label.isArchived.toggle()
        if label.isArchived {
            SettingsDefaultLabels.clear(label, in: context)
        }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving label failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Delete label sheet

/// "Delete “Meetings”? 42 sessions use it. Move them to: ▾ [Unlabeled]" — reassign target, or archive instead.
@MainActor
private struct SettingsDeleteLabelSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let label: WorkLabel
    let candidates: [WorkLabel]
    let onDeleted: () -> Void

    @State private var targetID: PersistentIdentifier?

    private var sortedCandidates: [WorkLabel] {
        candidates.filter { !$0.isArchived } + candidates.filter { $0.isArchived }
    }

    var body: some View {
        if label.isDeleted || label.modelContext == nil {
            Color.clear.frame(width: 460, height: 120)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let sessions = label.sessions?.count ?? 0
        let segments = label.segments?.count ?? 0
        VStack(alignment: .leading, spacing: theme.spacingL) {
            Text("Delete “\(label.name)”?")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
            Text(sessions + segments == 0
                 ? "No sessions use this label."
                 : "\(sessions) \(sessions == 1 ? "session" : "sessions") and \(segments) \(segments == 1 ? "segment" : "segments") use it.")
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

            HStack(spacing: theme.spacingS) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !label.isArchived {
                    Button("Archive Instead") {
                        label.isArchived = true
                        SettingsDefaultLabels.clear(label, in: context)
                        try? context.save()
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Delete Label", role: .destructive) {
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

// MARK: - Scope (shared with the tags pane)

/// "Available in **All profiles**" / "Available in **Work only**".
enum SettingsTaxonomyScope: Hashable {
    case allProfiles
    case thisProfile
}

/// The "Available in" value sentence of the label and tag editors.
struct SettingsScopePicker: View {
    @Binding var selection: SettingsTaxonomyScope
    let profileName: String

    var body: some View {
        let name = profileName
        ValuePicker("Available in", selection: $selection, options: [.allProfiles, .thisProfile],
                    title: { $0 == .allProfiles ? "All profiles" : "\(name) only" })
    }
}

/// Trailing globe on a global label or tag row.
struct SettingsGlobalMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "globe")
            .imageScale(.small)
            .foregroundStyle(theme.textTertiary)
            .help("All profiles")
            .accessibilityHidden(true)
    }
}

extension WorkLabel {
    /// Offered in every profile: no profile, or its profile was deleted. False for a deleted label.
    @MainActor var isAvailableEverywhere: Bool {
        ModelLiveness.isLive(self) && ModelLiveness.live(profile) == nil
    }
}

extension WorkTag {
    /// Offered in every profile: no profile, or its profile was deleted. False for a deleted tag.
    @MainActor var isAvailableEverywhere: Bool {
        ModelLiveness.isLive(self) && ModelLiveness.live(profile) == nil
    }
}

/// Per-profile default labels (`WorkProfile.defaultLabelUUID`).
@MainActor
enum SettingsDefaultLabels {
    /// Clears every profile's default that points to `label` (it was archived). Does not save.
    static func clear(_ label: WorkLabel, in context: ModelContext) {
        guard ModelLiveness.isLive(label) else { return }
        let id = label.uuid
        for profile in ProfileOps.allProfiles(in: context) where profile.defaultLabelUUID == id {
            profile.defaultLabelUUID = nil
            profile.touch()
        }
    }
}
