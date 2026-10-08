import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The "Today" page of the main window: the start form when idle, the live instrument while a session runs.
@MainActor
struct LiveSessionView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    init() {}

    var body: some View {
        Group {
            if let session = engine.activeSession, LiveModelGuard.isUsable(session) {
                LiveActivePane(session: session, onDiscard: discardActiveSession)
                    .id(session.persistentModelID)
                    .transition(.opacity)
            } else {
                LiveIdlePane()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
    }

    /// `engine.discard()` clears `activeSession` right away (this page switches to the idle pane) and deletes the
    /// session on the next main-actor turn, so no view reads it after deletion. No animation: the active pane
    /// must not linger in a transition while its model goes away.
    private func discardActiveSession() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = engine.discard()
        }
    }
}

// MARK: - Idle

@MainActor
private struct LiveIdlePane: View {
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
            startLabel = engine.defaultLabel(for: currentProfile)
        } else if let label = startLabel, !LiveStartChoice.isUsable(label, in: profileID) {
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            _ = engine.start(label: label, tags: tags, focus: focus, profile: profile)
        }
        startFocus = ""
        startTags = []
    }
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
        if LiveModelGuard.isUsable(session) {
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

// MARK: - Active

@MainActor
private struct LiveActivePane: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @Environment(WindowRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let session: WorkSession
    private let onDiscard: () -> Void

    @State private var showSplit = false
    @State private var showEditSegment = false
    @State private var confirmDiscard = false
    @State private var keepGoingDismissed = false
    @State private var coarseNow = Date()
    @State private var isDropTargeted = false
    @FocusState private var noteFocused: Bool

    init(session: WorkSession, onDiscard: @escaping () -> Void) {
        self.session = session
        self.onDiscard = onDiscard
    }

    private var isPaused: Bool { engine.isPaused }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacingXL) {
                banners
                header
                instrument
                controls
                // The takeaway belongs to the session's profile: hide it while that isn't the current one.
                if otherProfile == nil, let takeaway = engine.lastTakeaway {
                    takeawayStrip(takeaway)
                }
                segmentsSection
                notesSection
            }
            .padding(theme.spacingXL)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            // Coarse clock for the "still working?" banner (no need to re-render the page every second).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                coarseNow = Date()
            }
        }
        .onAppear(perform: handlePendingRequests)
        .onChange(of: router.noteFocusRequest) { _, _ in handlePendingRequests() }
        .onChange(of: router.splitRequest) { _, _ in handlePendingRequests() }
        .onChange(of: router.discardRequest) { _, _ in handlePendingRequests() }
    }

    // MARK: Banners

    /// The running session's profile when it isn't the current one (nil otherwise, or when it has no profile).
    /// The page then says so and offers to switch; the live controls stay usable.
    private var otherProfile: WorkProfile? {
        guard let sessionProfile = engine.activeSessionProfile,
              sessionProfile.uuid != profiles.activeProfileID else { return nil }
        return sessionProfile
    }

    @ViewBuilder
    private var banners: some View {
        let reason = engine.autoPauseReason
        let showLong = shouldWarnLongSession(at: coarseNow)
        let other = otherProfile
        if (reason != nil && isPaused) || showLong || other != nil {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                if let other {
                    otherProfileBanner(other)
                }
                if let reason, isPaused {
                    InlineBanner(reason == .sleep ? "Paused while your Mac slept." : "Paused when Worklog quit.",
                                 systemImage: "pause.circle",
                                 style: .warning,
                                 actionTitle: "Resume",
                                 action: { engine.resume() },
                                 onDismiss: { engine.clearAutoPauseReason() })
                }
                if showLong {
                    LiveLongSessionBanner(
                        hours: Int(session.activeDuration(at: max(coarseNow, Date())) / 3600),
                        onStopAtLastActivity: { _ = engine.stop(at: session.lastActivityDate) },
                        onStopNow: { _ = engine.stop() },
                        onKeepGoing: { keepGoingDismissed = true })
                }
            }
        }
    }

    private func otherProfileBanner(_ profile: WorkProfile) -> some View {
        let name = profile.displayName
        let canSwitch = !profile.isArchived
        let switchAction: (() -> Void)? = canSwitch ? { profiles.select(profile) } : nil
        return InlineBanner("Running in “\(name)”.",
                            systemImage: profile.symbolName.isEmpty ? "person.crop.circle" : profile.symbolName,
                            style: .info,
                            actionTitle: canSwitch ? "Switch to “\(name)”" : nil,
                            action: switchAction)
    }

    /// Based on active time (pauses, including an overnight auto-pause on sleep, don't count) and never while
    /// paused: a paused session isn't accumulating anything to forget about.
    private func shouldWarnLongSession(at date: Date) -> Bool {
        guard !keepGoingDismissed, !isPaused, settings.longSessionWarningHours > 0 else { return false }
        // Read `Date()` too so the banner also appears right after a relaunch, before the coarse clock ticks.
        let now = max(date, Date())
        return session.activeDuration(at: now) >= settings.longSessionWarningHours * 3600
    }

    // MARK: Header

    private var header: some View {
        let segment = engine.currentSegment
        let focus = segment?.focus.trimmed ?? ""
        let segmentCount = session.segments?.count ?? 0
        let tags = displayedTags(segment)

        return HStack(alignment: .top, spacing: theme.spacingL) {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                Button {
                    showEditSegment = true
                } label: {
                    LabelBadge(label: engine.currentLabel, size: .large)
                }
                .buttonStyle(.plain)
                .help("Edit segment")
                .accessibilityHint("Edits the current segment.")

                Button {
                    showEditSegment = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                        Text(focus.isEmpty ? "Add a focus…" : focus)
                            .font(theme.titleFont)
                            .foregroundStyle(focus.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "pencil")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit segment")
                .accessibilityLabel(focus.isEmpty ? "Add a focus" : "Focus: \(focus)")
                .accessibilityHint("Edits the current segment.")

                if !tags.isEmpty {
                    TagChipsRow(tags: tags)
                }
            }
            .popover(isPresented: $showEditSegment, arrowEdge: .bottom) {
                LiveSegmentForm(mode: .edit, style: .popover) { showEditSegment = false }
                    .padding(theme.spacingL)
                    .frame(width: 300)
                    .modifier(LiveEnvironmentBridge(engine: engine, profiles: profiles, theme: theme,
                                                    context: modelContext))
            }

            Spacer(minLength: theme.spacingS)

            VStack(alignment: .trailing, spacing: theme.spacingXS) {
                if profiles.hasMultipleProfiles {
                    LiveSessionProfileMenu(session: session)
                }
                Text("Started \(session.startedAt.shortTime) · \(segmentCount) \(segmentCount == 1 ? "segment" : "segments")")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                if engine.isActiveSessionOnAnotherMac {
                    LiveOtherMacHint()
                }
            }
        }
    }

    /// Session tags ∪ current segment tags, unique, by name.
    private func displayedTags(_ segment: Segment?) -> [WorkTag] {
        var seen = Set<UUID>()
        var result: [WorkTag] = []
        for tag in session.tagList + (segment?.tagList ?? []) where seen.insert(tag.uuid).inserted {
            result.append(tag)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Instrument

    private var instrument: some View {
        LiveClock(isTicking: !isPaused) { date in
            VStack(spacing: theme.spacingS) {
                TimerText(engine.elapsed(at: date), style: .hero, isPaused: isPaused)
                HStack(spacing: theme.spacingS) {
                    LiveDot(isPaused: isPaused)
                    Text(isPaused ? "Paused" : "Running")
                        .font(theme.captionFont.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                    Text("·")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                    Text("this segment")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                    TimerText(engine.currentSegmentElapsed(at: date), style: .medium, isPaused: isPaused)
                        .accessibilityLabel("Segment time")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: theme.spacingM) {
            Button {
                engine.togglePause()
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(QuietButtonStyle())
            .help(isPaused ? "Resume" : "Pause")

            Button {
                showSplit = true
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(QuietButtonStyle())
            .help("Split segment")
            .popover(isPresented: $showSplit, arrowEdge: .bottom) {
                LiveSegmentForm(mode: .split, style: .popover) { showSplit = false }
                    .padding(theme.spacingL)
                    .frame(width: 300)
                    .modifier(LiveEnvironmentBridge(engine: engine, profiles: profiles, theme: theme,
                                                    context: modelContext))
            }

            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Stop")
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button(action: requestDiscard) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Discard session")
            .help("Discard")
            .confirmationDialog("Discard this session?", isPresented: $confirmDiscard) {
                Button("Discard", role: .destructive, action: onDiscard)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its notes and time will be deleted.")
            }
        }
    }

    /// The trash button and Session ▸ Discard Session… (`router.discardRequest`) share this.
    private func requestDiscard() {
        if settings.confirmBeforeDiscard {
            confirmDiscard = true
        } else {
            onDiscard()
        }
    }

    private func stop() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            _ = engine.stop()
        }
    }

    // MARK: Takeaway

    private func takeawayStrip(_ takeaway: SessionTakeaway) -> some View {
        LiveTakeawayView(takeaway: takeaway, lineLimit: 3, isCompact: true)
            .padding(theme.spacingM)
            .background(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: theme.borderWidth))
    }

    // MARK: Segments

    private var segmentsSection: some View {
        let segments = session.sortedSegments
        return VStack(alignment: .leading, spacing: theme.spacingS) {
            SectionHeader("Segments", systemImage: "rectangle.split.3x1") {
                Text("\(segments.count)")
                    .monospacedDigit()
            }
            LiveClock(isTicking: !isPaused) { date in
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    ProportionBar(parts: segments.map { segment in
                        ProportionBar.Part(value: segment.activeDuration(at: date),
                                           color: segment.effectiveLabel?.color ?? theme.textTertiary,
                                           label: "\(segment.displayFocus), \(segment.activeDuration(at: date).formattedShort)")
                    }, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(segments) { segment in
                            LiveSegmentRow(segment: segment,
                                           isCurrent: segment.endedAt == nil,
                                           isPaused: isPaused,
                                           now: date)
                        }
                    }
                }
            }
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        let notes = session.sortedNotes
        let attachments = session.sortedAttachments
        return VStack(alignment: .leading, spacing: theme.spacingS) {
            SectionHeader("Notes", systemImage: "note.text") {
                Button(action: attachImages) {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .accessibilityLabel("Add images")
                .help("Add images")
            }

            if !attachments.isEmpty {
                LiveAttachmentStrip(attachments: attachments)
            }

            if notes.isEmpty {
                Text("Notes you add get a timestamp.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textTertiary)
            } else {
                LiveNotesList(notes: notes)
            }

            LiveQuickNoteField(prompt: "Add a note…", isFocused: $noteFocused)
        }
        .padding(isDropTargeted ? theme.spacingS : 0)
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                    .fill(theme.accent.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
        }
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            dropImages(providers)
            return true
        }
        // Paste commands only reach focused views: let a click on the notes area (outside the text field) focus it.
        .focusable()
        .focusEffectDisabled()
        .onPasteCommand(of: [UTType.image, UTType.fileURL]) { _ in
            pasteImages()
        }
    }

    private func attachImages() {
        guard LiveModelGuard.isUsable(session) else { return }
        AttachmentImporter.addFromOpenPanel(to: session, in: modelContext)
    }

    private func dropImages(_ providers: [NSItemProvider]) {
        let target = session
        let context = modelContext
        Task { @MainActor in
            let images = await AttachmentImporter.loadImages(from: providers)
            guard !images.isEmpty, LiveModelGuard.isUsable(target) else { return }
            AttachmentImporter.add(images, to: target, in: context)
        }
    }

    private func pasteImages() {
        let images = AttachmentImporter.imagesFromPasteboard()
        guard !images.isEmpty, LiveModelGuard.isUsable(session) else { return }
        AttachmentImporter.add(images, to: session, in: modelContext)
    }

    // MARK: Router requests

    private func handlePendingRequests() {
        if router.noteFocusRequest > LiveRequestLedger.handledNoteFocusRequest {
            LiveRequestLedger.handledNoteFocusRequest = router.noteFocusRequest
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                noteFocused = true
            }
        }
        if router.splitRequest > LiveRequestLedger.handledSplitRequest {
            LiveRequestLedger.handledSplitRequest = router.splitRequest
            // Let the window come forward before anchoring the popover.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                showSplit = true
            }
        }
        if router.discardRequest > LiveRequestLedger.handledDiscardRequest {
            LiveRequestLedger.handledDiscardRequest = router.discardRequest
            // Like split: let the window come forward before the confirmation dialog anchors to it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard LiveModelGuard.isUsable(session), engine.activeSession === session else { return }
                requestDiscard()
            }
        }
    }
}

// MARK: - Active pane pieces

/// The running session's profile (shown with 2+ profiles). A session keeps running in its own profile when the
/// user switches: the menu offers "Switch to “Work”" when it isn't the selected profile, and "Move to" the other
/// profiles (asking first when labels or tags would be copied).
@MainActor
private struct LiveSessionProfileMenu: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let session: WorkSession

    @State private var pendingMove: LiveProfileMove.Request?

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let sessionProfile = LiveModelGuard.isUsable(session) ? ProfileOps.effectiveProfile(of: session) : nil
        let canSwitch = sessionProfile.map { !$0.isArchived && $0.uuid != profiles.activeProfileID } ?? false
        let targets = ModelLiveness.live(profiles.profiles).filter { $0.uuid != sessionProfile?.uuid }

        Menu {
            if let sessionProfile, canSwitch {
                Button("Switch to “\(sessionProfile.displayName)”") {
                    profiles.select(sessionProfile)
                }
            }
            if !targets.isEmpty {
                Menu("Move to") {
                    ForEach(targets, id: \.uuid) { target in
                        Button {
                            requestMove(to: target)
                        } label: {
                            Label {
                                Text(target.displayName)
                            } icon: {
                                Image(nsImage: LabelMenuIcon.image(symbol: target.symbolName, hex: target.colorHex))
                                    .renderingMode(.original)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: theme.spacingXS) {
                ProfileBadge(profile: sessionProfile, size: .small)
                Image(systemName: "chevron.down")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(minWidth: 0, maxWidth: 220, alignment: .trailing)
        .help("Profile")
        .accessibilityLabel("Profile")
        .accessibilityValue(sessionProfile?.displayName ?? "No profile")
        .confirmationDialog(pendingMove?.title ?? "",
                            isPresented: Binding(get: { pendingMove != nil },
                                                 set: { if !$0 { pendingMove = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingMove) { request in
            Button("Move") {
                pendingMove = nil
                LiveProfileMove.perform(request, moving: session, profiles: profiles, in: modelContext)
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { request in
            Text(request.message)
        }
    }

    private func requestMove(to target: WorkProfile) {
        if case .needsConfirmation(let request) = LiveProfileMove.begin(moving: session, to: target,
                                                                        in: modelContext) {
            pendingMove = request
        }
    }
}

@MainActor
private struct LiveSegmentRow: View {
    @Environment(\.theme) private var theme
    private let segment: Segment
    private let isCurrent: Bool
    private let isPaused: Bool
    private let now: Date

    init(segment: Segment, isCurrent: Bool, isPaused: Bool, now: Date) {
        self.segment = segment
        self.isCurrent = isCurrent
        self.isPaused = isPaused
        self.now = now
    }

    var body: some View {
        if LiveModelGuard.isUsable(segment) {
            let duration = segment.activeDuration(at: now)
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
                Text(timeRange)
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .frame(minWidth: 110, alignment: .leading)
                LabelBadge(label: segment.effectiveLabel, size: .small)
                Text(segment.focus.isBlank ? "—" : segment.focus.trimmed)
                    .font(theme.calloutFont)
                    .foregroundStyle(segment.focus.isBlank ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(segment.displayFocus)
                if !segment.tagList.isEmpty {
                    Text(segment.tagList.map { "#\($0.name)" }.joined(separator: " "))
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.spacingS)
                if isCurrent {
                    LiveDot(isPaused: isPaused, size: 6)
                    TimerText(duration, style: .compact, isPaused: isPaused)
                        .accessibilityLabel("Current segment time")
                } else {
                    Text(duration.formattedShort)
                        .font(theme.timerCompactFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.vertical, theme.spacingXS + 1)
            .accessibilityElement(children: .combine)
        }
    }

    private var timeRange: String {
        let start = segment.startedAt.shortTime
        if let end = segment.endedAt {
            return "\(start) – \(end.shortTime)"
        }
        return "\(start) – now"
    }
}

/// Notes of the running session, oldest first / newest at the bottom, in a bounded scroll box that follows
/// new notes. Context menu: Copy, Edit (inline editor: Return saves, Esc cancels), Delete.
@MainActor
private struct LiveNotesList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let notes: [Note]
    @State private var contentHeight: CGFloat = 0
    @State private var editingNoteID: PersistentIdentifier?
    @State private var editText = ""
    @FocusState private var editorFocused: Bool

    private static let maxHeight: CGFloat = 320

    init(notes: [Note]) {
        self.notes = notes
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    ForEach(notes) { note in
                        if LiveModelGuard.isUsable(note) {
                            row(for: note)
                                .id(note.persistentModelID)
                        }
                    }
                }
                .padding(theme.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: LiveNotesHeightKey.self, value: geo.size.height)
                })
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: min(max(contentHeight, 40), Self.maxHeight))
            .onPreferenceChange(LiveNotesHeightKey.self) { value in
                MainActor.assumeIsolated { contentHeight = value }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: notes.count) { oldCount, newCount in
                if newCount > oldCount { scrollToBottom(proxy, animated: true) }
            }
        }
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(theme.separator, lineWidth: theme.borderWidth))
        .clipShape(shape)
    }

    @ViewBuilder
    private func row(for note: Note) -> some View {
        if editingNoteID == note.persistentModelID {
            editor(for: note)
        } else {
            NoteRow(note: note, showsSegment: true)
                .contextMenu {
                    Button("Copy Text") { copy(note.text) }
                    Button("Edit Note…") { beginEditing(note) }
                    Divider()
                    Button("Delete Note", role: .destructive) {
                        if editingNoteID == note.persistentModelID { cancelEditing() }
                        SessionEditor.deleteNote(note, in: modelContext)
                    }
                }
        }
    }

    private func editor(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                Text(note.createdAt.shortTime)
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                TextField("Note", text: $editText, prompt: Text("Note text"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.bodyFont)
                    .lineLimit(1...6)
                    .focused($editorFocused)
                    .onSubmit { commitEditing(note) }
                    .onExitCommand { cancelEditing() }
                    .insetField(isFocused: editorFocused)
                    .accessibilityLabel("Edit note")
            }
            HStack(spacing: theme.spacingS) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancelEditing)
                    .buttonStyle(QuietButtonStyle())
                Button("Save") { commitEditing(note) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(editText.isBlank)
                    .help("Save")
            }
            .controlSize(.small)
        }
    }

    private func beginEditing(_ note: Note) {
        guard LiveModelGuard.isUsable(note) else { return }
        editText = note.text
        editingNoteID = note.persistentModelID
        Task { @MainActor in
            await Task.yield()
            editorFocused = true
        }
    }

    private func commitEditing(_ note: Note) {
        let text = editText.trimmed
        defer { cancelEditing() }
        guard !text.isEmpty, LiveModelGuard.isUsable(note), text != note.text else { return }
        SessionEditor.updateNote(note, text: text, date: nil, in: modelContext)
    }

    private func cancelEditing() {
        editingNoteID = nil
        editorFocused = false
        editText = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = notes.last(where: { LiveModelGuard.isUsable($0) }) else { return }
        let id = last.persistentModelID
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LiveNotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Thumbnails of images attached during the session (thumbnailData only).
@MainActor
private struct LiveAttachmentStrip: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let attachments: [Attachment]

    init(attachments: [Attachment]) {
        self.attachments = attachments
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacingS) {
                ForEach(attachments) { attachment in
                    if LiveModelGuard.isUsable(attachment) {
                        thumbnail(attachment)
                    }
                }
            }
        }
    }

    private func thumbnail(_ attachment: Attachment) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        return Group {
            if let image = attachment.thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(width: 64, height: 64)
        .background(shape.fill(theme.insetSurface))
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.separator, lineWidth: 1))
        .help(attachment.caption.isBlank ? attachment.filename : attachment.caption)
        .accessibilityLabel(attachment.caption.isBlank ? "Image \(attachment.filename)" : "Image: \(attachment.caption)")
        .contextMenu {
            Button("Save Image…") { AttachmentImporter.saveToDisk(attachment) }
            Divider()
            Button("Delete Image", role: .destructive) {
                SessionEditor.deleteAttachment(attachment, in: modelContext)
            }
        }
    }
}

/// "Still working?" banner with three actions (InlineBanner has room for one).
@MainActor
private struct LiveLongSessionBanner: View {
    @Environment(\.theme) private var theme
    private let hours: Int
    private let onStopAtLastActivity: () -> Void
    private let onStopNow: () -> Void
    private let onKeepGoing: () -> Void

    init(hours: Int, onStopAtLastActivity: @escaping () -> Void, onStopNow: @escaping () -> Void,
         onKeepGoing: @escaping () -> Void) {
        self.hours = hours
        self.onStopAtLastActivity = onStopAtLastActivity
        self.onStopNow = onStopNow
        self.onKeepGoing = onKeepGoing
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                Image(systemName: "exclamationmark.triangle")
                    .font(theme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                Text("Running for \(hours) \(hours == 1 ? "hour" : "hours"). Still working?")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: theme.spacingS) {
                Button("Stop at last activity", action: onStopAtLastActivity)
                    .accessibilityHint("Ends at your last note, split or resume.")
                Button("Stop now", action: onStopNow)
                Button("Keep going", action: onKeepGoing)
            }
            .buttonStyle(QuietButtonStyle())
            .controlSize(.small)
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background {
            ZStack {
                shape.fill(theme.surface)
                shape.fill(theme.warning.opacity(theme.tintOpacity))
            }
        }
        .overlay(shape.strokeBorder(theme.warning.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Warning: still working?")
    }
}
