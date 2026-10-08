import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable

/// Density of `LearningsEditor`.
enum LearningsEditorStyle {
    /// Session detail: every control visible (tags + mastery per learning point, taller text editor).
    case full
    /// End-of-session sheet: shorter text editor; learning-point tags/mastery behind a disclosure;
    /// at most 3 points visible until "Show more".
    case compact
}

/// The "what I learned" editor for one session:
/// - free-text `learningText` ("What I learned"),
/// - `overlaySummary` ("Takeaway for next time", 140-character guidance counter; typing a non-blank
///   summary turns `showInOverlay` on),
/// - the `showInOverlay` toggle,
/// - discrete `LearningPoint`s (add, edit, delete, reorder by drag or context menu, tags, mastery 1–5).
///
/// Edits write straight to the model, touch the session and save on submit / disappear; point creation,
/// deletion and reordering go through `SessionEditor`. The editor has no section header of its own:
/// the host adds one (e.g. `SectionHeader("Learnings", systemImage: "lightbulb")`).
/// Safe to keep on screen while the session is deleted (it renders nothing once the model is gone).
@MainActor
struct LearningsEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    @Environment(SessionEngine.self) private var engine: SessionEngine?

    @Bindable private var session: WorkSession
    private let style: LearningsEditorStyle
    private let showsTakeaway: Bool

    @State private var newPointText = ""
    @State private var showsPointDetails = false
    @State private var showsAllPoints = false
    @FocusState private var focusedField: LearningsField?

    /// - Parameter showsTakeaway: pass `false` when the host already edits `overlaySummary` itself (the end-of-session sheet).
    init(session: WorkSession, style: LearningsEditorStyle = .full, showsTakeaway: Bool = true) {
        self._session = Bindable(wrappedValue: session)
        self.style = style
        self.showsTakeaway = showsTakeaway
    }

    static let summaryGuidanceLength = 140

    var body: some View {
        if isAlive {
            content
        } else {
            EmptyView()
        }
    }

    // MARK: - Layout

    private var content: some View {
        VStack(alignment: .leading, spacing: style == .full ? theme.spacingL : theme.spacingM) {
            learningTextEditor
            if showsTakeaway {
                takeawayEditor
            }
            pointsEditor
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onChange(of: session.learningText) { _, _ in
            markEdited()
        }
        .onChange(of: session.overlaySummary) { oldValue, newValue in
            guard isAlive else { return }
            if oldValue.isBlank && !newValue.isBlank && !session.showInOverlay {
                session.showInOverlay = true
            }
            markEdited()
        }
        .onChange(of: session.showInOverlay) { _, _ in
            markEdited()
            persist()
        }
        .onChange(of: focusedField) { oldValue, _ in
            // Leaving a text field commits it.
            if oldValue == .learning || oldValue == .summary { persist() }
        }
        .onDisappear { persist() }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(theme.calloutFont.weight(.medium))
            .foregroundStyle(theme.textSecondary)
    }

    // MARK: Learning text

    private var learningTextEditor: some View {
        let isFocused = focusedField == .learning
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            fieldTitle("What I learned")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.learningText)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .learning)
                    .padding(.horizontal, theme.spacingXS)
                    .padding(.vertical, theme.spacingXS + 2)
                    .accessibilityLabel("What I learned")
                if session.learningText.isEmpty {
                    Text("What worked, what didn’t, what you’d do differently…")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, theme.spacingS + 1)
                        .padding(.vertical, theme.spacingXS + 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: style == .full ? 100 : 64,
                   idealHeight: style == .full ? 140 : 80,
                   maxHeight: style == .full ? 320 : 160)
            .background(shape.fill(theme.insetSurface))
            .overlay {
                shape.strokeBorder(isFocused ? theme.accent.opacity(0.8) : theme.separator,
                                   lineWidth: isFocused ? 1.5 : 1)
            }
        }
    }

    // MARK: Takeaway

    private var takeawayEditor: some View {
        let count = session.overlaySummary.trimmed.count
        let over = count > Self.summaryGuidanceLength
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .firstTextBaseline) {
                fieldTitle("Takeaway for next time")
                Spacer(minLength: theme.spacingS)
                Text("\(count)/\(Self.summaryGuidanceLength)")
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(over ? theme.warning : theme.textTertiary)
                    .help("Suggested length")
                    .accessibilityLabel("\(count) of \(Self.summaryGuidanceLength) suggested characters")
            }
            TextField("One line for next time", text: $session.overlaySummary)
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .focused($focusedField, equals: .summary)
                .onSubmit { persist() }
                .insetField(isFocused: focusedField == .summary)
                .accessibilityLabel("Takeaway for next time")

            Toggle("Show in overlay & menu bar", isOn: $session.showInOverlay)
                .toggleStyle(.checkbox)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textPrimary)

            if session.showInOverlay && session.takeawayText == nil {
                Text("Add a takeaway or learning to show.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if over {
                Text("Long takeaways are cut off in the overlay.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Learning points

    private var pointsEditor: some View {
        let points = livePoints
        let capped = style == .compact && !showsAllPoints && points.count > 3
        // Compact keeps the most recent points visible (new ones are appended at the end).
        let visible = capped ? Array(points.suffix(3)) : points
        let hiddenCount = points.count - visible.count
        let showsDetails = style == .full || showsPointDetails

        return VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                fieldTitle("Learning points")
                if !points.isEmpty {
                    Text("\(points.count)")
                        .font(theme.captionFont.monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityLabel("\(points.count) points")
                }
                Spacer(minLength: theme.spacingS)
                if style == .compact && !points.isEmpty {
                    Button {
                        showsPointDetails.toggle()
                    } label: {
                        Label(showsPointDetails ? "Hide tags & mastery" : "Tags & mastery",
                              systemImage: showsPointDetails ? "chevron.down" : "chevron.right")
                            .font(theme.captionFont)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .help(showsPointDetails ? "Hide details" : "Show details")
                }
            }

            if hiddenCount > 0 {
                Button("Show \(hiddenCount) earlier \(hiddenCount == 1 ? "point" : "points")") {
                    showsAllPoints = true
                }
                .buttonStyle(.plain)
                .font(theme.captionFont)
                .foregroundStyle(theme.accent)
            }

            ForEach(visible, id: \.uuid) { point in
                let index = points.firstIndex(where: { $0.uuid == point.uuid }) ?? 0
                LearningsPointRow(
                    point: point,
                    scopeLabel: session.label,
                    profileID: ProfileOps.effectiveProfileID(of: session),
                    showsDetails: showsDetails,
                    canMoveUp: index > 0,
                    canMoveDown: index < points.count - 1,
                    focusedField: $focusedField,
                    onEdited: { markEdited() },
                    onCommit: { commit(point) },
                    onMove: { offset in move(point, by: offset) },
                    onDropPoint: { draggedID in move(draggedID, onto: point) },
                    onDelete: { delete(point) }
                )
            }

            if points.isEmpty {
                Text("Tag points to follow a topic on the Learning page.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            newPointComposer
        }
    }

    private var newPointComposer: some View {
        HStack(spacing: theme.spacingS) {
            Image(systemName: "plus")
                .font(theme.captionFont.weight(.semibold))
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Add a learning point", text: $newPointText)
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .focused($focusedField, equals: .newPoint)
                .onSubmit(addPoint)
                .accessibilityLabel("New learning point")
            Button("Add", action: addPoint)
                .buttonStyle(QuietButtonStyle())
                .controlSize(.small)
                .disabled(newPointText.isBlank)
                .help("Add learning point")
        }
        .insetField(isFocused: focusedField == .newPoint)
    }

    // MARK: - Model

    private var isAlive: Bool { !session.isDeleted && session.modelContext != nil }

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private var livePoints: [LearningPoint] {
        session.sortedLearningPoints.filter { !$0.isDeleted }
    }

    /// A user edit: an unassigned session is written into its effective profile first.
    private func markEdited() {
        guard isAlive else { return }
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        session.touch()
    }

    /// Saves pending edits and lets the engine pick up a changed takeaway.
    private func persist() {
        guard isAlive else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("LearningsEditor save failed: \(error.localizedDescription, privacy: .public)")
        }
        engine?.refreshTakeaway()
    }

    private func addPoint() {
        let text = newPointText.trimmed
        guard !text.isEmpty, isAlive else { return }
        SessionEditor.addLearningPoint(text, tags: [], to: session, in: context)
        newPointText = ""
        focusedField = .newPoint
    }

    /// Return in a point's field: a point emptied by the user is removed, otherwise saved.
    private func commit(_ point: LearningPoint) {
        guard isAlive, !point.isDeleted else { return }
        if point.text.isBlank {
            delete(point)
            focusedField = .newPoint
        } else {
            persist()
        }
    }

    private func delete(_ point: LearningPoint) {
        guard isAlive, !point.isDeleted else { return }
        if focusedField == .point(point.uuid) { focusedField = nil }
        SessionEditor.deleteLearningPoint(point, in: context)
    }

    private func move(_ point: LearningPoint, by offset: Int) {
        guard isAlive, !point.isDeleted else { return }
        var points = livePoints
        guard let from = points.firstIndex(where: { $0.uuid == point.uuid }) else { return }
        let to = from + offset
        guard points.indices.contains(to) else { return }
        points.swapAt(from, to)
        SessionEditor.reorderLearningPoints(points)
    }

    /// Drop `draggedID` onto `target`: the dragged point takes the target's position.
    private func move(_ draggedID: UUID, onto target: LearningPoint) {
        guard isAlive, !target.isDeleted else { return }
        var points = livePoints
        guard let from = points.firstIndex(where: { $0.uuid == draggedID }),
              let to = points.firstIndex(where: { $0.uuid == target.uuid }),
              from != to else { return }
        let item = points.remove(at: from)
        points.insert(item, at: min(to, points.count))
        SessionEditor.reorderLearningPoints(points)
    }
}

// MARK: - Focus

private enum LearningsField: Hashable {
    case learning, summary, newPoint
    case point(UUID)
}

// MARK: - Drag payload

/// In-app drag payload for reordering learning points. Generic `.data` (not text) so text fields
/// never accept it as a string drop.
private struct LearningsPointDragItem: Codable, Transferable {
    let uuid: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Point row

@MainActor
private struct LearningsPointRow: View {
    @Environment(\.theme) private var theme
    @Bindable private var point: LearningPoint
    private let scopeLabel: WorkLabel?
    /// The session's profile: point tags offered here are its tags (global + local).
    private let profileID: UUID?
    private let showsDetails: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private var focusedField: FocusState<LearningsField?>.Binding
    private let onEdited: () -> Void
    private let onCommit: () -> Void
    private let onMove: (Int) -> Void
    private let onDropPoint: (UUID) -> Void
    private let onDelete: () -> Void

    @State private var isDropTarget = false

    init(point: LearningPoint, scopeLabel: WorkLabel?, profileID: UUID?, showsDetails: Bool,
         canMoveUp: Bool, canMoveDown: Bool,
         focusedField: FocusState<LearningsField?>.Binding,
         onEdited: @escaping () -> Void, onCommit: @escaping () -> Void, onMove: @escaping (Int) -> Void,
         onDropPoint: @escaping (UUID) -> Void, onDelete: @escaping () -> Void) {
        self._point = Bindable(wrappedValue: point)
        self.scopeLabel = scopeLabel
        self.profileID = profileID
        self.showsDetails = showsDetails
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.focusedField = focusedField
        self.onEdited = onEdited
        self.onCommit = onCommit
        self.onMove = onMove
        self.onDropPoint = onDropPoint
        self.onDelete = onDelete
    }

    var body: some View {
        if point.isDeleted || point.modelContext == nil {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        let isFocused = focusedField.wrappedValue == .point(point.uuid)
        return HStack(alignment: .top, spacing: theme.spacingS) {
            Image(systemName: "line.3.horizontal")
                .font(theme.captionFont.weight(.semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 16, height: 26)
                .contentShape(Rectangle())
                .draggable(LearningsPointDragItem(uuid: point.uuid)) {
                    Text(point.text.isBlank ? "Learning point" : point.text)
                        .font(theme.bodyFont)
                        .lineLimit(1)
                        .padding(theme.spacingS)
                }
                .help("Reorder")
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                TextField("Learning point", text: $point.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1...6)
                    .focused(focusedField, equals: .point(point.uuid))
                    .onSubmit(onCommit)
                    .insetField(isFocused: isFocused)
                    .accessibilityLabel("Learning point")

                if showsDetails {
                    HStack(alignment: .center, spacing: theme.spacingM) {
                        TagPicker(selection: $point.tagList, scopeLabel: scopeLabel, profileID: profileID)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        LearningsMasteryControl(rating: $point.mastery)
                    }
                } else if !point.tagList.isEmpty || point.mastery > 0 {
                    HStack(spacing: theme.spacingS) {
                        TagChipsRow(tags: point.tagList)
                            .frame(minWidth: 0, alignment: .leading)
                        if point.mastery > 0 {
                            Text("Mastery \(point.mastery)/5")
                                .font(theme.captionFont.monospacedDigit())
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .padding(.top, 2)
            .accessibilityLabel("Delete learning point")
            .help("Delete")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .fill(theme.accent.opacity(0.06))
            }
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: LearningsPointDragItem.self) { items, _ in
            guard let item = items.first, item.uuid != point.uuid else { return false }
            onDropPoint(item.uuid)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .contextMenu {
            Button("Move Up") { onMove(-1) }
                .disabled(!canMoveUp)
            Button("Move Down") { onMove(1) }
                .disabled(!canMoveDown)
            Divider()
            Button("Delete Learning Point", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { if canMoveUp { onMove(-1) } }
        .accessibilityAction(named: "Move down") { if canMoveDown { onMove(1) } }
        .accessibilityAction(named: "Delete") { onDelete() }
        .onChange(of: point.text) { _, _ in onEdited() }
        .onChange(of: point.mastery) { _, _ in onEdited() }
        .onChange(of: point.tagList) { _, _ in onEdited() }
    }
}

// MARK: - Mastery

/// "Mastery" caption + five small circles, filled up to the rating in the accent color; clicking the
/// current value clears it. Each dot's tooltip names its value ("How well you know this: 3 of 5").
@MainActor
private struct LearningsMasteryControl: View {
    @Environment(\.theme) private var theme
    @Binding private var rating: Int

    init(rating: Binding<Int>) {
        self._rating = rating
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Mastery")
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            dots
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mastery")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(5, rating + 1)
            case .decrement: rating = max(0, rating - 1)
            @unknown default: break
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                let filled = value <= rating
                Button {
                    rating = (rating == value) ? 0 : value
                } label: {
                    Circle()
                        .fill(filled ? theme.accent : theme.accent.opacity(0))
                        .overlay {
                            Circle().strokeBorder(filled ? theme.accent : theme.textTertiary, lineWidth: 1)
                        }
                        .frame(width: 8, height: 8)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(rating == value ? "Clear mastery" : "How well you know this: \(value) of 5")
            }
        }
    }
}

#Preview("Learnings editor — compact") {
    LearningsEditor(session: PreviewData.sampleSession, style: .compact)
        .padding(24)
        .frame(width: 520)
        .withAppServices(.preview)
}
