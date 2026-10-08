import SwiftUI
import SwiftData

/// Segments of a session: a timeline strip (wall time, label colors, hover tooltips), one row per segment
/// (label, focus, tags, times, active duration, a visible Split… button, ⋯ menu / context menu) and a
/// boundary handle between rows.
/// Every structural edit goes through `SessionEditor` (split, merge, delete, move boundary);
/// label/tags/focus edits write to the segment directly, then touch and save.
@MainActor
struct DetailSegmentsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    private let session: WorkSession

    @State private var splitRequest: DetailSplitRequest?
    @State private var boundarySegmentID: UUID?
    @State private var deleteCandidate: Segment?
    @State private var errorMessage: String?

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let segments = session.sortedSegments.filter { !$0.isDeleted }
        VStack(alignment: .leading, spacing: theme.spacingS) {
            SectionHeader("Segments", systemImage: "rectangle.split.3x1") {
                Text("\(segments.count)")
                    .monospacedDigit()
                    .accessibilityLabel("\(segments.count) segments")
            }

            if !segments.isEmpty {
                timeline(segments)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.uuid) { index, segment in
                    DetailSegmentRow(
                        segment: segment,
                        endDate: endDate(of: segment),
                        isLast: index == segments.count - 1,
                        isOnly: segments.count == 1,
                        onSplit: { splitRequest = DetailSplitRequest(segmentID: segment.uuid) },
                        onMerge: { merge(segment) },
                        onMoveEnd: { boundarySegmentID = segment.uuid },
                        onDelete: { deleteCandidate = segment }
                    )
                    if index < segments.count - 1 {
                        DetailBoundaryHandle(
                            session: session,
                            segment: segment,
                            next: segments[index + 1],
                            isPresented: Binding(
                                get: { boundarySegmentID == segment.uuid },
                                set: { presented in
                                    if presented {
                                        boundarySegmentID = segment.uuid
                                    } else if boundarySegmentID == segment.uuid {
                                        boundarySegmentID = nil
                                    }
                                }
                            )
                        )
                    }
                }
            }

            if segments.count == 1 {
                Text("Split to add a switch you missed.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $splitRequest) { request in
            DetailSplitSheet(session: session, initialSegmentID: request.segmentID)
                .environment(\.theme, theme)
                .environment(\.modelContext, context)
                .tint(theme.accent)
        }
        .confirmationDialog("Delete this segment?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteCandidate) { segment in
            Button("Delete Segment", role: .destructive) { delete(segment) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("Its time and notes go to the neighbouring segment.")
        }
        .alert("Couldn’t change the segments",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Timeline

    private func timeline(_ segments: [Segment]) -> some View {
        let parts = segments.map { segment in
            ProportionBar.Part(
                value: segment.interval().duration,
                color: segment.effectiveLabel?.color ?? theme.textTertiary,
                label: "\(segment.displayFocus) · \(segment.startedAt.shortTime)–\(endText(of: segment))"
            )
        }
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            ProportionBar(parts: parts, height: 10)
            HStack {
                Text(session.startedAt.shortTime)
                Spacer()
                Text(session.endedAt?.shortTime ?? "now")
            }
            .font(theme.captionFont.monospacedDigit())
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
        }
        .padding(.bottom, theme.spacingXS)
    }

    // MARK: - Helpers

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private func endDate(of segment: Segment) -> Date? {
        segment.endedAt ?? session.endedAt
    }

    private func endText(of segment: Segment) -> String {
        endDate(of: segment)?.shortTime ?? "now"
    }

    private func merge(_ segment: Segment) {
        guard !segment.isDeleted else { return }
        do {
            try SessionEditor.mergeWithNext(segment, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ segment: Segment) {
        deleteCandidate = nil
        guard !segment.isDeleted else { return }
        do {
            try SessionEditor.deleteSegment(segment, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Identifies a pending split sheet.
struct DetailSplitRequest: Identifiable {
    let id = UUID()
    let segmentID: UUID
}

// MARK: - Segment row

@MainActor
private struct DetailSegmentRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    private let segment: Segment
    private let endDate: Date?
    private let isLast: Bool
    private let isOnly: Bool
    private let onSplit: () -> Void
    private let onMerge: () -> Void
    private let onMoveEnd: () -> Void
    private let onDelete: () -> Void

    @State private var isEditing = false
    @State private var isHovering = false

    init(segment: Segment, endDate: Date?, isLast: Bool, isOnly: Bool,
         onSplit: @escaping () -> Void, onMerge: @escaping () -> Void,
         onMoveEnd: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.segment = segment
        self.endDate = endDate
        self.isLast = isLast
        self.isOnly = isOnly
        self.onSplit = onSplit
        self.onMerge = onMerge
        self.onMoveEnd = onMoveEnd
        self.onDelete = onDelete
    }

    var body: some View {
        if segment.isDeleted || segment.modelContext == nil {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        let focusText = segment.focus.trimmed
        let rangeText = "\(segment.startedAt.shortTime)–\(endDate?.shortTime ?? "now")"
        let duration = segment.activeDuration()
        let spokenName: String = focusText.isEmpty ? (segment.effectiveLabel?.name ?? "Unlabeled") : focusText
        let accessibilityText: String = "Segment " + spokenName + ", " + rangeText + ", "
            + DesignSystemDurationSpeech.spoken(duration)
        return HStack(alignment: .center, spacing: theme.spacingM) {
            LabelBadge(label: segment.effectiveLabel, size: .small)
                .frame(maxWidth: 160, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(focusText.isEmpty ? "No focus set" : focusText)
                    .font(theme.bodyFont)
                    .foregroundStyle(focusText.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(focusText)
                    .frame(minWidth: 0, alignment: .leading)
                TagChipsRow(tags: segment.tagList)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(rangeText)
                .font(theme.captionFont.monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            Text(duration.formattedShort)
                .font(theme.timerCompactFont)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
                .fixedSize()

            // Always visible: splitting after the fact is the main fix-up on this page.
            Button(action: onSplit) {
                Label("Split…", systemImage: "scissors")
            }
            .buttonStyle(QuietButtonStyle())
            .controlSize(.small)
            .fixedSize()
            .help("Split segment")
            .accessibilityLabel("Split segment")

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("Segment actions")
        }
        .padding(.vertical, theme.spacingXS + 2)
        .padding(.horizontal, theme.spacingS)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                .fill(theme.textPrimary.opacity(isHovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { isEditing = true }
        .contextMenu { menuItems }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            DetailSegmentEditor(segment: segment) { isEditing = false }
                .environment(\.theme, theme)
                .environment(\.modelContext, segment.modelContext ?? modelContext)
                .tint(theme.accent)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Edit") { isEditing = true }
        .accessibilityAction(named: "Split") { onSplit() }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit…") { isEditing = true }
        Button("Split at…", action: onSplit)
        Button("Merge with Next", action: onMerge)
            .disabled(isLast)
        Button("Move End Time…", action: onMoveEnd)
            .disabled(isLast)
        Divider()
        Button("Delete Segment…", role: .destructive, action: onDelete)
            .disabled(isOnly)
    }
}

// MARK: - Segment editor (popover)

/// Label, tags and focus of one segment ("None" label = use the session's label).
@MainActor
private struct DetailSegmentEditor: View {
    @Environment(\.theme) private var theme
    @Bindable private var segment: Segment
    private let onDone: () -> Void
    @FocusState private var focusFieldFocused: Bool

    init(segment: Segment, onDone: @escaping () -> Void) {
        self._segment = Bindable(wrappedValue: segment)
        self.onDone = onDone
    }

    var body: some View {
        if segment.isDeleted || segment.modelContext == nil {
            EmptyView()
        } else {
            editor
        }
    }

    /// Labels and tags offered here are the session's profile's.
    private var profileID: UUID? {
        ModelLiveness.live(ModelLiveness.live(segment.session)?.profile)?.uuid
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
        guard !segment.isDeleted else { return }
        segment.session?.touch()
    }

    private func save() {
        guard !segment.isDeleted, let context = segment.modelContext else { return }
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
private struct DetailBoundaryHandle: View {
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
        guard !segment.isDeleted, !next.isDeleted, let context = segment.modelContext else {
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

// MARK: - Split sheet

/// Split a segment at a chosen time (DatePicker clamped inside the segment, ≥ minimumSegmentLength from
/// each end). The new segment gets the chosen label (None = keep the original's), tags and focus.
@MainActor
private struct DetailSplitSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let session: WorkSession

    @State private var segmentID: UUID
    @State private var date: Date
    @State private var label: WorkLabel?
    @State private var tags: [WorkTag]
    @State private var focus: String = ""
    @State private var error: String?
    @FocusState private var focusFieldFocused: Bool

    init(session: WorkSession, initialSegmentID: UUID) {
        self.session = session
        let segments = session.sortedSegments
        let segment = segments.first { $0.uuid == initialSegmentID } ?? segments.first
        self._segmentID = State(initialValue: segment?.uuid ?? initialSegmentID)
        self._date = State(initialValue: Self.midpoint(of: segment, in: session))
        self._label = State(initialValue: segment?.label)
        self._tags = State(initialValue: segment?.tagList ?? [])
    }

    static func end(of segment: Segment, in session: WorkSession) -> Date {
        segment.endedAt ?? session.endedAt ?? .now
    }

    static func midpoint(of segment: Segment?, in session: WorkSession) -> Date {
        guard let segment else { return session.startedAt }
        let segmentEnd = Self.end(of: segment, in: session)
        return segment.startedAt.addingTimeInterval(max(0, segmentEnd.timeIntervalSince(segment.startedAt)) / 2)
    }

    /// Allowed split times, or nil when the segment is too short.
    static func splitRange(of segment: Segment, in session: WorkSession) -> ClosedRange<Date>? {
        let lower = segment.startedAt.addingTimeInterval(SessionEditor.minimumSegmentLength)
        let upper = Self.end(of: segment, in: session).addingTimeInterval(-SessionEditor.minimumSegmentLength)
        return lower < upper ? lower...upper : nil
    }

    var body: some View {
        let segments = session.sortedSegments.filter { !$0.isDeleted }
        let selected = segments.first { $0.uuid == segmentID }
        let range = selected.flatMap { Self.splitRange(of: $0, in: session) }

        VStack(alignment: .leading, spacing: theme.spacingL) {
            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text("Split segment")
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                Text("The part after this time becomes a new segment.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: theme.spacingM, verticalSpacing: theme.spacingM) {
                if segments.count > 1 {
                    GridRow {
                        fieldLabel("Segment")
                        Picker("Segment", selection: $segmentID) {
                            ForEach(segments, id: \.uuid) { segment in
                                Text("\(segment.displayFocus) · \(segment.startedAt.shortTime)–\(Self.end(of: segment, in: session).shortTime)")
                                    .tag(segment.uuid)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    fieldLabel("Split at")
                    if let range {
                        DatePicker("Split at", selection: $date, in: range,
                                   displayedComponents: range.lowerBound.isSameDay(as: range.upperBound)
                                       ? [.hourAndMinute] : [.date, .hourAndMinute])
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                    } else {
                        Text("This segment is too short to split.")
                            .font(theme.calloutFont)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                GridRow {
                    fieldLabel("New focus")
                    TextField(selected?.focus.nilIfBlank ?? "What did you switch to?", text: $focus)
                        .textFieldStyle(.plain)
                        .focused($focusFieldFocused)
                        .insetField(isFocused: focusFieldFocused)
                }
                GridRow {
                    fieldLabel("Label")
                    LabelPicker(selection: $label, includeNone: true, title: "Label", profileID: profileID)
                        .labelsHidden()
                        .fixedSize()
                }
                GridRow {
                    fieldLabel("Tags")
                    TagPicker(selection: $tags, scopeLabel: label ?? session.label, profileID: profileID)
                }
            }

            if let selected, range != nil {
                Text(previewText(for: selected))
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    split(selected)
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(range == nil)
            }
        }
        .padding(theme.spacingXL)
        .frame(minWidth: 460, alignment: .leading)
        .onChange(of: segmentID) { _, newValue in
            let segment = session.sortedSegments.first { $0.uuid == newValue }
            date = Self.midpoint(of: segment, in: session)
            label = segment?.label
            tags = segment?.tagList ?? []
            error = nil
        }
        .onChange(of: date) { _, _ in error = nil }
    }

    /// Labels and tags offered here are the session's profile's.
    private var profileID: UUID? {
        session.isDeleted || session.modelContext == nil ? nil : ModelLiveness.live(session.profile)?.uuid
    }

    /// "Before: 9:02 AM–9:40 AM (38m) · After: 9:40 AM–10:15 AM (35m)"
    private func previewText(for segment: Segment) -> String {
        let start = segment.startedAt
        let segmentEnd = Self.end(of: segment, in: session)
        let before = "\(start.shortTime)–\(date.shortTime) (\(date.timeIntervalSince(start).formattedShort))"
        let after = "\(date.shortTime)–\(segmentEnd.shortTime) (\(segmentEnd.timeIntervalSince(date).formattedShort))"
        return "Before: \(before) · After: \(after)"
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.calloutFont)
            .foregroundStyle(theme.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    private func split(_ segment: Segment?) {
        guard let segment, !segment.isDeleted, let context = session.modelContext else {
            dismiss()
            return
        }
        do {
            try SessionEditor.split(segment, at: date, label: label, tags: tags, focus: focus, in: context)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
