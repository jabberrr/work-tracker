import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Overlay ▸ Layout: a real-size preview of the overlay (current theme, compact setting and opacity)
/// with an edit mode in the spirit of iPhone Control Center:
/// - elements wiggle (a dashed outline under Reduce Motion) and carry a (−) badge that removes them
/// - drag an element onto another to reorder (live, as the drag moves)
/// - (+) adds an element that isn't shown
/// - context menu and accessibility actions: Move Up / Move Down / Remove
///
/// Every change writes `settings.overlayLayout` immediately, so the real overlay follows live.
/// Preview and edit mode never touch the engine (`OverlayContent` ignores hits outside `.live`).
@MainActor
struct OverlayLayoutEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Environment(WindowRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sample's label is the default label (no fetch in `body`).
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var isEditing = false
    @State private var previewStatus: OverlayPreviewStatus = .running
    @State private var dragging: OverlayElement?
    /// A reference (not view state): its bookkeeping must not re-render the editor on every drag update.
    @State private var reorderGuard = OverlayReorderGuard()
    @State private var isAddPresented = false

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            headerRow
            stage
        }
        .onDisappear(perform: endEditing)
        // Every drag (and its end) starts the reorder debounce clean.
        .onChange(of: dragging) { _, _ in reorderGuard.reset() }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: theme.spacingS) {
            if !isEditing {
                Picker("Preview", selection: $previewStatus) {
                    Text("Running").tag(OverlayPreviewStatus.running)
                    Text("Idle").tag(OverlayPreviewStatus.idle)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Preview")
            }
            Spacer(minLength: 0)
            if isEditing {
                Button("Reset Layout") {
                    withAnimation(editAnimation) { settings.resetOverlayLayout() }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(settings.overlayLayout == OverlayElement.defaultLayout)

                Button("Done", action: endEditing)
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Edit") {
                    dragging = nil
                    isEditing = true
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Edit layout")
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        let data = previewData
        let layout = settings.overlayLayout
        let isCompact = settings.overlayCompact

        return VStack(spacing: theme.spacingL) {
            OverlayContent(
                layout: layout,
                data: data,
                isCompact: isCompact,
                mode: isEditing ? .editing : .preview,
                panelOpacity: settings.overlayOpacity
            ) { element, index, view in
                editableElement(element, index: index, view: view, count: layout.count,
                                data: data, isCompact: isCompact)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Overlay preview")

            if isEditing {
                addButton
            }
        }
        .padding(theme.spacingXL)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous).fill(theme.insetSurface))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
            .strokeBorder(theme.separator, lineWidth: 1))
        // A drop anywhere else on the stage just ends the drag.
        .onDrop(of: [.plainText], delegate: OverlayStageDropDelegate(dragging: $dragging))
    }

    private func editableElement(_ element: OverlayElement, index: Int, view: OverlayElementView, count: Int,
                                 data: OverlayDisplayData, isCompact: Bool) -> some View {
        OverlayEditableElement(
            element: element,
            content: view,
            seed: index,
            isEditing: isEditing,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            dragging: $dragging,
            reorderGuard: reorderGuard,
            dragPreview: dragPreview(element, data: data, isCompact: isCompact),
            onMove: { move($0, to: $1) },
            onStep: { step($0, by: $1) },
            onRemove: { remove($0) }
        )
    }

    private var previewData: OverlayDisplayData {
        let label = LiveStartChoice.defaultLabel(in: labels, settings: settings)
        let status: OverlayDisplayData.Status = (isEditing || previewStatus == .running) ? .running : .idle
        return .sample(status: status, label: label, takeaway: engine.lastTakeaway)
    }

    /// The element as it looks on the panel, unrotated, for the drag image. Environment passed explicitly in
    /// case the preview is rendered outside this hierarchy.
    private func dragPreview(_ element: OverlayElement, data: OverlayDisplayData, isCompact: Bool) -> some View {
        let isInline = OverlayBlockPlan.isInline(element, isCompact: isCompact, isIdle: false)
        let width: CGFloat = isCompact ? 220 - 2 * theme.spacingS : 300 - 2 * theme.spacingM
        return OverlayElementView(element: element, data: data, isCompact: isCompact, mode: .editing)
            .frame(width: isInline ? nil : width, alignment: .leading)
            .fixedSize(horizontal: isInline, vertical: true)
            .padding(theme.spacingS)
            .themedPanelBackground(cornerRadius: theme.radiusM)
            .environment(\.theme, theme)
            .environment(engine)
            .environment(router)
            .environment(\.modelContext, modelContext)
    }

    // MARK: Add

    private var hiddenElements: [OverlayElement] {
        OverlayElement.allCases.filter { !settings.overlayLayout.contains($0) }
    }

    private var addButton: some View {
        let allShown = hiddenElements.isEmpty
        return AddBadgeButton(accessibilityLabel: "Add element") {
            isAddPresented = true
        }
        .disabled(allShown)
        .help(allShown ? "All elements shown" : "Add")
        .popover(isPresented: $isAddPresented, arrowEdge: .bottom) {
            addList
                .environment(\.theme, theme)
        }
    }

    private var addList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(hiddenElements) { element in
                Button {
                    add(element)
                } label: {
                    HStack(spacing: theme.spacingS) {
                        Image(systemName: element.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityHidden(true)
                        Text(element.title)
                            .font(theme.bodyFont)
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.spacingS)
                    .padding(.vertical, theme.spacingXS + 1)
                }
                .buttonStyle(LiveHoverRowStyle(hoverOpacity: 0.06))
                .accessibilityLabel("Add \(element.title)")
            }
        }
        .padding(theme.spacingS)
        .frame(width: 220)
    }

    // MARK: Changes (each writes settings.overlayLayout, so the real overlay follows)

    private var editAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    private func add(_ element: OverlayElement) {
        guard !settings.overlayLayout.contains(element) else { return }
        withAnimation(editAnimation) { settings.overlayLayout.append(element) }
        if hiddenElements.isEmpty { isAddPresented = false }
    }

    private func remove(_ element: OverlayElement) {
        if dragging == element { dragging = nil }
        withAnimation(editAnimation) { settings.overlayLayout.removeAll { $0 == element } }
    }

    /// Moves `element` to `target`'s position (after it when moving down, before it when moving up).
    private func move(_ element: OverlayElement, to target: OverlayElement) {
        var layout = settings.overlayLayout
        guard element != target,
              let from = layout.firstIndex(of: element),
              let to = layout.firstIndex(of: target) else { return }
        layout.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(editAnimation) { settings.overlayLayout = layout }
    }

    /// Move Up (-1) / Move Down (+1).
    private func step(_ element: OverlayElement, by offset: Int) {
        var layout = settings.overlayLayout
        guard let from = layout.firstIndex(of: element) else { return }
        let to = from + offset
        guard layout.indices.contains(to) else { return }
        layout.swapAt(from, to)
        withAnimation(editAnimation) { settings.overlayLayout = layout }
    }

    private func endEditing() {
        isEditing = false
        dragging = nil
        isAddPresented = false
    }
}

private enum OverlayPreviewStatus: Hashable {
    case running, idle
}

// MARK: - Editable element

/// Edit-mode chrome around one element: wiggle, (−) badge, drag source + drop target, context menu and
/// accessibility actions. Outside edit mode it is inert (the element ignores hits and there is no hit area).
@MainActor
private struct OverlayEditableElement<DragPreview: View>: View {
    private let element: OverlayElement
    private let content: OverlayElementView
    private let seed: Int
    private let isEditing: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    @Binding private var dragging: OverlayElement?
    private let reorderGuard: OverlayReorderGuard
    private let dragPreview: DragPreview
    private let onMove: (OverlayElement, OverlayElement) -> Void
    private let onStep: (OverlayElement, Int) -> Void
    private let onRemove: (OverlayElement) -> Void

    init(element: OverlayElement, content: OverlayElementView, seed: Int, isEditing: Bool,
         canMoveUp: Bool, canMoveDown: Bool, dragging: Binding<OverlayElement?>,
         reorderGuard: OverlayReorderGuard, dragPreview: DragPreview,
         onMove: @escaping (OverlayElement, OverlayElement) -> Void,
         onStep: @escaping (OverlayElement, Int) -> Void,
         onRemove: @escaping (OverlayElement) -> Void) {
        self.element = element
        self.content = content
        self.seed = seed
        self.isEditing = isEditing
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self._dragging = dragging
        self.reorderGuard = reorderGuard
        self.dragPreview = dragPreview
        self.onMove = onMove
        self.onStep = onStep
        self.onRemove = onRemove
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(element.title)
            .accessibilityActions {
                if isEditing {
                    if canMoveUp {
                        Button("Move Up") { onStep(element, -1) }
                    }
                    if canMoveDown {
                        Button("Move Down") { onStep(element, 1) }
                    }
                    Button("Remove") { onRemove(element) }
                }
            }
            // The element itself ignores hits; this transparent layer is what the drag, the context menu and
            // the drop target hit in edit mode.
            .overlay {
                if isEditing {
                    Color.clear
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
            }
            .wiggle(isEditing, seed: seed)
            .overlay(alignment: .topLeading) {
                if isEditing {
                    RemoveBadgeButton(accessibilityLabel: "Remove \(element.title)") { onRemove(element) }
                        .offset(x: -6, y: -6)
                }
            }
            .onDrag {
                // A drop outside the window gives no callback: every new drag starts clean.
                dragging = element
                return NSItemProvider(object: element.rawValue as NSString)
            } preview: {
                dragPreview
            }
            .onDrop(of: [.plainText],
                    delegate: OverlayReorderDropDelegate(target: element, dragging: $dragging,
                                                         reorderGuard: reorderGuard, move: onMove))
            .contextMenu {
                if isEditing {
                    Button("Move Up") { onStep(element, -1) }
                        .disabled(!canMoveUp)
                    Button("Move Down") { onStep(element, 1) }
                        .disabled(!canMoveDown)
                    Divider()
                    Button("Remove", role: .destructive) { onRemove(element) }
                }
            }
    }
}

/// Debounces live reorder. A move reflows the preview (an element can switch between inline and full width),
/// which can put the pointer over another element, or back over the same one, and move it again (jitter).
/// - Right after a move, entering the same target again is ignored.
/// - Entering a different target during the cooldown is remembered and done on a later `dropUpdated` there,
///   so a fast drag still lands where the pointer rests.
private final class OverlayReorderGuard {
    private static let cooldown: TimeInterval = 0.3

    private var lastDragging: OverlayElement?
    private var lastTarget: OverlayElement?
    private var lastMoveAt: Date = .distantPast
    private var pendingTarget: OverlayElement?

    func reset() {
        lastDragging = nil
        lastTarget = nil
        lastMoveAt = .distantPast
        pendingTarget = nil
    }

    /// The pointer entered `target`: whether to move `dragging` there now.
    func shouldMoveOnEnter(_ dragging: OverlayElement, onto target: OverlayElement, now: Date = Date()) -> Bool {
        pendingTarget = nil
        guard now.timeIntervalSince(lastMoveAt) < Self.cooldown else {
            record(dragging, target, now)
            return true
        }
        if lastDragging != dragging || lastTarget != target {
            pendingTarget = target
        }
        return false
    }

    /// The pointer is still over `target`: whether a move deferred by the cooldown is due now.
    func shouldMoveOnUpdate(_ dragging: OverlayElement, onto target: OverlayElement, now: Date = Date()) -> Bool {
        guard pendingTarget == target, now.timeIntervalSince(lastMoveAt) >= Self.cooldown else { return false }
        pendingTarget = nil
        record(dragging, target, now)
        return true
    }

    func exited(_ target: OverlayElement) {
        if pendingTarget == target { pendingTarget = nil }
    }

    private func record(_ dragging: OverlayElement, _ target: OverlayElement, _ now: Date) {
        lastDragging = dragging
        lastTarget = target
        lastMoveAt = now
    }
}

/// Live reorder: entering another element moves the dragged one to its position (debounced by
/// `OverlayReorderGuard`).
private struct OverlayReorderDropDelegate: DropDelegate {
    private let target: OverlayElement
    @Binding private var dragging: OverlayElement?
    private let reorderGuard: OverlayReorderGuard
    private let move: (OverlayElement, OverlayElement) -> Void

    init(target: OverlayElement, dragging: Binding<OverlayElement?>, reorderGuard: OverlayReorderGuard,
         move: @escaping (OverlayElement, OverlayElement) -> Void) {
        self.target = target
        self._dragging = dragging
        self.reorderGuard = reorderGuard
        self.move = move
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        if reorderGuard.shouldMoveOnEnter(dragging, onto: target) {
            move(dragging, target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let dragging, dragging != target, reorderGuard.shouldMoveOnUpdate(dragging, onto: target) {
            move(dragging, target)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        reorderGuard.exited(target)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The stage around the preview: a drop there ends the drag (only drags that started in the editor count).
private struct OverlayStageDropDelegate: DropDelegate {
    @Binding private var dragging: OverlayElement?

    init(dragging: Binding<OverlayElement?>) {
        self._dragging = dragging
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
