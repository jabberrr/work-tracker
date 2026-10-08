import SwiftData
import SwiftUI

/// Review sheet shown by RootView while `engine.pendingEndSession` is set. Built to be done in ~10 seconds:
/// title, primary label, session tags and the "takeaway for next time" up front; the segment review is one
/// proportion bar with the rows behind a disclosure; notes and learnings (B's `LearningsEditor`) are disclosures.
///
/// Save (the customizable "Save Session Review" shortcut, default ⌘↩; Esc = save as-is, fixed) →
/// `engine.completeReview()`; Resume → `engine.resumePendingSession()`; Discard (trash icon, confirmed) →
/// `engine.discardPendingSession()`.
///
/// Discard is two-phase: `discardPendingSession()` only clears `pendingEndSession` (the sheet starts closing while
/// the session is still alive, so nothing here reads a destroyed model); RootView's sheet `onDismiss` then calls
/// `engine.finishPendingDiscard()`, which deletes it.
@MainActor
struct EndSessionSheet: View {
    @Environment(SessionEngine.self) private var engine

    private let session: WorkSession

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        if LiveModelGuard.isUsable(session) {
            EndSessionForm(session: session, onDiscard: discard)
        } else {
            // Deleted elsewhere (e.g. replaced by an import) while the sheet was up.
            Color.clear
                .frame(width: 520, height: 200)
                .onAppear { engine.completeReview() }
        }
    }

    private func discard() {
        if let pending = engine.pendingEndSession, pending.persistentModelID == session.persistentModelID {
            engine.discardPendingSession()
        } else {
            // No longer pending (e.g. replaced by an import): just close the sheet.
            engine.completeReview()
        }
    }
}

// MARK: - Form

@MainActor
private struct EndSessionForm: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(ProfileStore.self) private var profiles
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    @Bindable private var session: WorkSession
    private let onDiscard: () -> Void

    @State private var confirmDiscard = false
    @State private var showsNotes = false
    @State private var showsSegments = false
    @State private var showsLearnings = false
    @FocusState private var titleFocused: Bool
    @FocusState private var takeawayFocused: Bool

    private static let fieldLabelWidth: CGFloat = 72
    /// Same guidance as LearningsEditor's takeaway counter.
    private static let takeawayGuidanceLength = 140

    init(session: WorkSession, onDiscard: @escaping () -> Void) {
        self._session = Bindable(wrappedValue: session)
        self.onDiscard = onDiscard
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingL) {
                    header
                    if session.activeDuration() < 60 {
                        InlineBanner("Under a minute long.",
                                     style: .warning,
                                     actionTitle: "Discard",
                                     action: { confirmDiscard = true })
                    }
                    fields
                    segmentsReview
                    notesReview
                    learningsReview
                }
                .padding(theme.spacingXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 300, idealHeight: 470, maxHeight: 760)

            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)

            footer
                .padding(.horizontal, theme.spacingXL)
                .padding(.vertical, theme.spacingM)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 720)
        .confirmationDialog("Discard this session?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its notes, images, learnings and time will be deleted.")
        }
        .onAppear {
            // Reopen what the user already filled in (e.g. a resumed-then-stopped session).
            showsLearnings = !session.learningText.isBlank || !(session.learningPoints ?? []).isEmpty
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                titleFocused = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
                Text("Session complete")
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
                if profiles.hasMultipleProfiles {
                    Spacer(minLength: theme.spacingS)
                    ProfileBadge(profile: sessionProfile, size: .small)
                        .frame(minWidth: 0, maxWidth: 200, alignment: .trailing)
                }
            }
            Text(summaryLine)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(timeLine)
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
                .monospacedDigit()
        }
    }

    private var summaryLine: String {
        let active = session.activeDuration()
        let paused = session.pausedDuration()
        let segments = session.segments?.count ?? 0
        let notes = session.notes?.count ?? 0
        let images = session.attachments?.count ?? 0
        var parts = ["\(active.formattedShort) active"]
        if paused >= 1 { parts.append("\(paused.formattedShort) paused") }
        parts.append("\(segments) \(segments == 1 ? "segment" : "segments")")
        parts.append("\(notes) \(notes == 1 ? "note" : "notes")")
        if images > 0 { parts.append("\(images) \(images == 1 ? "image" : "images")") }
        return parts.joined(separator: " · ")
    }

    private var timeLine: String {
        let start = session.startedAt
        let end = session.endedAt ?? Date()
        let day = start.relativeDayTitle
        if start.isSameDay(as: end) {
            return "\(day) · \(start.shortTime) – \(end.shortTime)"
        }
        return "\(day) · \(start.shortTime) – \(end.shortDateTime)"
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            fieldRow("Title") {
                VStack(alignment: .leading, spacing: theme.spacingXS) {
                    TextField("Title", text: $session.title, prompt: Text(suggestedTitle ?? "Untitled session"))
                        .textFieldStyle(.plain)
                        .font(theme.bodyFont)
                        .focused($titleFocused)
                        .insetField(isFocused: titleFocused)
                        .accessibilityLabel("Title")
                    if session.title.isBlank, let suggestion = suggestedTitle {
                        Text("Leave empty to use “\(suggestion)”.")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
            fieldRow("Label") {
                LabelPicker(selection: primaryLabelBinding, includeNone: true, title: "Label",
                            profileID: sessionProfile?.uuid)
                    .labelsHidden()
                    .frame(minWidth: 0, maxWidth: 260, alignment: .leading)
            }
            fieldRow("Tags") {
                TagPicker(selection: sessionTagsBinding, scopeLabel: session.label, profileID: sessionProfile?.uuid)
            }
            fieldRow("Takeaway") {
                takeawayField
            }
        }
    }

    /// The one line shown in the overlay and menu bar during the next session (`overlaySummary`). The same field
    /// also appears inside the Learnings disclosure (LearningsEditor); both edit the same property.
    private var takeawayField: some View {
        let count = session.overlaySummary.trimmed.count
        let limit = Self.takeawayGuidanceLength
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            TextField("Takeaway", text: $session.overlaySummary,
                      prompt: Text("One line for next time"))
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .focused($takeawayFocused)
                .insetField(isFocused: takeawayFocused)
                .accessibilityLabel("Takeaway for next time")
                .onChange(of: session.overlaySummary) { oldValue, newValue in
                    guard LiveModelGuard.isUsable(session) else { return }
                    if oldValue.isBlank && !newValue.isBlank && !session.showInOverlay {
                        session.showInOverlay = true
                    }
                }
            HStack(spacing: theme.spacingS) {
                Toggle("Show in overlay & menu bar", isOn: $session.showInOverlay)
                    .toggleStyle(.checkbox)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: theme.spacingS)
                if count > 0 {
                    Text("\(count)/\(limit)")
                        .font(theme.captionFont.monospacedDigit())
                        .foregroundStyle(count > limit ? theme.warning : theme.textTertiary)
                        .help("Suggested length")
                        .accessibilityLabel("\(count) of \(limit) suggested characters")
                }
            }
        }
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
            Text(title)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .frame(width: Self.fieldLabelWidth, alignment: .leading)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Labels and tags offered here are the session's own profile's.
    private var sessionProfile: WorkProfile? {
        LiveModelGuard.isUsable(session) ? ProfileOps.effectiveProfile(of: session) : nil
    }

    /// Changing the primary label also relabels the segments that followed the old one.
    private var primaryLabelBinding: Binding<WorkLabel?> {
        Binding(
            get: { LiveModelGuard.isUsable(session) ? session.label : nil },
            set: { newValue in
                guard LiveModelGuard.isUsable(session) else { return }
                SessionEditor.setPrimaryLabel(newValue, for: session, in: modelContext)
            }
        )
    }

    private var sessionTagsBinding: Binding<[WorkTag]> {
        Binding(
            get: { LiveModelGuard.isUsable(session) ? session.tagList : [] },
            set: { newValue in
                guard LiveModelGuard.isUsable(session) else { return }
                session.tagList = newValue
                session.touch()
            }
        )
    }

    /// Distinct segment focuses ("Refactor parser · Review Maya's PR"), else the label name.
    private var suggestedTitle: String? {
        var unique: [String] = []
        for focus in session.sortedSegments.map({ $0.focus.trimmed }) where !focus.isEmpty {
            if !unique.contains(where: { $0.caseInsensitiveCompare(focus) == .orderedSame }) {
                unique.append(focus)
            }
        }
        if !unique.isEmpty {
            let head = unique.prefix(2).joined(separator: " · ")
            return unique.count > 2 ? "\(head) +\(unique.count - 2)" : head
        }
        if let name = session.label?.name.nilIfBlank {
            return name
        }
        return nil
    }

    // MARK: Segments / notes review

    private var segmentsReview: some View {
        let segments = session.sortedSegments
        return VStack(alignment: .leading, spacing: theme.spacingS) {
            ProportionBar(parts: segments.map { segment in
                ProportionBar.Part(value: segment.activeDuration(),
                                   color: segment.effectiveLabel?.color ?? theme.textTertiary,
                                   label: "\(segment.displayFocus), \(segment.activeDuration().formattedShort)")
            }, height: 8)
            DisclosureGroup(isExpanded: $showsSegments) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(segments) { segment in
                        EndSessionSegmentRow(segment: segment)
                    }
                    Text("Split, merge and retime segments later in History.")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, theme.spacingXS)
                }
                .padding(.top, theme.spacingXS)
            } label: {
                Label("Segments (\(segments.count))", systemImage: "rectangle.split.3x1")
                    .font(theme.calloutFont.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var notesReview: some View {
        let notes = session.sortedNotes
        if !notes.isEmpty {
            DisclosureGroup(isExpanded: $showsNotes) {
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    ForEach(notes) { note in
                        NoteRow(note: note, showsSegment: (session.segments?.count ?? 0) > 1)
                    }
                }
                .padding(.top, theme.spacingS)
            } label: {
                Label("Notes (\(notes.count))", systemImage: "note.text")
                    .font(theme.calloutFont.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// What I learned + learning points (B's editor), collapsed by default.
    private var learningsReview: some View {
        let hasLearnings = !session.learningText.isBlank || !(session.learningPoints ?? []).isEmpty
        return DisclosureGroup(isExpanded: $showsLearnings) {
            LearningsEditor(session: session, style: .compact, showsTakeaway: false)
                .padding(.top, theme.spacingS)
        } label: {
            Label(hasLearnings ? "Learnings" : "Add learnings", systemImage: "lightbulb")
                .font(theme.calloutFont.weight(.medium))
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: theme.spacingS) {
            Button {
                confirmDiscard = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(DestructiveButtonStyle())
            .help("Discard")
            .accessibilityLabel("Discard session")

            Spacer(minLength: theme.spacingM)

            Button {
                engine.resumePendingSession()
            } label: {
                Label("Resume session", systemImage: "play.fill")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(engine.isActive)
            .help(engine.isActive ? "Another session is running" : "Resume session")

            Button(action: save) {
                Text("Save")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(shortcuts.shortcut(for: .saveReview))
            .help("Save")

            // Esc = save as-is (also applies the suggested title when the title is empty).
            Button("Save as is", action: save)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func save() {
        guard LiveModelGuard.isUsable(session) else {
            engine.completeReview()
            return
        }
        if session.title.isBlank {
            session.title = suggestedTitle ?? ""
        } else if session.title != session.title.trimmed {
            session.title = session.title.trimmed
        }
        if session.overlaySummary != session.overlaySummary.trimmed {
            session.overlaySummary = session.overlaySummary.trimmed
        }
        session.touch()
        engine.completeReview()
    }
}

@MainActor
private struct EndSessionSegmentRow: View {
    @Environment(\.theme) private var theme
    private let segment: Segment

    init(segment: Segment) {
        self.segment = segment
    }

    var body: some View {
        if LiveModelGuard.isUsable(segment) {
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
                Spacer(minLength: theme.spacingS)
                Text(segment.activeDuration().formattedShort)
                    .font(theme.timerCompactFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.vertical, theme.spacingXS)
            .accessibilityElement(children: .combine)
        }
    }

    private var timeRange: String {
        let start = segment.startedAt.shortTime
        guard let end = segment.endedAt else { return "\(start) –" }
        return "\(start) – \(end.shortTime)"
    }
}
