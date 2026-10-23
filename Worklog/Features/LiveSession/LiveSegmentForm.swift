import AppKit
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
            tags = LiveCurrentSegmentTags.editable(engine)
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
            let movesSessionTags = LiveCurrentSegmentTags.sessionTagsFollowSegment(engine)
            let picked = safeLabel ?? LiveStartChoice.splitLabel(engine.currentLabel)
            engine.updateCurrentSegment(label: LiveCurrentSegmentTags.labelToWrite(picked, engine: engine),
                                        tags: safeTags, focus: focus)
            if movesSessionTags {
                LiveCurrentSegmentTags.dropSessionTags(engine)
            }
        }
        onFinish()
    }
}

// MARK: - Current segment's tags

/// The running segment's tags as the edit form and the panels' tag menus show them, and the in-place saves behind
/// the panels' tag and label menus. Writes go through `engine.updateCurrentSegment(label:tags:focus:)`.
@MainActor
enum LiveCurrentSegmentTags {
    /// One-segment session with session-level tags (sessions started before start tags moved to the first
    /// segment): those tags are this segment's too, so they are shown and edited with it.
    static func sessionTagsFollowSegment(_ engine: SessionEngine) -> Bool {
        guard let session = ModelLiveness.live(engine.activeSession) else { return false }
        return (session.segments ?? []).count == 1 && !session.tagList.isEmpty
    }

    /// The current segment's live tags, plus the session's own tags when they follow this segment (see above).
    /// Empty when idle.
    static func editable(_ engine: SessionEngine) -> [WorkTag] {
        guard let segment = engine.currentSegment else { return [] }
        let segmentTags = segment.tagList
        guard sessionTagsFollowSegment(engine), let session = ModelLiveness.live(engine.activeSession) else {
            return ModelLiveness.live(segmentTags)
        }
        var seen = Set<UUID>()
        return (segmentTags + session.tagList).filter { ModelLiveness.isLive($0) && seen.insert($0.uuid).inserted }
    }

    /// Sets the current segment's tags in place, keeping its label and focus. No-op when idle.
    static func save(_ tags: [WorkTag], engine: SessionEngine) {
        guard let segment = engine.currentSegment else { return }
        let movesSessionTags = sessionTagsFollowSegment(engine)
        engine.updateCurrentSegment(label: labelToWrite(engine.currentLabel, engine: engine),
                                    tags: ModelLiveness.live(tags), focus: segment.focus)
        if movesSessionTags {
            dropSessionTags(engine)
        }
    }

    /// Sets the current segment's label in place, keeping its tags (session-level ones stay where they are) and
    /// focus. No-op when idle or when `label` is gone.
    static func saveLabel(_ label: WorkLabel, engine: SessionEngine) {
        guard let segment = engine.currentSegment, ModelLiveness.isLive(label) else { return }
        engine.updateCurrentSegment(label: labelToWrite(label, engine: engine),
                                    tags: ModelLiveness.live(segment.tagList), focus: segment.focus)
    }

    /// What to hand `updateCurrentSegment` for `label`: a later segment that inherits the session's label
    /// (`segment.label` nil) keeps inheriting when `label` is that same inherited label, instead of being pinned
    /// to it. A one-segment session gets `label` as is (the engine also writes it to the session, so nil would
    /// clear the session's label).
    static func labelToWrite(_ label: WorkLabel?, engine: SessionEngine) -> WorkLabel? {
        guard let session = ModelLiveness.live(engine.activeSession), let segment = engine.currentSegment,
              (session.segments ?? []).count > 1, ModelLiveness.live(segment.label) == nil,
              let label, let inherited = ModelLiveness.live(session.label),
              inherited.persistentModelID == label.persistentModelID else { return label }
        return nil
    }

    /// The session-level tags were shown as this segment's (now saved there): drop that copy so a tag removed
    /// from the segment is really gone.
    static func dropSessionTags(_ engine: SessionEngine) {
        guard let session = ModelLiveness.live(engine.activeSession) else { return }
        session.tagList = []
        session.touch()
        engine.save()
    }
}

/// The running segment's tags as a `LiveTagMenu`, saved as soon as a tag is toggled
/// (`LiveCurrentSegmentTags.save`). For the menu bar panel and the overlay. `showsSummary` false: just the
/// tag icon (the caller shows the chips).
@MainActor
struct LiveCurrentTagsMenu: View {
    @Environment(SessionEngine.self) private var engine
    private let showsSummary: Bool

    init(showsSummary: Bool) {
        self.showsSummary = showsSummary
    }

    var body: some View {
        LiveTagMenu(selection: selection, scopeLabel: engine.currentLabel,
                    profileID: engine.activeSessionProfileID, showsSummary: showsSummary)
    }

    private var selection: Binding<[WorkTag]> {
        Binding(
            get: { LiveCurrentSegmentTags.editable(engine) },
            set: { LiveCurrentSegmentTags.save($0, engine: engine) }
        )
    }
}

/// The running segment's label as a native pull-down whose button is the `LabelBadge` itself (no indicator), for
/// the menu bar panel and the overlay. Lists the labels the split form offers (non-archived, offered in the
/// session's profile, by sort order; plus the current one when it is archived or not offered), with a checkmark
/// on the current one. Picking one saves at once (`LiveCurrentSegmentTags.saveLabel`); tags and focus stay.
/// Native menus never take key status, so this is safe in the menu bar window and the non-activating overlay.
@MainActor
struct LiveCurrentLabelMenu: View {
    @Environment(SessionEngine.self) private var engine
    @Query(sort: \WorkLabel.sortIndex) private var allLabels: [WorkLabel]

    init() {}

    var body: some View {
        let current = engine.currentLabel
        let scope = ProfileScope(profileID: engine.activeSessionProfileID)
        let items = options(current: current, in: scope)
        let currentID = current?.persistentModelID

        Menu {
            ForEach(items) { label in
                item(for: label, isCurrent: label.persistentModelID == currentID, in: scope)
            }
            if items.isEmpty {
                Text("No labels yet")
            }
        } label: {
            LabelBadge(label: current, size: .small)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Change label")
        .accessibilityLabel("Change label")
        .accessibilityValue(current?.name ?? "Unlabeled")
    }

    /// Offered active labels, plus the current one when it is archived or not offered (so it shows checked).
    private func options(current: WorkLabel?, in scope: ProfileScope) -> [WorkLabel] {
        var list = ModelLiveness.live(allLabels).filter { !$0.isArchived && scope.offers($0) }
        if let current, !list.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            list.append(current)
        }
        return list
    }

    private func item(for label: WorkLabel, isCurrent: Bool, in scope: ProfileScope) -> some View {
        Toggle(isOn: Binding(
            get: { isCurrent },
            set: { isOn in
                if isOn { LiveCurrentSegmentTags.saveLabel(label, engine: engine) }
            }
        )) {
            Label {
                Text(ScopedItemTitle.title(for: label, in: scope))
            } icon: {
                Image(nsImage: LabelMenuIcon.image(symbol: label.symbolName, hex: label.colorHex))
                    .renderingMode(.original)
            }
        }
    }
}

// MARK: - Tag menu (native, for panels)

/// Native pull-down menu of tags with checkmarks: label-scoped tags first, then global tags, then other labels'
/// tags in a submenu. Only tags offered in `profileID` are listed (plus any selected tag that isn't, so it can be
/// removed). Native menus never take key status, so this is safe inside the menu bar window/overlay.
/// `showsSummary` false: the button is just the tag icon (no names, no indicator); the names stay in the help
/// and accessibility value.
@MainActor
struct LiveTagMenu: View {
    @Environment(\.theme) private var theme
    @Query(sort: \WorkTag.name) private var allTags: [WorkTag]
    @Binding private var selection: [WorkTag]
    private let scopeLabel: WorkLabel?
    private let profileID: UUID?
    private let showsSummary: Bool

    init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel?, profileID: UUID?, showsSummary: Bool = true) {
        self._selection = selection
        self.scopeLabel = scopeLabel
        self.profileID = profileID
        self.showsSummary = showsSummary
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
            if showsSummary {
                Label(summary, systemImage: "number")
                    .lineLimit(1)
            } else {
                Image(systemName: "number")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(showsSummary ? .visible : .hidden)
        .fixedSize(horizontal: !showsSummary, vertical: true)
        .foregroundStyle(theme.textSecondary)
        .accessibilityLabel("Tags")
        .accessibilityValue(liveSelection.isEmpty ? "None" : summary)
        .help(showsSummary || liveSelection.isEmpty ? "Tags" : "Tags: \(summary)")
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
