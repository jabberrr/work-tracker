import SwiftUI
import SwiftData

/// Segments of a session: a timeline strip (wall time, label colors, hover tooltips), one row per segment
/// (label, focus, tags, times, active duration, a visible Split… button, ⋯ menu / context menu) and a
/// boundary handle between rows.
/// Every structural edit goes through `SessionEditor` (split, merge, delete, move boundary);
/// label/tags/focus edits write to the segment directly, then touch and save.
/// The row's editor popover and the boundary handle live in DetailSegmentEditor.swift, the Split sheet in
/// DetailSplitSheet.swift. The Split sheet counts as a child sheet of the main window
/// (`WindowRouter.childSheetDidAppear`), so a review sheet waits for it to close.
@MainActor
struct DetailSegmentsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    @Environment(WindowRouter.self) private var router: WindowRouter?
    private let session: WorkSession

    @State private var splitRequest: DetailSplitRequest?
    @State private var boundarySegmentID: UUID?
    @State private var deleteCandidate: Segment?
    @State private var errorMessage: String?

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let segments = ModelLiveness.live(session.sortedSegments)
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
                .onAppear { router?.childSheetDidAppear() }
                .onDisappear { router?.childSheetDidDisappear() }
        }
        .countsAsChildSheet(isPresented: deleteCandidate != nil)
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
        .countsAsChildSheet(isPresented: errorMessage != nil)
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
        guard ModelLiveness.isLive(segment) else { return }
        do {
            try SessionEditor.mergeWithNext(segment, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ segment: Segment) {
        deleteCandidate = nil
        guard ModelLiveness.isLive(segment) else { return }
        do {
            try SessionEditor.deleteSegment(segment, in: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
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
        if !ModelLiveness.isLive(segment) {
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
