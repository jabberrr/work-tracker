import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Active

@MainActor
struct LiveActivePane: View {
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
        let longHours = longSessionHours(at: coarseNow)
        let other = otherProfile
        if (reason != nil && isPaused) || longHours != nil || other != nil {
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
                if let longHours {
                    LiveLongSessionBanner(
                        hours: longHours,
                        lastActivity: lastActivityStop,
                        onStopAtLastActivity: stopAtLastActivity,
                        onStopNow: stop,
                        onKeepGoing: keepGoing)
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

    /// `LiveLongSessionRule` (active time only, never while paused); "Keep going" sticks per session on the engine
    /// (`keepGoingDismissed` hides it right away).
    private func longSessionHours(at date: Date) -> Int? {
        // Read `Date()` too so the banner also appears right after a relaunch, before the coarse clock ticks.
        LiveLongSessionRule.warningHours(
            for: session, isPaused: isPaused,
            isDismissed: keepGoingDismissed || engine.isLongSessionWarningDismissed(for: session),
            settings: settings, now: max(date, Date()))
    }

    /// The last note, split or resume, when there was one after the start (else "Stop at last activity" would end
    /// the session at its start, as a 0-second session).
    private var lastActivityStop: Date? {
        guard ModelLiveness.isLive(session) else { return nil }
        let last = session.lastActivityDate
        return last > session.startedAt ? last : nil
    }

    private func stopAtLastActivity() {
        guard let date = lastActivityStop else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            _ = engine.stop(at: date)
        }
    }

    private func keepGoing() {
        keepGoingDismissed = true
        engine.dismissLongSessionWarning(for: session)
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
        LiveTicker(isTicking: !isPaused) { date in
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
                Text("Its notes, images and time will be deleted.")
            }
            .countsAsChildSheet(isPresented: confirmDiscard)
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
            router.stopSession(engine)
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
            LiveTicker(isTicking: !isPaused) { date in
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
        guard ModelLiveness.isLive(session) else { return }
        // Downscaling and encoding run off the main thread; the importer re-checks the session before inserting.
        let target = session
        let context = modelContext
        Task { @MainActor in
            _ = await AttachmentImporter.addFromOpenPanel(to: target, in: context)
        }
    }

    /// Drops and pastes import like the open panel: downscaling and encoding run off the main thread and the
    /// importer re-checks the session before inserting.
    private func dropImages(_ providers: [NSItemProvider]) {
        let target = session
        let context = modelContext
        Task { @MainActor in
            let images = await AttachmentImporter.loadImages(from: providers)
            guard !images.isEmpty, ModelLiveness.isLive(target) else { return }
            _ = await AttachmentImporter.addInBackground(images, to: target, in: context)
        }
    }

    private func pasteImages() {
        let images = AttachmentImporter.imagesFromPasteboard()
        guard !images.isEmpty, ModelLiveness.isLive(session) else { return }
        let target = session
        let context = modelContext
        Task { @MainActor in
            _ = await AttachmentImporter.addInBackground(images, to: target, in: context)
        }
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
                guard ModelLiveness.isLive(session), engine.activeSession === session else { return }
                requestDiscard()
            }
        }
    }
}
