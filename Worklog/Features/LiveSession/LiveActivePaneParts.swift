import AppKit
import SwiftData
import SwiftUI

// MARK: - Active pane pieces

/// The running session's profile (shown with 2+ profiles). A session keeps running in its own profile when the
/// user switches (the page's "Running in “Work”" banner offers to switch back); the menu offers "Move to" the
/// other profiles (asking first when labels or tags would be copied).
@MainActor
struct LiveSessionProfileMenu: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let session: WorkSession

    @State private var pendingMove: LiveProfileMove.Request?

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let sessionProfile = ModelLiveness.isLive(session) ? ProfileOps.effectiveProfile(of: session) : nil
        let targets = ModelLiveness.live(profiles.profiles).filter { $0.uuid != sessionProfile?.uuid }

        Menu {
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
        .liveChildSheet(isPresented: pendingMove != nil)
    }

    private func requestMove(to target: WorkProfile) {
        if case .needsConfirmation(let request) = LiveProfileMove.begin(moving: session, to: target,
                                                                        in: modelContext) {
            pendingMove = request
        }
    }
}

@MainActor
struct LiveSegmentRow: View {
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
        if ModelLiveness.isLive(segment) {
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
/// new notes. Context menu: Copy, Edit (inline editor: Return saves, Esc cancels), Delete (confirmed).
@MainActor
struct LiveNotesList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    private let notes: [Note]
    @State private var contentHeight: CGFloat = 0
    @State private var editingNoteID: PersistentIdentifier?
    @State private var editText = ""
    @State private var deleteCandidate: Note?
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
                        if ModelLiveness.isLive(note) {
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
        .confirmationDialog("Delete this note?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteCandidate) { note in
            Button("Delete Note", role: .destructive) { delete(note) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .liveChildSheet(isPresented: deleteCandidate != nil)
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
                    Button("Delete Note…", role: .destructive) { deleteCandidate = note }
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
        guard ModelLiveness.isLive(note) else { return }
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
        guard !text.isEmpty, ModelLiveness.isLive(note), text != note.text else { return }
        SessionEditor.updateNote(note, text: text, date: nil, in: modelContext)
    }

    private func delete(_ note: Note) {
        deleteCandidate = nil
        guard ModelLiveness.isLive(note) else { return }
        if editingNoteID == note.persistentModelID { cancelEditing() }
        SessionEditor.deleteNote(note, in: modelContext)
    }

    private func cancelEditing() {
        editingNoteID = nil
        editorFocused = false
        editText = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = notes.last(where: { ModelLiveness.isLive($0) }) else { return }
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
struct LiveAttachmentStrip: View {
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
                    if ModelLiveness.isLive(attachment) {
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
            // The full image may not have synced to this Mac yet.
            Button("Save Image…") { AttachmentImporter.saveToDisk(attachment) }
                .disabled(attachment.data == nil)
            Divider()
            Button("Delete Image", role: .destructive) {
                SessionEditor.deleteAttachment(attachment, in: modelContext)
            }
        }
    }
}

/// "Still working?" banner with three actions (InlineBanner has room for one). "Stop at 9:02" (the last note,
/// split or resume) only shows when there was activity after the start.
@MainActor
struct LiveLongSessionBanner: View {
    @Environment(\.theme) private var theme
    private let hours: Int
    private let lastActivity: Date?
    private let onStopAtLastActivity: () -> Void
    private let onStopNow: () -> Void
    private let onKeepGoing: () -> Void

    init(hours: Int, lastActivity: Date?, onStopAtLastActivity: @escaping () -> Void,
         onStopNow: @escaping () -> Void, onKeepGoing: @escaping () -> Void) {
        self.hours = hours
        self.lastActivity = lastActivity
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
                if let lastActivity {
                    Button("Stop at \(stopTime(lastActivity))", action: onStopAtLastActivity)
                        .help("Ends at your last note, split or resume.")
                        .accessibilityHint("Ends at your last note, split or resume.")
                }
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

    /// "9:02", or with the day when it wasn't today.
    private func stopTime(_ date: Date) -> String {
        date.isSameDay(as: Date()) ? date.shortTime : date.shortDateTime
    }
}
