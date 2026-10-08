import SwiftUI
import SwiftData

/// Full, editable view of one session: header (title, date/time range, durations, label, tags),
/// segments (timeline + rows: edit, split, merge, move boundary, delete), notes (add/edit/re-time/delete),
/// images (open panel, paste, drop, caption, viewer, save, delete) and learnings (`LearningsEditor(.full)`).
///
/// Time edits go through `SessionEditor` (which touches, recomputes, normalizes and saves); direct field
/// edits (title, tags, captions, segment label/tags/focus) touch the session and save on commit/disappear.
/// Works for the active session too, except that start/end times and deletion are locked while it runs.
@MainActor
struct SessionDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable private var session: WorkSession

    @State private var isComposingNote = false
    @State private var isEditingTimes = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(session: WorkSession) {
        self._session = Bindable(wrappedValue: session)
    }

    var body: some View {
        if session.isDeleted || session.modelContext == nil {
            EmptyStateView(title: "Session deleted",
                           systemImage: "trash",
                           message: "This session no longer exists.")
        } else {
            content
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingXL) {
                    if session.isActive {
                        InlineBanner("This session is still running.",
                                     systemImage: "record.circle",
                                     style: .info,
                                     actionTitle: "Go to Today",
                                     action: { router?.selection = .today })
                    }
                    header(proxy)
                    DetailSegmentsSection(session: session)
                    DetailNotesSection(session: session, isComposing: $isComposingNote)
                        .id(DetailAnchor.notes)
                    DetailAttachmentsSection(session: session)
                        .id(DetailAnchor.images)
                    VStack(alignment: .leading, spacing: theme.spacingS) {
                        SectionHeader("Learnings", systemImage: "lightbulb")
                        LearningsEditor(session: session, style: .full)
                    }
                }
                // Width depends only on the proposed width (never on content): capped at 760,
                // leading-aligned so a scroller appearing doesn't re-centre it.
                .frame(minWidth: 0, maxWidth: 760, alignment: .topLeading)
                .padding(.horizontal, theme.spacingXL)
                .padding(.vertical, theme.spacingXL)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .themedBackground()
        .onChange(of: session.title) { _, _ in markEdited() }
        .onChange(of: session.tagList) { _, _ in
            markEdited()
            save()
        }
        .onDisappear { save() }
        .confirmationDialog("Delete this session?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .alert("Couldn’t change the session",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private func header(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(alignment: .center, spacing: theme.spacingS) {
                TextField("Untitled session", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .focused($titleFocused)
                    .onSubmit {
                        titleFocused = false
                        save()
                    }
                    .modifier(DetailTitleFieldStyle(isFocused: titleFocused))
                    .accessibilityLabel("Session title")
                    .help("Rename")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { save() }
                    }
                moreMenu
            }

            metaLine

            HStack(alignment: .center, spacing: theme.spacingM) {
                // Constant cap instead of `.fixedSize()`, so a long label name can't widen the column.
                LabelPicker(selection: labelBinding, includeNone: true, title: "Label")
                    .labelsHidden()
                    .frame(minWidth: 0, maxWidth: 220, alignment: .leading)
                    .help("Label")
                TagPicker(selection: $session.tagList, scopeLabel: session.label)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }

            actionBar(proxy)
        }
    }

    /// One-click "Add Note" / "Add Image…" (the sections below also take paste and drop).
    private func actionBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: theme.spacingS) {
            Button {
                addNote(proxy)
            } label: {
                Label("Add Note", systemImage: "square.and.pencil")
            }
            .help("Add note")

            Button {
                addImages(proxy)
            } label: {
                Label("Add Image…", systemImage: "photo.badge.plus")
            }
            .help("Add images")

            Spacer(minLength: 0)
        }
        .buttonStyle(QuietButtonStyle())
        .controlSize(.small)
        .padding(.top, theme.spacingXS)
    }

    private var moreMenu: some View {
        Menu {
            Button("Edit Start and End…") { isEditingTimes = true }
                .disabled(session.isActive)
            Divider()
            Button("Delete Session…", role: .destructive) { confirmDelete = true }
                .disabled(session.isActive)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    private var metaLine: some View {
        HStack(alignment: .center, spacing: theme.spacingXS) {
            Text(timeRangeText)
                .monospacedDigit()
            Button {
                isEditingTimes = true
            } label: {
                Image(systemName: "clock.badge.checkmark")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .disabled(session.isActive)
            .accessibilityLabel("Edit start and end time")
            .help(session.isActive ? "Stop the session first" : "Edit times")
            .popover(isPresented: $isEditingTimes, arrowEdge: .bottom) {
                DetailTimesEditor(session: session) { isEditingTimes = false }
                    .environment(\.theme, theme)
                    .environment(\.modelContext, context)
                    .tint(theme.accent)
            }
            durationsText
        }
        .font(theme.calloutFont)
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var durationsText: some View {
        if session.isActive && !session.isPaused {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                durations(at: context.date)
            }
        } else {
            durations(at: .now)
        }
    }

    private func durations(at date: Date) -> some View {
        let active = session.activeDuration(at: date)
        let paused = session.pausedDuration(at: date)
        var text = "· \(active.formattedShort) active"
        if paused >= 1 { text += " · \(paused.formattedShort) paused" }
        var spoken: String = "Active " + DesignSystemDurationSpeech.spoken(active)
        if paused >= 1 { spoken += ", paused " + DesignSystemDurationSpeech.spoken(paused) }
        return Text(text)
            .monospacedDigit()
            .accessibilityLabel(spoken)
    }

    /// "Wed, Oct 7 · 9:02 AM – 10:20 AM" (end date added when the session crosses midnight).
    private var timeRangeText: String {
        let start = session.startedAt
        let sameYear = Calendar.current.isDate(start, equalTo: .now, toGranularity: .year)
        let day = sameYear
            ? start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        guard let end = session.endedAt else {
            return "\(day) · \(start.shortTime) – now"
        }
        let endText = end.isSameDay(as: start)
            ? end.shortTime
            : end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(day) · \(start.shortTime) – \(endText)"
    }

    private var labelBinding: Binding<WorkLabel?> {
        Binding(
            get: { session.label },
            set: { newValue in
                guard newValue?.persistentModelID != session.label?.persistentModelID else { return }
                SessionEditor.setPrimaryLabel(newValue, for: session, in: context)
            }
        )
    }

    // MARK: - Actions

    private var isAlive: Bool { !session.isDeleted && session.modelContext != nil }

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private func addNote(_ proxy: ScrollViewProxy) {
        guard isAlive else { return }
        isComposingNote = true
        scroll(proxy, to: DetailAnchor.notes)
    }

    private func addImages(_ proxy: ScrollViewProxy) {
        guard isAlive else { return }
        let added = AttachmentImporter.addFromOpenPanel(to: session, in: context)
        if !added.isEmpty {
            scroll(proxy, to: DetailAnchor.images)
        }
    }

    /// Scrolls after the next layout pass so newly shown content (e.g. the note composer) is measured.
    private func scroll(_ proxy: ScrollViewProxy, to anchor: DetailAnchor) {
        let animate = !reduceMotion
        Task { @MainActor in
            await Task.yield()
            if animate {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .top) }
            } else {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private func markEdited() {
        guard isAlive else { return }
        session.touch()
    }

    private func save() {
        guard isAlive else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("SessionDetailView save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears the selection first (History then unmounts this view), and deletes a moment later so no
    /// view still shows the model when it goes away. The engine refreshes the takeaway on save.
    private func deleteSession() {
        guard isAlive else { return }
        let context = self.context
        let session = self.session
        let router = self.router
        let id = session.persistentModelID
        let wasSelected = router?.selectedSessionID == id
        if wasSelected {
            router?.selectedSessionID = nil
        }
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            guard !session.isDeleted, session.modelContext != nil else { return }
            do {
                try SessionEditor.deleteSession(session, in: context)
            } catch {
                Log.persistence.error("Delete session failed: \(error.localizedDescription, privacy: .public)")
                // Re-select the session so it is clear it still exists; the alert below shows when this
                // view is still on screen (it was not the History selection).
                if wasSelected, router?.selectedSessionID == nil {
                    router?.selectedSessionID = id
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Scroll targets inside the session detail.
enum DetailAnchor: Hashable {
    case notes, images
}

// MARK: - Title field look

/// Plain title text at rest; inset well while editing — same metrics both ways so nothing jumps.
private struct DetailTitleFieldStyle: ViewModifier {
    let isFocused: Bool
    @Environment(\.theme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFocused {
            content.insetField(isFocused: true)
        } else {
            content
                .padding(.horizontal, theme.spacingS)
                .padding(.vertical, theme.spacingXS + 2)
        }
    }
}

// MARK: - Times editor

/// Popover: start and end `DatePicker`s (stepper fields), Save / Cancel, errors inline.
/// Saves through `SessionEditor.setTimes` (segments and pauses follow).
@MainActor
struct DetailTimesEditor: View {
    @Environment(\.theme) private var theme
    private let session: WorkSession
    private let onDone: () -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var error: String?

    init(session: WorkSession, onDone: @escaping () -> Void) {
        self.session = session
        self.onDone = onDone
        self._start = State(initialValue: session.startedAt)
        self._end = State(initialValue: session.endedAt ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            Text("Session time")
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: theme.spacingM, verticalSpacing: theme.spacingS) {
                GridRow {
                    Text("Start")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textSecondary)
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
                GridRow {
                    Text("End")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textSecondary)
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
            }

            Text(end > start
                 ? "Wall time \(end.timeIntervalSince(start).formattedShort); segments and pauses adjust to fit."
                 : "The end must be after the start.")
                .font(theme.captionFont)
                .foregroundStyle(end > start ? theme.textTertiary : theme.danger)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(end > start))
            }
        }
        .padding(theme.spacingL)
        .frame(width: 320)
        .onChange(of: start) { _, _ in error = nil }
        .onChange(of: end) { _, _ in error = nil }
    }

    private func save() {
        guard let context = session.modelContext, !session.isDeleted else {
            onDone()
            return
        }
        do {
            try SessionEditor.setTimes(of: session, start: start, end: end, in: context)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview("Session detail") {
    SessionDetailView(session: PreviewData.sampleSession)
        .withAppServices(.preview)
        .frame(width: 760, height: 900)
}
