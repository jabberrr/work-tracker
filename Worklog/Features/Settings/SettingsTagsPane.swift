import SwiftData
import SwiftUI

/// Tags: filterable list (active / archived) + editor (name, color, parent label, archive, merge, delete).
struct SettingsTagsPane: View {
    @Environment(\.modelContext) private var context
    @Environment(\.theme) private var theme
    @Query(sort: \WorkTag.name) private var tags: [WorkTag]
    @State private var selectedID: PersistentIdentifier?
    @State private var filterText = ""
    @State private var newTagName = ""

    private var filtered: [WorkTag] {
        let query = filterText.trimmed
        let base = tags.filter { !$0.isDeleted }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || ($0.label?.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    private var selectedTag: WorkTag? {
        guard let selectedID else { return nil }
        return tags.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            tagList
                .frame(width: 230)
            Divider()
            Group {
                if let tag = selectedTag {
                    SettingsTagEditor(tag: tag, allTags: tags,
                                      onDeleted: { selectedID = nil },
                                      onMerged: { target in selectedID = target.persistentModelID })
                        .id(tag.persistentModelID)
                } else if tags.isEmpty {
                    EmptyStateView(title: "No tags", systemImage: "number",
                                   message: "Tags add detail to a label, like a project or a topic. Create one below or while starting a session.")
                } else {
                    EmptyStateView(title: "Select a tag", systemImage: "number",
                                   message: "Choose a tag to rename it, give it a color or a parent label, merge or archive it.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if let parent = tag.label {
                    Text(parent.name)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: theme.spacingXS)
            Text("\(tag.usageCount)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Sessions, segments and learning points using this tag")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(tag.usageCount) uses\(tag.isArchived ? ", archived" : "")")
    }

    private func addTag() {
        let name = newTagName.trimmed
        guard !name.isEmpty else { return }
        // Returns the existing active tag when the name is taken (no duplicates).
        let tag = TaxonomyOps.createTag(name: name, in: context)
        newTagName = ""
        filterText = ""
        selectedID = tag.persistentModelID
    }
}

// MARK: - Tag editor

private struct SettingsTagEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.theme) private var theme
    @Bindable var tag: WorkTag
    let allTags: [WorkTag]
    let onDeleted: () -> Void
    let onMerged: (WorkTag) -> Void

    @State private var draftName = ""
    @State private var duplicate: WorkTag?
    @FocusState private var nameFocused: Bool
    @State private var mergeTarget: WorkTag?
    @State private var confirmsDelete = false

    private var otherTags: [WorkTag] {
        allTags
            .filter { $0.persistentModelID != tag.persistentModelID && !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                        Button("Merge Into It…") { mergeTarget = duplicate }
                            .buttonStyle(QuietButtonStyle())
                            .controlSize(.small)
                    }
                }
                LabeledContent("Preview") {
                    TagChip(tag: tag)
                }
                LabelPicker(selection: $tag.label, includeNone: true, title: "Parent label")
                SettingsFootnote("A tag with a parent label is offered first when that label is picked. Without one, the tag is global.")
            }

            Section("Color") {
                LabelColorPicker(hex: $tag.colorHex)
                if tag.hasCustomColor {
                    Button("Use Default Gray") { tag.colorHex = LabelPalette.defaultTagHex }
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
                    .help(tag.isArchived ? "Offer this tag in pickers again" : "Hide from pickers. Past sessions keep the tag.")
                    Menu("Merge Into") {
                        ForEach(otherTags) { other in
                            Button(other.isArchived ? "\(other.name) (archived)" : other.name) {
                                mergeTarget = other
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(otherTags.isEmpty)
                    .help("Replace this tag with another one everywhere and remove it")
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
        .onDisappear(perform: commitName)
        .onChange(of: tag.colorHex) { save() }
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
            Text("Sessions, segments and learning points tagged “\(tag.name)” get “\(mergeTarget?.name ?? "")” instead, and “\(tag.name)” is deleted. This can’t be undone.")
        }
        .confirmationDialog("Delete the tag “\(tag.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                TaxonomyOps.deleteTag(tag, in: context)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from \(usageDescriptionShort). The sessions themselves are kept. This can’t be undone — archive it to just hide it.")
        }
    }

    private var counts: (sessions: Int, segments: Int, points: Int) {
        (tag.sessions?.count ?? 0, tag.segments?.count ?? 0, tag.learningPoints?.count ?? 0)
    }

    private var usageDescriptionShort: String {
        let c = counts
        return "\(c.sessions) \(c.sessions == 1 ? "session" : "sessions"), "
            + "\(c.segments) \(c.segments == 1 ? "segment" : "segments") and "
            + "\(c.points) learning \(c.points == 1 ? "point" : "points")"
    }

    private var usageDescription: String {
        "Used on \(usageDescriptionShort)."
    }

    private func commitName() {
        guard !tag.isDeleted, tag.modelContext != nil else { return }
        let trimmed = draftName.trimmed
        guard !trimmed.isEmpty else {
            draftName = tag.name
            return
        }
        guard trimmed != tag.name else { return }
        if let existing = otherTags.first(where: {
            $0.name.trimmed.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
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
