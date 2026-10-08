import SwiftUI
import SwiftData

/// Chips for selected tags (removable) + "+" popover: search field, tags scoped to `scopeLabel` first,
/// then tags for any label; if allowsCreate, "Create “x”" → `TaxonomyOps.createTag(name:profile:in:)` via
/// @Environment(\.modelContext): the new tag is local to `profileID`'s profile (global when `profileID` is nil).
/// When the query names an ARCHIVED tag offered there, the row reads "Unarchive “x”" instead: it brings that tag
/// back and selects it (no second tag with the same name).
///
/// Profile scope: only tags offered in `profileID` (global + local to it) are listed; `profileID == nil` offers
/// every tag. Selected tags that aren't offered (local to another profile) keep their chip and are listed under
/// "Other profiles" with their profile's name, so they can be removed.
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
    private let profileID: UUID?
    private let allowsCreate: Bool
    @State private var isPresented = false

    init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel? = nil, profileID: UUID?, allowsCreate: Bool = true) {
        self._selection = selection
        self.scopeLabel = scopeLabel
        self.profileID = profileID
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
        let scope = ProfileScope(profileID: profileID)
        let offered = liveTags.filter { scope.offers($0) }
        let foreign = chips.filter { !scope.offers($0) }
        let foreignNames = Dictionary(
            foreign.map { ($0.persistentModelID, ScopedItemTitle.foreignProfileName(of: $0, in: scope) ?? "") },
            uniquingKeysWith: { first, _ in first })
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
                                 allTags: offered,
                                 foreignTags: foreign,
                                 foreignProfileNames: foreignNames,
                                 scopeLabel: ModelLiveness.live(scopeLabel),
                                 allowsCreate: allowsCreate,
                                 profileScoped: profileID != nil,
                                 onCreate: create,
                                 onUnarchive: unarchive)
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
        // Fetched here (an action), never in `body`. A missing profile (nil id, or deleted) creates a global tag.
        let profile = ProfileOps.profile(withID: profileID, in: modelContext)
        let tag = TaxonomyOps.createTag(name: trimmed, profile: profile, in: modelContext)
        var current = ModelLiveness.live(selection)
        if !current.contains(where: { $0.persistentModelID == tag.persistentModelID }) {
            current.append(tag)
        }
        selection = current
    }

    /// "Unarchive “x”": brings the archived tag back (`TaxonomyOps.unarchive(_:)`, saves) and selects it.
    private func unarchive(_ tag: WorkTag) {
        guard ModelLiveness.isLive(tag) else { return }
        TaxonomyOps.unarchive(tag)
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
    /// Live tags offered in the picker's profile.
    let allTags: [WorkTag]
    /// Live selected tags NOT offered in the picker's profile (local to another profile).
    let foreignTags: [WorkTag]
    /// Profile name of each foreign tag, by persistentModelID.
    let foreignProfileNames: [PersistentIdentifier: String]
    let scopeLabel: WorkLabel?
    let allowsCreate: Bool
    /// Mirrors `TaxonomyOps.createTag`: with a profile, any offered tag counts; without one, global tags only.
    let profileScoped: Bool
    let onCreate: (String) -> Void
    let onUnarchive: (WorkTag) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(selection: Binding<[WorkTag]>, allTags: [WorkTag], foreignTags: [WorkTag],
         foreignProfileNames: [PersistentIdentifier: String], scopeLabel: WorkLabel?,
         allowsCreate: Bool, profileScoped: Bool,
         onCreate: @escaping (String) -> Void, onUnarchive: @escaping (WorkTag) -> Void) {
        self._selection = selection
        self.allTags = allTags
        self.foreignTags = foreignTags
        self.foreignProfileNames = foreignProfileNames
        self.scopeLabel = scopeLabel
        self.allowsCreate = allowsCreate
        self.profileScoped = profileScoped
        self.onCreate = onCreate
        self.onUnarchive = onUnarchive
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

    /// Selected tags of other profiles that match the query (listed so they can be unselected).
    private var otherProfileTags: [WorkTag] {
        foreignTags.filter { matches($0) }
    }

    private var exactMatch: WorkTag? {
        (activeTags + foreignTags).first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
    }

    /// An archived tag named like the query (trimmed, case-/diacritic-insensitive) when no active one is: the tag
    /// `TaxonomyOps.createTag` would unarchive (same rule as `TaxonomyOps.archivedTag(named:profile:in:)`, computed
    /// from the offered tags so `body` doesn't fetch). The profile's own tag wins over a global one.
    private var archivedMatch: WorkTag? {
        guard allowsCreate, !trimmedQuery.isEmpty, exactMatch == nil else { return nil }
        let named = allTags.filter { tag in
            tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (profileScoped || ModelLiveness.live(tag.profile) == nil)
        }
        guard !named.contains(where: { !$0.isArchived }) else { return nil }
        return named.first { ModelLiveness.live($0.profile) != nil } ?? named.first
    }

    private var canCreate: Bool {
        allowsCreate && !trimmedQuery.isEmpty && exactMatch == nil && archivedMatch == nil
    }

    var body: some View {
        let scoped = scopedTags
        let global = globalTags
        let others = otherTags
        let foreign = otherProfileTags
        let nothing = scoped.isEmpty && global.isEmpty && others.isEmpty && foreign.isEmpty
        let archived = archivedMatch

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
                        group(title: scope.name, tags: scoped, caption: { _ in nil })
                    }
                    group(title: scopeLabel == nil ? "Tags" : "Any label", tags: global, caption: { _ in nil })
                    group(title: "Other labels", tags: others, caption: { parentLabel(of: $0)?.name })
                    group(title: "Other profiles", tags: foreign, caption: { foreignProfileNames[$0.persistentModelID] })
                    if nothing && !canCreate && archived == nil {
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
            } else if let archived {
                Rectangle().fill(theme.separator).frame(height: 1)
                Button {
                    unarchive(archived)
                } label: {
                    HStack(spacing: theme.spacingS) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(theme.accent)
                        Text("Unarchive “\(archived.name)”")
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
    private func group(title: String, tags: [WorkTag], caption: @escaping (WorkTag) -> String?) -> some View {
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
                row(tag, caption: caption(tag))
            }
        }
    }

    /// `caption`: trailing tertiary text (the parent label, or another profile's name).
    private func row(_ tag: WorkTag, caption: String?) -> some View {
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
                if let caption, !caption.isEmpty {
                    Text(caption)
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

    private func unarchive(_ tag: WorkTag) {
        onUnarchive(tag)
        query = ""
    }

    /// Return: exact match → toggle; else unarchive an archived match; else create if allowed;
    /// else the single visible match → toggle.
    private func submit() {
        guard !trimmedQuery.isEmpty else { return }
        if let exact = exactMatch {
            toggle(exact)
            query = ""
        } else if let archived = archivedMatch {
            unarchive(archived)
        } else if canCreate {
            createFromQuery()
        } else {
            let visible = scopedTags + globalTags + otherTags + otherProfileTags
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
