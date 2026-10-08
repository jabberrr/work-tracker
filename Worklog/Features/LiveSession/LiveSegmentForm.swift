import SwiftData
import SwiftUI

// MARK: - Segment form (split / edit current segment)

enum LiveSegmentFormMode {
    /// Close the current segment and open a new one (engine.split).
    case split
    /// Change the current segment in place (engine.updateCurrentSegment).
    case edit
}

enum LiveSegmentFormStyle {
    /// Main window popover: full TagPicker (its own popover).
    case popover
    /// Menu bar panel / overlay: tags via a native menu (no nested popover, which would steal key status and
    /// close the menu bar window, or activate the app from the non-activating overlay).
    case inline
    /// Like `.inline`, narrower spacing for the compact overlay.
    case inlineCompact
}

/// Focus + label + tags for a new segment (split) or for the current segment (edit).
@MainActor
struct LiveSegmentForm: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    private let mode: LiveSegmentFormMode
    private let style: LiveSegmentFormStyle
    private let onFinish: () -> Void

    @State private var focus = ""
    @State private var label: WorkLabel?
    @State private var tags: [WorkTag] = []
    @State private var didLoad = false
    @FocusState private var focusFieldFocused: Bool

    init(mode: LiveSegmentFormMode, style: LiveSegmentFormStyle, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.style = style
        self.onFinish = onFinish
    }

    private var isInline: Bool { style != .popover }
    /// Labels and tags offered here are the running session's profile's (not the selected profile's).
    private var profileID: UUID? { engine.activeSessionProfileID }
    private var spacing: CGFloat { style == .inlineCompact ? theme.spacingS : theme.spacingM }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(mode == .split ? "Split segment" : "This segment")
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            TextField(mode == .split ? "New focus" : "Focus", text: $focus, prompt: Text(focusPrompt))
                .textFieldStyle(.plain)
                .focused($focusFieldFocused)
                .insetField(isFocused: focusFieldFocused)
                .onSubmit(commit)
                .accessibilityLabel(mode == .split ? "New focus" : "Focus")

            if isInline {
                LabelPicker(selection: $label, includeNone: false, title: "Label", profileID: profileID)
                    .labelsHidden()
                    .controlSize(.small)
                LiveTagMenu(selection: $tags, scopeLabel: label, profileID: profileID)
            } else {
                LabelPicker(selection: $label, includeNone: false, title: "Label", profileID: profileID)
                    .fixedSize()
                HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                    Text("Tags")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textSecondary)
                    TagPicker(selection: $tags, scopeLabel: label, profileID: profileID)
                }
            }

            HStack(spacing: theme.spacingS) {
                Spacer(minLength: 0)
                Button("Cancel", action: onFinish)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: commit) {
                    if mode == .split {
                        Label("Split", systemImage: "scissors")
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help(mode == .split ? "Split segment" : "Save")
            }
            .controlSize(isInline ? .small : .regular)
        }
        .onAppear(perform: load)
    }

    private var focusPrompt: String {
        mode == .split ? "What are you switching to?" : "What are you focusing on?"
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let current = engine.currentSegment
        switch mode {
        case .split:
            focus = ""
            label = engine.currentLabel
            tags = current?.tagList ?? []
        case .edit:
            focus = current?.focus ?? ""
            label = current?.effectiveLabel ?? engine.currentLabel
            tags = editableTags(current)
        }
        // Give the hosting window a moment to become key before focusing the field.
        Task { @MainActor in
            await Task.yield()
            focusFieldFocused = true
        }
    }

    private func commit() {
        guard engine.isActive else {
            onFinish()
            return
        }
        // Label/tags may have been deleted or archived in Settings while the form was open.
        let safeLabel = LiveStartChoice.splitLabel(label)
        let safeTags = LiveStartChoice.tags(tags)
        switch mode {
        case .split:
            engine.split(label: safeLabel, tags: safeTags, focus: focus)
        case .edit:
            let movesSessionTags = sessionTagsFollowSegment
            engine.updateCurrentSegment(label: safeLabel ?? LiveStartChoice.splitLabel(engine.currentLabel),
                                        tags: safeTags, focus: focus)
            if movesSessionTags, let session = ModelLiveness.live(engine.activeSession) {
                // The form showed them as this segment's tags (now saved there): drop the session-level copy so a
                // tag removed here is really gone.
                session.tagList = []
                session.touch()
                engine.save()
            }
        }
        onFinish()
    }

    /// One-segment session with session-level tags (sessions started before start tags moved to the first
    /// segment): those tags are this segment's too, so the edit form shows and edits them with it.
    private var sessionTagsFollowSegment: Bool {
        guard let session = ModelLiveness.live(engine.activeSession) else { return false }
        return (session.segments ?? []).count == 1 && !session.tagList.isEmpty
    }

    /// The current segment's tags, plus the session's own tags when they follow this segment (see above).
    private func editableTags(_ segment: Segment?) -> [WorkTag] {
        let segmentTags = segment?.tagList ?? []
        guard sessionTagsFollowSegment, let session = ModelLiveness.live(engine.activeSession) else {
            return segmentTags
        }
        var seen = Set<UUID>()
        return (segmentTags + session.tagList).filter { ModelLiveness.isLive($0) && seen.insert($0.uuid).inserted }
    }
}

// MARK: - Tag menu (native, for panels)

/// Native pull-down menu of tags with checkmarks: label-scoped tags first, then global tags, then other labels'
/// tags in a submenu. Only tags offered in `profileID` are listed (plus any selected tag that isn't, so it can be
/// removed). Native menus never take key status, so this is safe inside the menu bar window/overlay.
@MainActor
struct LiveTagMenu: View {
    @Environment(\.theme) private var theme
    @Query(sort: \WorkTag.name) private var allTags: [WorkTag]
    @Binding private var selection: [WorkTag]
    private let scopeLabel: WorkLabel?
    private let profileID: UUID?

    init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel?, profileID: UUID?) {
        self._selection = selection
        self.scopeLabel = scopeLabel
        self.profileID = profileID
    }

    var body: some View {
        // Never read a tag or label deleted/merged in Settings while this menu is on screen.
        let profileScope = ProfileScope(profileID: profileID)
        let selectedIDs = Set(liveSelection.map(\.persistentModelID))
        let active = ModelLiveness.live(allTags).filter { tag in
            (!tag.isArchived && profileScope.offers(tag)) || selectedIDs.contains(tag.persistentModelID)
        }
        let scope = ModelLiveness.live(scopeLabel)
        let scopeID = scope?.persistentModelID
        let scoped = active.filter { ModelLiveness.live($0.label)?.persistentModelID == scopeID && scopeID != nil }
        let global = active.filter { ModelLiveness.live($0.label) == nil }
        let others = active.filter { tag in
            guard let parent = ModelLiveness.live(tag.label) else { return false }
            return parent.persistentModelID != scopeID
        }

        Menu {
            if !scoped.isEmpty {
                Section(scope?.name ?? "Label") {
                    ForEach(scoped) { tag in toggle(for: tag) }
                }
            }
            if !global.isEmpty {
                Section("Global") {
                    ForEach(global) { tag in toggle(for: tag) }
                }
            }
            if !others.isEmpty {
                Menu("Other labels") {
                    ForEach(others) { tag in toggle(for: tag) }
                }
            }
            if active.isEmpty {
                Text("No tags yet")
            }
            if !liveSelection.isEmpty {
                Divider()
                Button("Clear tags") { selection = [] }
            }
        } label: {
            Label(summary, systemImage: "number")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(theme.textSecondary)
        .accessibilityLabel("Tags")
        .accessibilityValue(liveSelection.isEmpty ? "None" : summary)
        .help("Tags")
    }

    /// Never read a tag deleted or merged in Settings while this menu was on screen.
    private var liveSelection: [WorkTag] {
        ModelLiveness.live(selection)
    }

    private var summary: String {
        let live = liveSelection
        return live.isEmpty ? "Add tags" : live.map(\.name).joined(separator: ", ")
    }

    private func toggle(for tag: WorkTag) -> some View {
        let tagID = tag.persistentModelID
        return Toggle(ScopedItemTitle.title(for: tag, in: ProfileScope(profileID: profileID)), isOn: Binding(
            get: { liveSelection.contains(where: { $0.persistentModelID == tagID }) },
            set: { isOn in
                var next = liveSelection
                if isOn {
                    if !next.contains(where: { $0.persistentModelID == tagID }) {
                        next.append(tag)
                    }
                } else {
                    next.removeAll { $0.persistentModelID == tagID }
                }
                selection = next
            }
        ))
    }
}
