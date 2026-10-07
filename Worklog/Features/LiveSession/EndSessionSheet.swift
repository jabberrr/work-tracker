import SwiftData
import SwiftUI

/// Review sheet shown by RootView while `engine.pendingEndSession` is set: title, primary label, session tags,
/// a read-only review of segments and notes, and learnings (B's `LearningsEditor`, which also holds the
/// "Takeaway for next time" summary and the "Show in overlay & menu bar" toggle).
///
/// Save (⌘↩, also Esc = save as-is) → `engine.completeReview()`; Resume → `engine.resumePendingSession()`;
/// Discard (confirmed) → `engine.discardPendingSession()`.
///
/// Discard deletes the session. To never read a destroyed model (SwiftData traps), the sheet first swaps its
/// content for a placeholder of the same size — removing every view bound to the session, including the
/// LearningsEditor and the focused title field — and deletes on a later run-loop turn.
struct EndSessionSheet: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    private let session: WorkSession

    @State private var isClosing = false
    @State private var lastSize: CGSize = .zero

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        Group {
            if !isClosing && LiveModelGuard.isUsable(session) {
                EndSessionForm(session: session, onDiscard: discard)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { lastSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in lastSize = newSize }
                    })
            } else {
                closingPlaceholder
            }
        }
    }

    private var closingPlaceholder: some View {
        VStack(spacing: theme.spacingS) {
            ProgressView()
                .controlSize(.small)
            Text("Discarding…")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(width: lastSize.width > 0 ? lastSize.width : 560,
               height: lastSize.height > 0 ? lastSize.height : 240)
        .accessibilityElement(children: .combine)
    }

    private func discard() {
        let sessionID = session.persistentModelID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isClosing = true }
        // Delete only after the bound views are gone (their onDisappear/commit handlers may still write).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let pending = engine.pendingEndSession, pending.persistentModelID == sessionID {
                engine.discardPendingSession()
            } else {
                // No longer pending (e.g. replaced by an import): just close the sheet.
                engine.completeReview()
            }
        }
    }
}

// MARK: - Form

private struct EndSessionForm: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    @Bindable private var session: WorkSession
    private let onDiscard: () -> Void

    @State private var confirmDiscard = false
    @State private var showsNotes = false
    @FocusState private var titleFocused: Bool

    private static let fieldLabelWidth: CGFloat = 64

    init(session: WorkSession, onDiscard: @escaping () -> Void) {
        self._session = Bindable(wrappedValue: session)
        self.onDiscard = onDiscard
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingXL) {
                    header
                    if session.activeDuration() < 60 {
                        InlineBanner("This session was under a minute.",
                                     style: .warning,
                                     actionTitle: "Discard",
                                     action: { confirmDiscard = true })
                    }
                    fields
                    segmentsReview
                    notesReview
                    VStack(alignment: .leading, spacing: theme.spacingS) {
                        SectionHeader("Learnings", systemImage: "lightbulb")
                        LearningsEditor(session: session, style: .compact)
                    }
                }
                .padding(theme.spacingXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320, idealHeight: 560, maxHeight: 760)

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
            Text("Its notes, images, learnings and time will be deleted. This can’t be undone.")
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { titleFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            Text("Session complete")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
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
                LabelPicker(selection: primaryLabelBinding, includeNone: true, title: "Label")
                    .labelsHidden()
                    .fixedSize()
            }
            fieldRow("Tags") {
                TagPicker(selection: sessionTagsBinding, scopeLabel: session.label)
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
            SectionHeader("Segments", systemImage: "rectangle.split.3x1") {
                Text("\(segments.count)").monospacedDigit()
            }
            ProportionBar(parts: segments.map { segment in
                ProportionBar.Part(value: segment.activeDuration(),
                                   color: segment.effectiveLabel?.color ?? theme.textTertiary,
                                   label: "\(segment.displayFocus), \(segment.activeDuration().formattedShort)")
            }, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(segments) { segment in
                    EndSessionSegmentRow(segment: segment)
                }
            }
            Text("You can split, merge and retime segments later in History.")
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
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
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: theme.spacingS) {
            Button {
                confirmDiscard = true
            } label: {
                Label("Discard…", systemImage: "trash")
            }
            .buttonStyle(DestructiveButtonStyle())
            .help("Delete this session")

            Spacer(minLength: theme.spacingM)

            Button {
                engine.resumePendingSession()
            } label: {
                Label("Resume session", systemImage: "play.fill")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(engine.isActive)
            .help(engine.isActive ? "Another session is running" : "Keep tracking; the time since you stopped counts as a pause")

            Button(action: save) {
                Text("Save")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save session (⌘↩)")

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
        session.touch()
        engine.completeReview()
    }
}

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
