import SwiftUI
import SwiftData

/// Chips for selected tags (removable) + "+" popover: search field, tags scoped to `scopeLabel` first,
/// then global; if allowsCreate, "Create “x”" → TaxonomyOps.createTag(name:in:) via @Environment(\.modelContext).
///
/// Keyboard: in the popover, type to filter; Return toggles an exact/only match or creates the tag;
/// Esc clears the query, Esc again closes the popover.
/// The picker only edits the binding. Callers own `session.touch()` (e.g. `.onChange(of: session.tagList)`).
///
/// Tags in the binding that were deleted (or merged away) are treated as absent: they are never read or
/// shown, and the cleaned list is written back to the binding (on appear and whenever the tag list changes).
/// A deleted `scopeLabel` is treated as nil.
@MainActor
struct TagPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTag.name) private var allTags: [WorkTag]
    @Binding private var selection: [WorkTag]
    private let scopeLabel: WorkLabel?
    private let allowsCreate: Bool
    @State private var isPresented = false

    init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel? = nil, allowsCreate: Bool = true) {
        self._selection = selection
        self.scopeLabel = scopeLabel
        self.allowsCreate = allowsCreate
    }

    /// Live tags (the query can briefly include deleted-but-unsaved ones).
    private var liveTags: [WorkTag] { ModelLiveness.live(allTags) }

    /// The selection without deleted tags.
    private var liveSelection: [WorkTag] { ModelLiveness.live(selection) }

    /// Popover binding that never hands deleted tags to the list.
    private var safeSelection: Binding<[WorkTag]> {
        Binding(
            get: { ModelLiveness.live(selection) },
            set: { selection = $0 }
        )
    }

    var body: some View {
        let chips = liveSelection
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(chips) { tag in
                TagChip(tag: tag, onRemove: { remove(tag) })
            }
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 9 * theme.textScale, weight: .bold))
                    if chips.isEmpty {
                        Text("Add tag")
                    }
                }
            }
            .buttonStyle(TagPickerAddButtonStyle())
            .accessibilityLabel("Add tag")
            .help("Add tag")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                TagPickerPopover(selection: safeSelection,
                                 allTags: liveTags,
                                 scopeLabel: ModelLiveness.live(scopeLabel),
                                 allowsCreate: allowsCreate,
                                 onCreate: create)
                    .environment(\.theme, theme)
                    .tint(theme.accent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
        .onAppear(perform: dropDeletedTags)
        .onChange(of: liveTags.map(\.persistentModelID)) { _, _ in
            dropDeletedTags()
        }
    }

    /// Writes the selection back without tags that no longer exist.
    private func dropDeletedTags() {
        let cleaned = ModelLiveness.live(selection)
        if cleaned.count != selection.count {
            selection = cleaned
        }
    }

    private func remove(_ tag: WorkTag) {
        let id = tag.persistentModelID
        selection = ModelLiveness.live(selection).filter { $0.persistentModelID != id }
    }

    private func create(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = TaxonomyOps.createTag(name: trimmed, in: modelContext)
        var current = ModelLiveness.live(selection)
        if !current.contains(where: { $0.persistentModelID == tag.persistentModelID }) {
            current.append(tag)
        }
        selection = current
    }
}

// MARK: - Popover

@MainActor
private struct TagPickerPopover: View {
    @Environment(\.theme) private var theme
    @Binding var selection: [WorkTag]
    let allTags: [WorkTag]
    let scopeLabel: WorkLabel?
    let allowsCreate: Bool
    let onCreate: (String) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(selection: Binding<[WorkTag]>, allTags: [WorkTag], scopeLabel: WorkLabel?,
         allowsCreate: Bool, onCreate: @escaping (String) -> Void) {
        self._selection = selection
        self.allTags = allTags
        self.scopeLabel = scopeLabel
        self.allowsCreate = allowsCreate
        self.onCreate = onCreate
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var activeTags: [WorkTag] { allTags.filter { !$0.isArchived } }

    private func matches(_ tag: WorkTag) -> Bool {
        trimmedQuery.isEmpty || tag.name.localizedStandardContains(trimmedQuery)
    }

    /// A tag's scope label, nil when global or when that label was deleted.
    private func parentLabel(of tag: WorkTag) -> WorkLabel? {
        ModelLiveness.live(tag.label)
    }

    private var scopedTags: [WorkTag] {
        guard let scope = scopeLabel else { return [] }
        return activeTags.filter { parentLabel(of: $0)?.persistentModelID == scope.persistentModelID && matches($0) }
    }

    private var globalTags: [WorkTag] {
        activeTags.filter { parentLabel(of: $0) == nil && matches($0) }
    }

    /// Tags scoped to other labels: only offered while searching, to keep the list short.
    private var otherTags: [WorkTag] {
        guard !trimmedQuery.isEmpty else { return [] }
        return activeTags.filter { tag in
            guard let parent = parentLabel(of: tag) else { return false }
            return parent.persistentModelID != scopeLabel?.persistentModelID && matches(tag)
        }
    }

    private var exactMatch: WorkTag? {
        activeTags.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
    }

    private var canCreate: Bool {
        allowsCreate && !trimmedQuery.isEmpty && exactMatch == nil
    }

    var body: some View {
        let scoped = scopedTags
        let global = globalTags
        let others = otherTags
        let nothing = scoped.isEmpty && global.isEmpty && others.isEmpty

        VStack(spacing: 0) {
            SearchField(text: $query,
                        prompt: allowsCreate ? "Find or create a tag" : "Find a tag",
                        isFocused: $searchFocused)
                .onSubmit(submit)
                .padding(10)

            Rectangle().fill(theme.separator).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let scope = scopeLabel {
                        group(title: scope.name, tags: scoped, showsParent: false)
                    }
                    group(title: scopeLabel == nil ? "Tags" : "Global", tags: global, showsParent: false)
                    group(title: "Other labels", tags: others, showsParent: true)
                    if nothing && !canCreate {
                        Text(trimmedQuery.isEmpty ? "No tags yet." : "No matching tags.")
                            .font(theme.calloutFont)
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, theme.spacingL)
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 60, maxHeight: 260)

            if canCreate {
                Rectangle().fill(theme.separator).frame(height: 1)
                Button {
                    createFromQuery()
                } label: {
                    HStack(spacing: theme.spacingS) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(theme.accent)
                        Text("Create “\(trimmedQuery)”")
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TagPickerRowStyle())
                .padding(6)
            }
        }
        .frame(width: 260)
        .background(theme.elevatedSurface)
        .onAppear {
            // Let the popover window become key before focusing the field.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                searchFocused = true
            }
        }
    }

    @ViewBuilder
    private func group(title: String, tags: [WorkTag], showsParent: Bool) -> some View {
        if !tags.isEmpty {
            Text(title)
                .font(theme.captionFont.weight(.semibold))
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(tags) { tag in
                row(tag, showsParent: showsParent)
            }
        }
    }

    private func row(_ tag: WorkTag, showsParent: Bool) -> some View {
        let selected = isSelected(tag)
        return Button {
            toggle(tag)
        } label: {
            HStack(spacing: theme.spacingS) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                if tag.hasCustomColor {
                    ColorDot(hex: tag.colorHex, size: 7)
                }
                Text(tag.name)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsParent, let parent = parentLabel(of: tag) {
                    Text(parent.name)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(TagPickerRowStyle())
        .accessibilityLabel(tag.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isSelected(_ tag: WorkTag) -> Bool {
        selection.contains { $0.persistentModelID == tag.persistentModelID }
    }

    private func toggle(_ tag: WorkTag) {
        if isSelected(tag) {
            selection.removeAll { $0.persistentModelID == tag.persistentModelID }
        } else {
            selection.append(tag)
        }
    }

    private func createFromQuery() {
        guard canCreate else { return }
        onCreate(trimmedQuery)
        query = ""
    }

    /// Return: exact match → toggle; else create if allowed; else the single visible match → toggle.
    private func submit() {
        guard !trimmedQuery.isEmpty else { return }
        if let exact = exactMatch {
            toggle(exact)
            query = ""
        } else if canCreate {
            createFromQuery()
        } else {
            let visible = scopedTags + globalTags + otherTags
            if visible.count == 1, let only = visible.first {
                toggle(only)
                query = ""
            }
        }
    }
}

// MARK: - Styles

/// Dashed "add" chip matching TagChip metrics.
private struct TagPickerAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TagPickerAddButtonBody(configuration: configuration)
    }
}

private struct TagPickerAddButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        configuration.label
            .font(theme.labelFont)
            .foregroundStyle(isHovering ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .frame(minHeight: 18)
            .background(theme.chipShape.fill(configuration.isPressed
                                             ? theme.textPrimary.opacity(0.10)
                                             : (isHovering ? theme.textPrimary.opacity(0.05) : Color.clear)))
            .overlay {
                theme.chipShape.stroke(theme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .contentShape(theme.chipShape)
            .onHover { isHovering = $0 }
    }
}

/// Full-width list row with hover highlight (used in the popover).
private struct TagPickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TagPickerRowBody(configuration: configuration)
    }
}

private struct TagPickerRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        configuration.label
            .font(theme.bodyFont)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.accent.opacity(0.18)
                          : (isHovering ? theme.textPrimary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
