import SwiftUI
import SwiftData

/// Chronological notes of a session (`NoteRow` with segment caption). Add a note at any time inside the
/// session, edit its text and timestamp, delete — all through `SessionEditor` (segment reassigned by time).
@MainActor
struct DetailNotesSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    private let session: WorkSession

    /// Owned by the host so its "Add Note" button can open the composer.
    @Binding private var isComposing: Bool
    @State private var editingNoteID: UUID?
    @State private var deleteCandidate: Note?

    init(session: WorkSession, isComposing: Binding<Bool>) {
        self.session = session
        self._isComposing = isComposing
    }

    var body: some View {
        let notes = ModelLiveness.live(session.sortedNotes)
        VStack(alignment: .leading, spacing: theme.spacingS) {
            SectionHeader("Notes", systemImage: "note.text") {
                HStack(spacing: theme.spacingS) {
                    if !notes.isEmpty {
                        Text("\(notes.count)")
                            .monospacedDigit()
                            .accessibilityLabel("\(notes.count) notes")
                    }
                    Button {
                        editingNoteID = nil
                        isComposing = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .accessibilityLabel("Add note")
                    .help("Add note")
                }
            }

            if isComposing {
                DetailNoteEditor(initialText: "",
                                 initialDate: defaultNoteDate,
                                 range: noteRange,
                                 saveTitle: "Add Note",
                                 onSave: { text, date, _ in add(text, at: date) },
                                 onCancel: { isComposing = false })
            }

            if notes.isEmpty && !isComposing {
                Text("No notes.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textTertiary)
            }

            ForEach(notes, id: \.uuid) { note in
                if editingNoteID == note.uuid {
                    DetailNoteEditor(initialText: note.text,
                                     initialDate: note.createdAt,
                                     range: noteRange,
                                     saveTitle: "Save",
                                     onSave: { text, date, timeChanged in
                                         update(note, text: text, date: timeChanged ? date : nil)
                                     },
                                     onCancel: { editingNoteID = nil })
                } else {
                    noteRow(note)
                }
            }
        }
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
        .onChange(of: isComposing) { _, composing in
            // Opening the composer (also from the host's button) ends any inline edit.
            if composing { editingNoteID = nil }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: theme.spacingS) {
            NoteRow(note: note, showsSegment: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Menu {
                noteMenuItems(note)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, theme.spacingXS)
            .help("More")
            .accessibilityLabel("Note actions")
        }
        .contextMenu { noteMenuItems(note) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit") { startEditing(note) }
        .accessibilityAction(named: "Delete") { deleteCandidate = note }
    }

    @ViewBuilder
    private func noteMenuItems(_ note: Note) -> some View {
        Button("Edit…") { startEditing(note) }
        Button("Change Time…") { startEditing(note) }
        Divider()
        Button("Delete Note…", role: .destructive) { deleteCandidate = note }
    }

    // MARK: - Model

    private var context: ModelContext { session.modelContext ?? environmentContext }

    /// Notes may be placed anywhere inside the session (up to now while it runs).
    private var noteRange: ClosedRange<Date> {
        let end = max(session.startedAt, session.endedAt ?? .now)
        return session.startedAt...end
    }

    private var defaultNoteDate: Date {
        session.endedAt ?? .now
    }

    private func startEditing(_ note: Note) {
        isComposing = false
        editingNoteID = note.uuid
    }

    private func add(_ text: String, at date: Date) {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, ModelLiveness.isLive(session) else { return }
        SessionEditor.addNote(trimmed, at: date, to: session, in: context)
        isComposing = false
    }

    private func update(_ note: Note, text: String, date: Date?) {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, ModelLiveness.isLive(note) else { return }
        SessionEditor.updateNote(note, text: trimmed, date: date, in: context)
        editingNoteID = nil
    }

    private func delete(_ note: Note) {
        deleteCandidate = nil
        guard ModelLiveness.isLive(note) else { return }
        if editingNoteID == note.uuid { editingNoteID = nil }
        SessionEditor.deleteNote(note, in: context)
    }
}

// MARK: - Editor

/// Inline note editor: multi-line text (Return saves, Esc cancels) + time stepper clamped to the session.
@MainActor
private struct DetailNoteEditor: View {
    @Environment(\.theme) private var theme
    private let range: ClosedRange<Date>
    private let saveTitle: String
    private let onSave: (String, Date, Bool) -> Void
    private let onCancel: () -> Void

    @State private var text: String
    @State private var date: Date
    @State private var timeChanged = false
    @FocusState private var textFocused: Bool

    init(initialText: String, initialDate: Date, range: ClosedRange<Date>, saveTitle: String,
         onSave: @escaping (String, Date, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.range = range
        self.saveTitle = saveTitle
        self.onSave = onSave
        self.onCancel = onCancel
        self._text = State(initialValue: initialText)
        self._date = State(initialValue: min(max(initialDate, range.lowerBound), range.upperBound))
    }

    var body: some View {
        let components: DatePickerComponents = range.lowerBound.isSameDay(as: range.upperBound)
            ? [.hourAndMinute] : [.date, .hourAndMinute]
        VStack(alignment: .leading, spacing: theme.spacingS) {
            TextField("Write a note…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .lineLimit(1...10)
                .focused($textFocused)
                .onSubmit(save)
                .onExitCommand(perform: onCancel)
                .insetField(isFocused: textFocused)
                .accessibilityLabel("Note text")

            HStack(spacing: theme.spacingS) {
                Image(systemName: "clock")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                DatePicker("Time", selection: $date, in: range, displayedComponents: components)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .accessibilityLabel("Note time")
                Spacer(minLength: theme.spacingS)
                Button("Cancel", action: onCancel)
                    .buttonStyle(QuietButtonStyle())
                    .controlSize(.small)
                Button(saveTitle, action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(text.isBlank)
            }
        }
        .modifier(CardSurfaceModifier(padding: theme.spacingM))
        .onChange(of: date) { _, _ in timeChanged = true }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                textFocused = true
            }
        }
    }

    private func save() {
        guard !text.isBlank else { return }
        onSave(text, date, timeChanged)
    }
}
