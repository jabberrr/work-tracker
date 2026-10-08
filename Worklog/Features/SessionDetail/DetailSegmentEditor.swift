import SwiftUI
import SwiftData

// MARK: - Segment editor (popover)

/// Label, tags and focus of one segment ("None" label = use the session's label).
@MainActor
struct DetailSegmentEditor: View {
    @Environment(\.theme) private var theme
    @Bindable private var segment: Segment
    private let onDone: () -> Void
    @FocusState private var focusFieldFocused: Bool

    init(segment: Segment, onDone: @escaping () -> Void) {
        self._segment = Bindable(wrappedValue: segment)
        self.onDone = onDone
    }

    var body: some View {
        if !ModelLiveness.isLive(segment) {
            EmptyView()
        } else {
            editor
        }
    }

    /// Labels and tags offered here are the session's profile's.
    private var profileID: UUID? {
        ModelLiveness.live(segment.session).flatMap { ProfileOps.effectiveProfileID(of: $0) }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            Text("Edit segment")
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text("Focus")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                TextField("What was this part about?", text: $segment.focus)
                    .textFieldStyle(.plain)
                    .focused($focusFieldFocused)
                    .onSubmit(finish)
                    .insetField(isFocused: focusFieldFocused)
            }

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                LabelPicker(selection: $segment.label, includeNone: true, title: "Label", profileID: profileID)
                Text("None uses the session’s label.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text("Tags")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                TagPicker(selection: $segment.tagList, scopeLabel: segment.effectiveLabel, profileID: profileID)
            }

            HStack {
                Spacer()
                Button("Done", action: finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.spacingL)
        .frame(width: 320)
        .onChange(of: segment.focus) { _, _ in touch() }
        .onChange(of: segment.label) { _, _ in touch() }
        .onChange(of: segment.tagList) { _, _ in touch() }
        .onDisappear { save() }
    }

    private func touch() {
        guard ModelLiveness.isLive(segment), let session = ModelLiveness.live(segment.session) else { return }
        if let context = segment.modelContext {
            ProfileOps.assignProfileIfUnassigned(session, in: context)
        }
        session.touch()
    }

    private func save() {
        guard ModelLiveness.isLive(segment), let context = segment.modelContext else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("Segment edit save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish() {
        save()
        onDone()
    }
}

// MARK: - Boundary handle

/// "⇆ 10:15" between two rows → popover to move the boundary (SessionEditor.moveBoundary).
@MainActor
struct DetailBoundaryHandle: View {
    @Environment(\.theme) private var theme
    private let session: WorkSession
    private let segment: Segment
    private let next: Segment
    @Binding private var isPresented: Bool

    init(session: WorkSession, segment: Segment, next: Segment, isPresented: Binding<Bool>) {
        self.session = session
        self.segment = segment
        self.next = next
        self._isPresented = isPresented
    }

    var body: some View {
        let time = (segment.endedAt ?? next.startedAt).shortTime
        HStack(spacing: theme.spacingS) {
            Button {
                isPresented = true
            } label: {
                Label(time, systemImage: "arrow.left.and.right")
                    .font(theme.captionFont.monospacedDigit())
            }
            .buttonStyle(QuietButtonStyle())
            .controlSize(.small)
            .help("Move boundary")
            .accessibilityLabel("Move boundary at \(time)")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                DetailBoundaryEditor(session: session, segment: segment, next: next) { isPresented = false }
                    .environment(\.theme, theme)
                    .tint(theme.accent)
            }
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .padding(.leading, theme.spacingL)
        .padding(.vertical, 2)
    }
}

@MainActor
private struct DetailBoundaryEditor: View {
    @Environment(\.theme) private var theme
    private let session: WorkSession
    private let segment: Segment
    private let next: Segment
    private let onDone: () -> Void

    @State private var date: Date
    @State private var error: String?

    init(session: WorkSession, segment: Segment, next: Segment, onDone: @escaping () -> Void) {
        self.session = session
        self.segment = segment
        self.next = next
        self.onDone = onDone
        self._date = State(initialValue: segment.endedAt ?? next.startedAt)
    }

    private var lowerBound: Date { segment.startedAt.addingTimeInterval(SessionEditor.minimumSegmentLength) }
    private var upperBound: Date {
        (next.endedAt ?? session.endedAt ?? .now).addingTimeInterval(-SessionEditor.minimumSegmentLength)
    }

    var body: some View {
        let lower = lowerBound
        let upper = upperBound
        let valid = lower < upper
        let components: DatePickerComponents = lower.isSameDay(as: upper) ? [.hourAndMinute] : [.date, .hourAndMinute]

        VStack(alignment: .leading, spacing: theme.spacingM) {
            Text("Move boundary")
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
            Text("“\(segment.displayFocus)” ends and “\(next.displayFocus)” starts at:")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if valid {
                DatePicker("Boundary", selection: $date, in: lower...upper, displayedComponents: components)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                Text("Between \(lower.shortTime) and \(upper.shortTime).")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("These segments are too short to adjust.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }

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
                    .disabled(!valid)
            }
        }
        .padding(theme.spacingL)
        .frame(width: 300)
        .onChange(of: date) { _, _ in error = nil }
    }

    private func save() {
        guard ModelLiveness.isLive(segment), ModelLiveness.isLive(next), let context = segment.modelContext else {
            onDone()
            return
        }
        do {
            try SessionEditor.moveBoundary(after: segment, to: date, in: context)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
