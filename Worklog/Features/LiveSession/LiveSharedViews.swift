import AppKit
import Combine
import SwiftData
import SwiftUI

// Building blocks shared by Feature A's surfaces: the Today page (LiveSessionView), the end-of-session
// sheet, the menu bar panel and the floating overlay. Every type here carries the `Live…` prefix (§1.3).

// MARK: - Live clock

/// Re-renders `content` once per second while the session runs (TimelineView); renders it once, statically,
/// while paused or idle. Always compute durations from the date passed in (never accumulate).
@MainActor
struct LiveClock<Content: View>: View {
    private let isTicking: Bool
    private let content: (Date) -> Content

    init(isTicking: Bool, @ViewBuilder content: @escaping (Date) -> Content) {
        self.isTicking = isTicking
        self.content = content
    }

    var body: some View {
        if isTicking {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}

// MARK: - Today's sessions (query)

/// Fetches sessions that started since two days before today (enough to catch sessions crossing midnight)
/// with `@Query`, so no view fetches inside `body`. At midnight (`NSCalendarDayChanged`) the query is rebuilt
/// for the new day and the content re-renders, so "today" never goes stale while the app stays open.
@MainActor
struct LiveTodaySessionsQuery<Content: View>: View {
    private let content: ([WorkSession]) -> Content
    @State private var day = Date().startOfDay

    init(@ViewBuilder content: @escaping ([WorkSession]) -> Content) {
        self.content = content
    }

    var body: some View {
        LiveTodaySessionsResults(day: day, content: content)
            .id(day)
            .onReceive(LiveDayChange.publisher) { _ in
                day = Date().startOfDay
            }
            .onAppear {
                let today = Date().startOfDay
                if today != day { day = today }
            }
    }
}

@MainActor
private struct LiveTodaySessionsResults<Content: View>: View {
    @Query private var sessions: [WorkSession]
    private let content: ([WorkSession]) -> Content

    init(day: Date, content: @escaping ([WorkSession]) -> Content) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: day)
            ?? day.addingTimeInterval(-2 * 86_400)
        _sessions = Query(filter: #Predicate<WorkSession> { $0.startedAt >= cutoff },
                          sort: \WorkSession.startedAt, order: .reverse)
        self.content = content
    }

    var body: some View {
        // Drop objects deleted in this run loop turn (discard) before any child reads them.
        content(sessions.filter { LiveModelGuard.isUsable($0) })
    }
}

/// Midnight (or a clock/time-zone change that moves the day), delivered on the main queue.
enum LiveDayChange {
    static var publisher: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

/// Today-total math on already-fetched sessions (midnight-safe: clips every session to today's interval).
@MainActor
enum LiveDayMath {
    /// Active seconds today across `sessions` (+ `active` if the query missed it, e.g. started > 2 days ago).
    static func totalToday(_ sessions: [WorkSession], active: WorkSession?, now: Date) -> TimeInterval {
        let today = now.dayInterval
        var all = sessions.filter { LiveModelGuard.isUsable($0) }
        if let active, LiveModelGuard.isUsable(active), !all.contains(where: { $0 === active }) {
            all.append(active)
        }
        return all.reduce(0) { $0 + $1.activeDuration(in: today, now: now) }
    }

    /// Ended sessions that overlap today, newest first.
    static func endedToday(_ sessions: [WorkSession], now: Date) -> [WorkSession] {
        let today = now.dayInterval
        return sessions
            .filter { session in
                guard LiveModelGuard.isUsable(session), let end = session.endedAt else { return false }
                return end > today.start && session.startedAt < today.end
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func goalSeconds(_ settings: AppSettings) -> TimeInterval {
        max(0, settings.dailyGoalHours) * 3600
    }
}

/// A model object deleted in this context (discard) must never be read again: SwiftData traps on a
/// destroyed backing store. Views holding a session/segment check this first.
@MainActor
enum LiveModelGuard {
    static func isUsable(_ model: some PersistentModel) -> Bool {
        !model.isDeleted && model.modelContext != nil
    }
}

/// Start/split choices are held in `@State` across Settings edits: a label or tag picked earlier may have been
/// deleted, merged or archived since. Resolve them right before handing them to the engine.
@MainActor
enum LiveStartChoice {
    /// The picked label if it can still be used; a picked-but-gone label falls back to the default label.
    /// `nil` (the user chose "None") stays `nil`.
    static func label(_ picked: WorkLabel?, engine: SessionEngine) -> WorkLabel? {
        guard let picked else { return nil }
        if isUsable(picked) { return picked }
        return engine.defaultLabel()
    }

    /// Like `label(_:engine:)`, but a gone label becomes `nil` (the engine then keeps the current label).
    static func splitLabel(_ picked: WorkLabel?) -> WorkLabel? {
        guard let picked, isUsable(picked) else { return nil }
        return picked
    }

    static func tags(_ picked: [WorkTag]) -> [WorkTag] {
        picked.filter { LiveModelGuard.isUsable($0) && !$0.isArchived }
    }

    static func isUsable(_ label: WorkLabel) -> Bool {
        LiveModelGuard.isUsable(label) && !label.isArchived
    }

    /// Same rule as `SessionEngine.defaultLabel()`, computed from `@Query` results (no fetch in `body`).
    static func defaultLabel(in labels: [WorkLabel], settings: AppSettings) -> WorkLabel? {
        let active = labels.filter { isUsable($0) }
        if let id = settings.defaultLabelID, let match = active.first(where: { $0.uuid == id }) {
            return match
        }
        return active.first
    }
}

// MARK: - Environment bridge for popovers

/// Popovers and inline sub-windows are hosted in their own window; pass the services and theme explicitly so
/// `@Environment(SessionEngine.self)`, `@Query` (LabelPicker/TagPicker) and `\.theme` always resolve there.
struct LiveEnvironmentBridge: ViewModifier {
    let engine: SessionEngine
    let theme: Theme
    let context: ModelContext

    init(engine: SessionEngine, theme: Theme, context: ModelContext) {
        self.engine = engine
        self.theme = theme
        self.context = context
    }

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .environment(\.theme, theme)
            .modelContext(context)
            .font(theme.bodyFont)
            .tint(theme.accent)
    }
}

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
                LabelPicker(selection: $label, includeNone: false, title: "Label")
                    .labelsHidden()
                    .controlSize(.small)
                LiveTagMenu(selection: $tags, scopeLabel: label)
            } else {
                LabelPicker(selection: $label, includeNone: false, title: "Label")
                    .fixedSize()
                HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                    Text("Tags")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textSecondary)
                    TagPicker(selection: $tags, scopeLabel: label)
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
            tags = current?.tagList ?? []
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
            engine.updateCurrentSegment(label: safeLabel ?? LiveStartChoice.splitLabel(engine.currentLabel),
                                        tags: safeTags, focus: focus)
        }
        onFinish()
    }
}

// MARK: - Tag menu (native, for panels)

/// Native pull-down menu of tags with checkmarks: label-scoped tags first, then global tags, then other labels'
/// tags in a submenu. Native menus never take key status, so this is safe inside the menu bar window/overlay.
@MainActor
struct LiveTagMenu: View {
    @Environment(\.theme) private var theme
    @Query(sort: \WorkTag.name) private var allTags: [WorkTag]
    @Binding private var selection: [WorkTag]
    private let scopeLabel: WorkLabel?

    init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel?) {
        self._selection = selection
        self.scopeLabel = scopeLabel
    }

    var body: some View {
        // Never read a tag or label deleted/merged in Settings while this menu is on screen.
        let active = ModelLiveness.live(allTags).filter { !$0.isArchived }
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
        selection.filter { LiveModelGuard.isUsable($0) }
    }

    private var summary: String {
        let live = liveSelection
        return live.isEmpty ? "Add tags" : live.map(\.name).joined(separator: ", ")
    }

    private func toggle(for tag: WorkTag) -> some View {
        let tagID = tag.persistentModelID
        return Toggle(tag.name, isOn: Binding(
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

// MARK: - Quick note field

/// Single-line note composer: Return adds a timestamped note to the running session (engine.addNote),
/// clears the field and keeps focus. Shows a short confirmation line.
@MainActor
struct LiveQuickNoteField: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    private let prompt: String
    private let isCompact: Bool
    private var externalFocus: FocusState<Bool>.Binding?

    @State private var text = ""
    @State private var confirmation: String?
    @State private var confirmationToken = 0
    @FocusState private var internalFocus: Bool

    init(prompt: String = "Quick note…", isCompact: Bool = false) {
        self.prompt = prompt
        self.isCompact = isCompact
        self.externalFocus = nil
    }

    init(prompt: String, isCompact: Bool = false, isFocused: FocusState<Bool>.Binding) {
        self.prompt = prompt
        self.isCompact = isCompact
        self.externalFocus = isFocused
    }

    private var focusBinding: FocusState<Bool>.Binding { externalFocus ?? $internalFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(spacing: theme.spacingXS) {
                TextField("Note", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .font(isCompact ? theme.calloutFont : theme.bodyFont)
                    .focused(focusBinding)
                    .onSubmit(submit)
                    .onExitCommand { focusBinding.wrappedValue = false }
                    .accessibilityLabel("Note")
                    .accessibilityHint("Return adds a timestamped note.")
                Image(systemName: "return")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .insetField(isFocused: focusBinding.wrappedValue)
            .disabled(!engine.isActive)

            if let confirmation {
                Text(confirmation)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .transition(.opacity)
            }
        }
    }

    private func submit() {
        guard let note = engine.addNote(text) else { return }
        text = ""
        focusBinding.wrappedValue = true
        confirmation = "Note added at \(note.createdAt.shortTime)"
        confirmationToken += 1
        let token = confirmationToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            if confirmationToken == token { confirmation = nil }
        }
    }
}

// MARK: - Takeaway

/// "Last takeaway" block: quote glyph, the takeaway text, "title · day" metadata (a link that opens the source
/// session in History) and a "Done" checkmark (`engine.dismissTakeaway()`: the takeaway stops showing everywhere).
@MainActor
struct LiveTakeawayView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(WindowRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let takeaway: SessionTakeaway
    private let lineLimit: Int?
    private let showsTitle: Bool
    private let isCompact: Bool
    private let showsDone: Bool

    init(takeaway: SessionTakeaway, lineLimit: Int? = nil, showsTitle: Bool = true, isCompact: Bool = false,
         showsDone: Bool = true) {
        self.takeaway = takeaway
        self.lineLimit = lineLimit
        self.showsTitle = showsTitle
        self.isCompact = isCompact
        self.showsDone = showsDone
    }

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                Image(systemName: "quote.opening")
                    .font(theme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    VStack(alignment: .leading, spacing: theme.spacingXS) {
                        if showsTitle {
                            Text("Last takeaway")
                                .font(theme.captionFont.weight(.semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Text(takeaway.text)
                            .font(isCompact ? theme.calloutFont : theme.bodyFont)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(lineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)

                    Button(action: openSource) {
                        Text(meta)
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open session")
                    .accessibilityLabel("From \(meta)")
                    .accessibilityHint("Opens the session in History.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsDone {
                Button {
                    engine.dismissTakeaway()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(IconButtonStyle(size: isCompact ? 20 : 24))
                .foregroundStyle(theme.textTertiary)
                .accessibilityLabel("Done with this takeaway")
                .help("Done")
            }
        }
        .accessibilityElement(children: .contain)
        .help(takeaway.text)
    }

    private var meta: String {
        "\(takeaway.title) · \(takeaway.date.relativeDayTitle)"
    }

    private var accessibilityText: String {
        "Last takeaway: \(takeaway.text)"
    }

    /// Fetches the source session on click only (never in `body`).
    private func openSource() {
        let uuid = takeaway.sessionUUID
        var descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        guard let session = try? modelContext.fetch(descriptor).first, LiveModelGuard.isUsable(session) else {
            return
        }
        router.showSession(session)
    }
}

// MARK: - Other-Mac hint

/// Subtle hint while the active session is controlled from another Mac (synced through iCloud).
@MainActor
struct LiveOtherMacHint: View {
    @Environment(\.theme) private var theme

    init() {}

    var body: some View {
        Label("Running on another Mac", systemImage: "laptopcomputer")
            .font(theme.captionFont)
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
            .help("Running on another Mac")
    }
}

// MARK: - Row style

/// Full-width plain row with a subtle hover fill (today's sessions, menu-like rows).
struct LiveHoverRowStyle: ButtonStyle {
    private let hoverOpacity: Double

    init(hoverOpacity: Double = 0.05) {
        self.hoverOpacity = hoverOpacity
    }

    func makeBody(configuration: Configuration) -> some View {
        LiveHoverRowBody(configuration: configuration, hoverOpacity: hoverOpacity)
    }
}

private struct LiveHoverRowBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverOpacity: Double
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, hoverOpacity: Double) {
        self.configuration = configuration
        self.hoverOpacity = hoverOpacity
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .background(shape.fill(theme.textPrimary.opacity(
                configuration.isPressed ? hoverOpacity * 2 : (isHovering ? hoverOpacity : 0))))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Request ledger

/// `WindowRouter.noteFocusRequest` / `splitRequest` are counters. LiveSessionView may be created *after* the
/// increment (the request also switches to Today), so `.onChange` alone would miss it; remember what was handled.
@MainActor
enum LiveRequestLedger {
    static var handledNoteFocusRequest = 0
    static var handledSplitRequest = 0
}
