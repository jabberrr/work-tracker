import SwiftData
import SwiftUI

// MARK: - Idle

@MainActor
struct LiveIdlePane: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(ProfileStore.self) private var profiles
    @Environment(WindowRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var startLabel: WorkLabel?
    @State private var startTags: [WorkTag] = []
    @State private var startFocus = ""
    @State private var didLoadDefaults = false
    /// Set by Start: the form's choices were used, don't keep them as a draft.
    @State private var didStart = false
    @State private var today = Date()
    @FocusState private var focusFieldFocused: Bool

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacingXL) {
                header
                startCard
                if let takeaway = engine.takeaway(for: profiles.activeProfileID) {
                    Card {
                        LiveTakeawayView(takeaway: takeaway)
                    }
                }
                LiveTodaySessionsQuery { sessions in
                    LiveTodaySummary(sessions: sessions, scope: profiles.activeScope)
                }
            }
            .padding(theme.spacingXL)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: onAppear)
        .onDisappear(perform: saveDraft)
        .onReceive(LiveDayChange.publisher) { _ in today = Date() }
        // Switching profile: start over with that profile's default label and no tags.
        .onChange(of: profiles.activeProfileID) { _, _ in
            startLabel = engine.defaultLabel(for: currentProfile)
            startTags = []
        }
        // The profile's default label changed (Settings ▸ Profiles).
        .onChange(of: currentProfile?.defaultLabelUUID) { _, _ in
            startLabel = engine.defaultLabel(for: currentProfile)
        }
        .onChange(of: router.noteFocusRequest) { _, _ in handleNoteFocusRequest() }
        .onChange(of: router.splitRequest) { _, newValue in
            // Nothing to split while idle; mark it handled so it doesn't fire on the next active pane.
            LiveRequestLedger.handledSplitRequest = newValue
        }
        .onChange(of: router.discardRequest) { _, newValue in
            // Nothing to discard while idle; mark it handled so it doesn't fire on the next active pane.
            LiveRequestLedger.handledDiscardRequest = newValue
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(theme.largeTitleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.spacingM)
            if profiles.hasMultipleProfiles {
                ProfileBadge(profile: currentProfile, size: .small)
                    .frame(minWidth: 0, maxWidth: 200, alignment: .trailing)
                Text("·")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(today.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// The selected profile, if it still exists (the store reloads after a save; never read a deleted one).
    private var currentProfile: WorkProfile? {
        ModelLiveness.live(profiles.activeProfile)
    }

    /// Non-archived labels the current profile offers (global + its own).
    private var offeredLabels: [WorkLabel] {
        let scope = profiles.activeScope
        return ModelLiveness.live(labels).filter { !$0.isArchived && scope.offers($0) }
    }

    private var startCard: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingM) {
                Text("What are you working on?")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)

                TextField("Focus", text: $startFocus, prompt: Text("Focus (optional)"))
                    .textFieldStyle(.plain)
                    .focused($focusFieldFocused)
                    .insetField(isFocused: focusFieldFocused)
                    .onSubmit(start)
                    .accessibilityLabel("Focus")
                    .accessibilityHint("Return starts the session.")

                HStack(alignment: .firstTextBaseline, spacing: theme.spacingL) {
                    if offeredLabels.isEmpty {
                        noLabelsHint
                    } else {
                        LabelPicker(selection: $startLabel, includeNone: true, title: "Label",
                                    profileID: profiles.activeProfileID)
                            .fixedSize()
                    }
                    TagPicker(selection: $startTags, scopeLabel: startLabel, profileID: profiles.activeProfileID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button(action: start) {
                        Label("Start session", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .help("Start session")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A new profile (or one whose labels are all local elsewhere) has nothing to pick: point to Settings.
    private var noLabelsHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
            Text("No labels yet.")
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            Button("Add labels") { router.showSettings(tab: "labels") }
                .buttonStyle(QuietButtonStyle())
                .controlSize(.small)
                .help("Add labels")
        }
        .fixedSize()
    }

    private func onAppear() {
        today = Date()
        let profileID = profiles.activeProfileID
        if !didLoadDefaults {
            didLoadDefaults = true
            restoreDraft()
        }
        if let label = startLabel, !LiveStartChoice.isUsable(label, in: profileID) {
            // Deleted, merged, archived or made local to another profile since: fall back to the default label.
            startLabel = engine.defaultLabel(for: currentProfile)
        }
        startTags = LiveStartChoice.tags(startTags, in: profileID)
        if router.noteFocusRequest > LiveRequestLedger.handledNoteFocusRequest {
            handleNoteFocusRequest()
        }
        LiveRequestLedger.handledSplitRequest = router.splitRequest
        LiveRequestLedger.handledDiscardRequest = router.discardRequest
    }

    /// What the user typed or picked before leaving Today (same profile only); else the profile's default label.
    private func restoreDraft() {
        let draft = LiveStartDraft.current
        LiveStartDraft.current = nil
        guard let draft, draft.profileID == profiles.activeProfileID else {
            startLabel = engine.defaultLabel(for: currentProfile)
            return
        }
        startLabel = draft.hasPickedLabel ? draft.label : engine.defaultLabel(for: currentProfile)
        startTags = draft.tags
        startFocus = draft.focus
    }

    /// RootView rebuilds this pane on every page switch: keep a hand-picked label, tags and typed focus.
    private func saveDraft() {
        guard !didStart, !engine.isActive else {
            LiveStartDraft.current = nil
            return
        }
        let defaultID = ModelLiveness.live(engine.defaultLabel(for: currentProfile))?.persistentModelID
        let picked = ModelLiveness.live(startLabel)
        let hasPickedLabel = picked?.persistentModelID != defaultID
        let tags = LiveStartChoice.tags(startTags)
        guard hasPickedLabel || !tags.isEmpty || !startFocus.isEmpty else {
            LiveStartDraft.current = nil
            return
        }
        LiveStartDraft.current = LiveStartDraft(profileID: profiles.activeProfileID, hasPickedLabel: hasPickedLabel,
                                                label: picked, tags: tags, focus: startFocus)
    }

    /// No session to take notes in: focus the start form's focus field instead.
    private func handleNoteFocusRequest() {
        LiveRequestLedger.handledNoteFocusRequest = router.noteFocusRequest
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            focusFieldFocused = true
        }
    }

    private func start() {
        guard !engine.isActive else { return }
        // Today's Start always uses the selected profile. The picked label/tags may have been deleted, merged,
        // archived or scoped to another profile in Settings since they were chosen.
        let profile = currentProfile
        let label = LiveStartChoice.label(startLabel, engine: engine, profile: profile)
        let tags = LiveStartChoice.tags(startTags, in: profile?.uuid)
        let focus = startFocus
        didStart = true
        LiveStartDraft.current = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            _ = engine.start(label: label, tags: tags, focus: focus, profile: profile)
        }
        startFocus = ""
        startTags = []
    }
}

/// Today's start form, kept in memory while the user visits other pages (the idle pane is rebuilt on every page
/// switch). Only for the profile it was made in; models are re-checked on restore (`LiveStartChoice`).
@MainActor
private struct LiveStartDraft {
    static var current: LiveStartDraft?

    let profileID: UUID?
    /// False: the user kept the profile's default label, so follow the default if it changes meanwhile.
    let hasPickedLabel: Bool
    /// The picked label (nil = "None").
    let label: WorkLabel?
    let tags: [WorkTag]
    let focus: String
}

/// Today total vs goal, session count and today's finished sessions, for one profile (`scope`).
@MainActor
private struct LiveTodaySummary: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(WindowRouter.self) private var router
    @Environment(\.theme) private var theme

    private let sessions: [WorkSession]
    private let scope: ProfileScope

    init(sessions: [WorkSession], scope: ProfileScope) {
        self.sessions = sessions
        self.scope = scope
    }

    var body: some View {
        let now = Date()
        let total = LiveDayMath.totalToday(sessions, active: engine.activeSession, now: now, scope: scope)
        let ended = LiveDayMath.endedToday(sessions, now: now, scope: scope)
        let goal = LiveDayMath.goalSeconds(settings)

        VStack(alignment: .leading, spacing: theme.spacingL) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: theme.spacingM)],
                      alignment: .leading, spacing: theme.spacingM) {
                StatTile(title: "Today", value: total.formattedShort, systemImage: "target",
                         caption: goal > 0 ? "of \(goal.formattedShort) goal" : nil)
                StatTile(title: "Sessions", value: "\(ended.count)", systemImage: "clock.arrow.circlepath")
            }
            if goal > 0 {
                ProportionBar(parts: [.init(value: total, color: theme.accent, label: "Today")], total: goal)
                    .accessibilityLabel("Daily goal progress")
            }

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                SectionHeader("Today's sessions", systemImage: "clock.arrow.circlepath") {
                    if !ended.isEmpty { Text("\(ended.count)") }
                }
                if ended.isEmpty {
                    Text("Nothing logged today.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(ended) { session in
                        LiveTodaySessionRow(session: session) { router.showSession(session) }
                    }
                }
            }
        }
    }
}

@MainActor
private struct LiveTodaySessionRow: View {
    @Environment(\.theme) private var theme
    private let session: WorkSession
    private let action: () -> Void

    init(session: WorkSession, action: @escaping () -> Void) {
        self.session = session
        self.action = action
    }

    var body: some View {
        if ModelLiveness.isLive(session) {
            Button(action: action) {
                HStack(spacing: theme.spacingM) {
                    Text(session.startedAt.shortTime)
                        .font(theme.captionFont.monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: 60, alignment: .leading)
                    Text(session.displayTitle)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.displayTitle)
                    Spacer(minLength: theme.spacingS)
                    LabelBadge(label: session.label, size: .small)
                    Text(session.activeDuration().formattedShort)
                        .font(theme.timerCompactFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 56, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, theme.spacingS)
                .padding(.vertical, theme.spacingS)
            }
            .buttonStyle(LiveHoverRowStyle())
            .accessibilityLabel("\(session.displayTitle), \(session.label?.name ?? "Unlabeled"), \(session.activeDuration().formattedShort)")
            .accessibilityHint("Opens the session in History.")
        }
    }
}
