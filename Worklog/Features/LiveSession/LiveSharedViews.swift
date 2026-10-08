import AppKit
import Combine
import SwiftData
import SwiftUI

// Building blocks shared by Feature A's surfaces: the Today page (LiveSessionView), the end-of-session
// sheet, the menu bar panel and the floating overlay. Every type here carries the `Live…` prefix (§1.3).
// Elsewhere: the non-UI rules (`LiveDayMath`, `LiveStartChoice`, `LiveLongSessionRule`, `LiveProfileMove`) in
// Services/LiveSessionRules.swift, the tick view in LiveTicker.swift, the split/edit form and tag menu in
// LiveSegmentForm.swift, the takeaway editor in TakeawayField.swift.

// MARK: - Today's sessions (query)

/// Fetches sessions that started since two days before today (enough to catch sessions crossing midnight)
/// with `@Query`, so no view fetches inside `body`. At midnight (`NSCalendarDayChanged`) the query is rebuilt
/// for the new day and the content re-renders, so "today" never goes stale while the app stays open.
/// The content keeps its identity across midnight (no `.id(day)`): a half-typed note or open split form inside it
/// survives. Callers clip to today themselves (`LiveDayMath`), so a query still on yesterday's cutoff only
/// fetches a little more.
@MainActor
struct LiveTodaySessionsQuery<Content: View>: View {
    private let content: ([WorkSession]) -> Content
    @State private var day = Date().startOfDay

    init(@ViewBuilder content: @escaping ([WorkSession]) -> Content) {
        self.content = content
    }

    var body: some View {
        LiveTodaySessionsResults(day: day, content: content)
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
        content(ModelLiveness.live(sessions))
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

// MARK: - Environment bridge for popovers

/// Popovers and inline sub-windows are hosted in their own window; pass the services and theme explicitly so
/// `@Environment(SessionEngine.self)`, `@Environment(ProfileStore.self)`, `@Query` (LabelPicker/TagPicker) and
/// `\.theme` always resolve there.
struct LiveEnvironmentBridge: ViewModifier {
    let engine: SessionEngine
    let profiles: ProfileStore
    let theme: Theme
    let context: ModelContext

    init(engine: SessionEngine, profiles: ProfileStore, theme: Theme, context: ModelContext) {
        self.engine = engine
        self.profiles = profiles
        self.theme = theme
        self.context = context
    }

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .environment(profiles)
            .environment(\.theme, theme)
            .modelContext(context)
            .font(theme.bodyFont)
            .tint(theme.accent)
    }
}

// MARK: - Quick note field

/// Single-line note composer: Return adds a timestamped note to the running session (engine.addNote),
/// clears the field and keeps focus. Shows a short confirmation line.
///
/// `onDone` (the floating overlay): Esc, and Return after adding a note (or on an empty field), end editing and
/// call it, so the host can hand keyboard focus back (the overlay gives up key status).
@MainActor
struct LiveQuickNoteField: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    private let prompt: String
    private let isCompact: Bool
    private var externalFocus: FocusState<Bool>.Binding?
    private let onDone: (() -> Void)?

    @State private var text = ""
    @State private var confirmation: String?
    @State private var confirmationToken = 0
    @FocusState private var internalFocus: Bool

    init(prompt: String = "Quick note…", isCompact: Bool = false, onDone: (() -> Void)? = nil) {
        self.prompt = prompt
        self.isCompact = isCompact
        self.externalFocus = nil
        self.onDone = onDone
    }

    init(prompt: String, isCompact: Bool = false, isFocused: FocusState<Bool>.Binding,
         onDone: (() -> Void)? = nil) {
        self.prompt = prompt
        self.isCompact = isCompact
        self.externalFocus = isFocused
        self.onDone = onDone
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
                    .onExitCommand(perform: finishEditing)
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
        guard let note = engine.addNote(text) else {
            if onDone != nil && text.isBlank { finishEditing() }
            return
        }
        text = ""
        if onDone != nil {
            finishEditing()
        } else {
            focusBinding.wrappedValue = true
        }
        confirmation = "Note added at \(note.createdAt.shortTime)"
        confirmationToken += 1
        let token = confirmationToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            if confirmationToken == token { confirmation = nil }
        }
    }

    private func finishEditing() {
        focusBinding.wrappedValue = false
        onDone?()
    }
}

// MARK: - Takeaway

/// "Last takeaway" block: quote glyph, the takeaway text, "title · day" metadata (a link that opens the source
/// session in History) and a "Done" checkmark (`engine.dismissTakeaway(takeaway)`: this takeaway stops showing
/// everywhere; other profiles' takeaways stay).
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
                    engine.dismissTakeaway(takeaway)
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
        guard let session = try? modelContext.fetch(descriptor).first, ModelLiveness.isLive(session) else {
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

// MARK: - Long-session line

/// Overlay and menu bar version of Today's "Still working?" banner: one subtle line and "Keep going"
/// (`engine.dismissLongSessionWarning(for:)`, per session). Stopping stays with the regular Stop button.
@MainActor
struct LiveLongSessionLine: View {
    @Environment(\.theme) private var theme
    private let hours: Int
    private let onKeepGoing: () -> Void

    init(hours: Int, onKeepGoing: @escaping () -> Void) {
        self.hours = hours
        self.onKeepGoing = onKeepGoing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text("Running \(hours)h. Still working?")
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Running for \(hours) \(hours == 1 ? "hour" : "hours"). Still working?")
            Spacer(minLength: theme.spacingXS)
            Button("Keep going", action: onKeepGoing)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
                .fixedSize()
                .help("Keep going")
        }
        .font(theme.captionFont)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Running for \(hours) \(hours == 1 ? "hour" : "hours"). Still working?")
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

// MARK: - Child sheet tracking

extension View {
    /// For a confirmation dialog on the Today page (a sheet on macOS): counts it in
    /// `router.childSheetDidAppear/Disappear` while it is up, so RootView holds the review sheet back until it
    /// closes (or this view goes away, e.g. the session was stopped from the menu bar). Never use it inside the
    /// review sheet itself.
    func liveChildSheet(isPresented: Bool) -> some View {
        modifier(LiveChildSheetCounter(isPresented: isPresented))
    }
}

private struct LiveChildSheetCounter: ViewModifier {
    @Environment(WindowRouter.self) private var router
    private let isPresented: Bool
    /// This view's share of `router.presentedChildSheets` (0 or 1), so appear/disappear always balance.
    @State private var isCounted = false

    init(isPresented: Bool) {
        self.isPresented = isPresented
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, presented in update(presented) }
            .onDisappear { update(false) }
    }

    private func update(_ presented: Bool) {
        if presented && !isCounted {
            isCounted = true
            router.childSheetDidAppear()
        } else if !presented && isCounted {
            isCounted = false
            router.childSheetDidDisappear()
        }
    }
}

// MARK: - Request ledger

/// `WindowRouter.noteFocusRequest` / `splitRequest` / `discardRequest` are counters. LiveSessionView may be created *after* the
/// increment (the request also switches to Today), so `.onChange` alone would miss it; remember what was handled.
@MainActor
enum LiveRequestLedger {
    static var handledNoteFocusRequest = 0
    static var handledSplitRequest = 0
    static var handledDiscardRequest = 0
}
