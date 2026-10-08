import SwiftUI
import SwiftData

// MARK: - Split sheet

/// Identifies a pending split sheet.
struct DetailSplitRequest: Identifiable {
    let id = UUID()
    let segmentID: UUID
}

/// Split a segment at a chosen time (DatePicker clamped inside the segment, ≥ minimumSegmentLength from
/// each end). The new segment gets the chosen label (None = keep the original's), tags and focus.
@MainActor
struct DetailSplitSheet: View {
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
        let segments = ModelLiveness.live(session.sortedSegments)
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
        ModelLiveness.isLive(session) ? ProfileOps.effectiveProfileID(of: session) : nil
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
        guard let segment, ModelLiveness.isLive(segment), let context = session.modelContext else {
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
