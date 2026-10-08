import SwiftData
import SwiftUI

/// Tags: filterable list (active / archived) + editor (name, availability, color, parent label, archive, merge,
/// delete). Lists the tags the current profile offers (global + its own); new tags are local to it.
@MainActor
struct SettingsTagsPane: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Query(sort: \WorkTag.name) private var tags: [WorkTag]
    @State private var selectedID: PersistentIdentifier?
    @State private var filterText = ""
    @State private var newTagName = ""

    private var filtered: [WorkTag] {
        let query = filterText.trimmed
        let base = liveTags
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (ModelLiveness.live($0.label)?.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// Every live tag (all profiles). The query can briefly include tags deleted or merged a moment ago; never
    /// read those.
    private var allLiveTags: [WorkTag] { ModelLiveness.live(tags) }
    /// Scope marks appear once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.profiles.count + profileStore.archivedProfiles.count > 1 }
    /// Tags the current profile offers (global + its own).
    private var liveTags: [WorkTag] {
        let scope = profileStore.activeScope
        return allLiveTags.filter { scope.offers($0) }
    }

    private var selectedTag: WorkTag? {
        guard let selectedID else { return nil }
        return liveTags.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            tagList
                .frame(width: 230)
            Divider()
            Group {
                if let tag = selectedTag {
                    SettingsTagEditor(tag: tag, allTags: allLiveTags, offeredTags: liveTags,
                                      onDeleted: { selectedID = nil },
                                      onMerged: { target in selectedID = target.persistentModelID })
                        .id(tag.persistentModelID)
                } else if liveTags.isEmpty {
                    EmptyStateView(title: "No tags", systemImage: "number",
                                   message: "Create one below.")
                } else {
                    EmptyStateView(title: "Select a tag", systemImage: "number")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: profileStore.activeProfileID) {
            selectedID = nil
            filterText = ""
        }
    }

    private var tagList: some View {
        let visible = filtered
        let active = visible.filter { !$0.isArchived }
        let archived = visible.filter { $0.isArchived }
        return VStack(spacing: 0) {
            SearchField(text: $filterText, prompt: "Filter tags")
                .padding(theme.spacingS)

            List(selection: $selectedID) {
                Section("Tags") {
                    ForEach(active) { tag in
                        row(tag).tag(tag.persistentModelID)
                    }
                }
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { tag in
                            row(tag).tag(tag.persistentModelID)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: theme.spacingXS) {
                TextField("New tag", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button(action: addTag) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .disabled(newTagName.isBlank)
                .help("Create tag")
                .accessibilityLabel("Create tag")
            }
            .padding(theme.spacingS)
        }
        .themedBackground(.sidebar)
    }

    private func row(_ tag: WorkTag) -> some View {
        HStack(spacing: theme.spacingS) {
            Image(systemName: "number")
                .foregroundStyle(tag.hasCustomColor ? tag.color : theme.textTertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(tag.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tag.isArchived ? theme.textSecondary : theme.textPrimary)
                if let parent = ModelLiveness.live(tag.label) {
                    Text(parent.name)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: theme.spacingXS)
            if showsScope && tag.isAvailableEverywhere {
                SettingsGlobalMark()
            }
            Text("\(tag.usageCount)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Times used")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(tag.usageCount) uses\(tag.isArchived ? ", archived" : "")"
                            + (showsScope && tag.isAvailableEverywhere ? ", all profiles" : ""))
    }

    private func addTag() {
        let name = newTagName.trimmed
        guard !name.isEmpty else { return }
        // Returns the existing active tag offered here when the name is taken (no duplicates); else a new tag
        // local to the current profile.
        let tag = TaxonomyOps.createTag(name: name, profile: ModelLiveness.live(profileStore.activeProfile),
                                        in: context)
        newTagName = ""
        filterText = ""
        selectedID = tag.persistentModelID
    }
}

// MARK: - Tag editor

@MainActor
private struct SettingsTagEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Bindable var tag: WorkTag
    /// Every live tag (all profiles); merge targets are narrowed by `TaxonomyOps.mergeTargets`.
    let allTags: [WorkTag]
    /// Tags the current profile offers (duplicate-name check).
    let offeredTags: [WorkTag]
    let onDeleted: () -> Void
    let onMerged: (WorkTag) -> Void

    @State private var draftName = ""
    @State private var duplicate: WorkTag?
    @FocusState private var nameFocused: Bool
    @State private var mergeTarget: WorkTag?
    @State private var confirmsDelete = false
    /// Set while "Make “x” Work only?" is asked (other profiles use the tag).
    @State private var pendingLocalProfileID: UUID?

    /// Merge targets that keep every session's tags offered in its profile, by name.
    private var otherTags: [WorkTag] {
        TaxonomyOps.mergeTargets(for: tag, among: ModelLiveness.live(allTags))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var currentProfile: WorkProfile? { ModelLiveness.live(profileStore.activeProfile) }
    /// "Available in" appears once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.profiles.count + profileStore.archivedProfiles.count > 1 }

    private var scopeSelection: Binding<SettingsTaxonomyScope> {
        Binding(
            get: { tag.isAvailableEverywhere ? .allProfiles : .thisProfile },
            set: { requestScope($0) }
        )
    }

    var body: some View {
        if tag.isDeleted || tag.modelContext == nil {
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
                if let duplicate {
                    HStack(spacing: theme.spacingS) {
                        Text("A tag named “\(duplicate.name)” already exists.")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if otherTags.contains(where: { $0.persistentModelID == duplicate.persistentModelID }) {
                            Button("Merge Into It…") { mergeTarget = duplicate }
                                .buttonStyle(QuietButtonStyle())
                                .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Preview") {
                    TagChip(tag: tag)
                }
                if showsScope, let profile = currentProfile {
                    SettingsScopePicker(selection: scopeSelection, profileName: profile.displayName)
                }
                LabelValuePicker("Parent label", selection: $tag.label, profileID: profileStore.activeProfileID)
                SettingsFootnote("Offered first when that label is picked.")
            }

            Section("Color") {
                LabelColorPicker(hex: $tag.colorHex)
                if tag.hasCustomColor {
                    Button("Reset Color") { tag.colorHex = LabelPalette.defaultTagHex }
                        .buttonStyle(QuietButtonStyle())
                        .controlSize(.small)
                }
            }

            Section("Usage") {
                SettingsFootnote(usageDescription)
            }

            Section {
                HStack(spacing: theme.spacingS) {
                    Button(tag.isArchived ? "Unarchive" : "Archive") {
                        tag.isArchived.toggle()
                        save()
                    }
                    .buttonStyle(QuietButtonStyle())
                    Menu("Merge Into") {
                        ForEach(otherTags) { other in
                            Button(other.isArchived ? "\(other.name) (archived)" : other.name) {
                                mergeTarget = other
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(otherTags.isEmpty)
                    .help("Merge tag")
                    Spacer()
                    Button("Delete…") { confirmsDelete = true }
                        .buttonStyle(DestructiveButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = tag.name }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .onChange(of: draftName) { duplicate = nil }
        .onDisappear {
            commitName()
            // Flush a color change still waiting in the debounce below.
            if !tag.isDeleted, tag.modelContext != nil, context.hasChanges { save() }
        }
        .task(id: tag.colorHex) {
            // The color wheel reports every drag tick: save once the color settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
        .onChange(of: tag.label) { save() }
        .confirmationDialog(
            mergeTarget.map { "Merge “\(tag.name)” into “\($0.name)”?" } ?? "Merge tags?",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                guard let target = mergeTarget else { return }
                mergeTarget = nil
                TaxonomyOps.mergeTag(tag, into: target, in: context)
                onMerged(target)
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("Moves its uses to “\(mergeTarget?.name ?? "")” and deletes it.")
        }
        .confirmationDialog("Delete “\(tag.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                TaxonomyOps.deleteTag(tag, in: context)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions are kept, but this can’t be undone.")
        }
        .confirmationDialog(
            "Make “\(tag.name)” \(profileStore.profile(withID: pendingLocalProfileID)?.displayName ?? "this profile") only?",
            isPresented: Binding(get: { pendingLocalProfileID != nil }, set: { if !$0 { pendingLocalProfileID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Make Local") {
                let profile = profileStore.profile(withID: pendingLocalProfileID)
                pendingLocalProfileID = nil
                guard let profile, ModelLiveness.isLive(tag) else { return }
                TaxonomyOps.setScope(of: tag, to: profile, in: context)
            }
            Button("Cancel", role: .cancel) { pendingLocalProfileID = nil }
        } message: {
            Text("Other profiles keep their own copy.")
        }
    }

    /// All profiles: always fine. This profile only: asks first when other profiles use the tag (each gets its
    /// own copy).
    private func requestScope(_ scope: SettingsTaxonomyScope) {
        guard ModelLiveness.isLive(tag) else { return }
        switch scope {
        case .allProfiles:
            guard !tag.isAvailableEverywhere else { return }
            TaxonomyOps.setScope(of: tag, to: nil, in: context)
        case .thisProfile:
            guard tag.isAvailableEverywhere, let profile = currentProfile else { return }
            if case .copiesForOtherProfiles = TaxonomyOps.scopeChangeImpact(of: tag, to: profile) {
                pendingLocalProfileID = profile.uuid
            } else {
                TaxonomyOps.setScope(of: tag, to: profile, in: context)
            }
        }
    }

    private var counts: (sessions: Int, segments: Int, points: Int) {
        (tag.sessions?.count ?? 0, tag.segments?.count ?? 0, tag.learningPoints?.count ?? 0)
    }

    /// "3 sessions · 2 segments · 4 learning points".
    private var usageDescription: String {
        let c = counts
        return "\(c.sessions) \(c.sessions == 1 ? "session" : "sessions") · "
            + "\(c.segments) \(c.segments == 1 ? "segment" : "segments") · "
            + "\(c.points) learning \(c.points == 1 ? "point" : "points")"
    }

    private func commitName() {
        guard !tag.isDeleted, tag.modelContext != nil else { return }
        let trimmed = draftName.trimmed
        guard !trimmed.isEmpty else {
            draftName = tag.name
            return
        }
        guard trimmed != tag.name else { return }
        if let existing = offeredTags.first(where: {
            $0.persistentModelID != tag.persistentModelID && ModelLiveness.isLive($0)
                && $0.name.trimmed.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            duplicate = existing
            return
        }
        tag.name = trimmed
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
