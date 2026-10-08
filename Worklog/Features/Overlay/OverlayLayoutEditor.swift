import AppKit
import SwiftData
import SwiftUI

/// Settings ▸ Overlay ▸ Layout: a real-size preview of the overlay (current theme, compact setting and opacity)
/// with an edit mode in the spirit of iPhone Control Center, on the overlay's 6-column grid
/// (`OverlayGridLayout`):
/// - elements show their cell's extent, wiggle (a dashed outline under Reduce Motion) and carry a small
///   top-trailing (−) badge, always the topmost (clickable) layer
/// - drag an element anywhere: a floating copy follows the pointer, a dashed ghost shows the cell it snaps to and
///   the elements it would push down are dimmed. Dropping on occupied columns pushes those elements into a new
///   row below; dropping under the last row creates a row; releasing far outside the panel cancels
/// - drag the bottom-trailing handle to resize in column steps (clamped to `minSpan` and the right neighbour)
/// - (+) adds a hidden element to the first free cell
/// - keyboard (focused element): arrows move, ⇧← / ⇧→ narrower / wider, ⌫ / ⌦ remove
/// - context menu and accessibility actions: Move Left / Right / Up / Down, Wider, Narrower, Remove
///
/// Every change writes `settings.overlayGrid` immediately, so the real overlay follows live.
/// Preview and edit mode never touch the engine (`OverlayContent` ignores hits outside `.live`).
@MainActor
struct OverlayLayoutEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sample's label is the quick start profile's default label (no fetch in `body`).
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]

    @State private var isEditing = false
    @State private var previewStatus: OverlayPreviewStatus = .running
    @State private var isAddPresented = false
    /// The drag in progress (move or resize), nil otherwise.
    @State private var drag: OverlayGridDragState?
    /// Row frames in the "overlayGrid" space, reported by `OverlayContent` in edit mode.
    @State private var rowFrames: [Int: CGRect] = [:]
    /// The preview panel's size (its bounds in the "overlayGrid" space), for the cancel rule.
    @State private var panelSize: CGSize = .zero
    @FocusState private var focusedElement: OverlayElement?

    /// A drop whose floating copy's centre is further than this outside the panel cancels.
    private static let cancelDistance: CGFloat = 40

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            headerRow
            stage
            if isEditing {
                SettingsFootnote("Drag to move; drag the right edge to resize.")
            }
        }
        .onDisappear(perform: endEditing)
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
                    drag = nil
                    withAnimation(editAnimation) { settings.resetOverlayLayout() }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(settings.overlayGrid == OverlayGridLayout.defaultLayout)

                Button("Done", action: endEditing)
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Edit") {
                    drag = nil
                    isEditing = true
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Edit layout")
            }
        }
    }

    // MARK: Stage

    private var geometry: OverlayGridGeometry {
        OverlayGridGeometry(rowFrames: rowFrames, gutter: theme.spacingXS)
    }

    private var stage: some View {
        let data = previewData
        let grid = settings.overlayGrid
        let isCompact = settings.overlayCompact
        let order = grid.readingOrder
        let preview = dragPreview(grid: grid, geometry: geometry)
        let editingOptions = OverlayEditingOptions(
            trailingDropRowHeight: drag?.mode == .move ? drag?.start.height : nil,
            reportsFrames: isEditing
        )

        return VStack(spacing: theme.spacingL) {
            OverlayContent(
                grid: grid,
                data: data,
                isCompact: isCompact,
                mode: isEditing ? .editing : .preview,
                panelOpacity: settings.overlayOpacity,
                editing: editingOptions
            ) { placement, view in
                editableElement(placement, view: view, grid: grid,
                                seed: order.firstIndex(of: placement.element) ?? 0,
                                isDimmed: preview?.displaced.contains(placement.element) ?? false)
            }
            .background {
                if isEditing {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { panelSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in panelSize = size }
                    }
                }
            }
            .coordinateSpace(name: OverlayGridSpace.name)
            .overlay(alignment: .topLeading) {
                dragLayer(preview, data: data, isCompact: isCompact)
            }
            .onPreferenceChange(OverlayGridRowFramesKey.self) { frames in
                MainActor.assumeIsolated {
                    if rowFrames != frames { rowFrames = frames }
                }
            }
            .allowsHitTesting(isEditing)
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
    }

    private func editableElement(_ placement: OverlayPlacement, view: OverlayElementView, grid: OverlayGridLayout,
                                 seed: Int, isDimmed: Bool) -> some View {
        let element = placement.element
        let isDragged = drag?.element == element
        return OverlayEditableElement(
            placement: placement,
            content: view,
            seed: seed,
            isEditing: isEditing,
            isDragged: isDragged,
            isDimmed: isDimmed && !isDragged,
            directions: OverlayGridDirection.allCases.filter { grid.canNudge(element, $0) },
            canWiden: grid.canResize(element, by: 1),
            canNarrow: grid.canResize(element, by: -1),
            focus: $focusedElement,
            onNudge: { nudge(element, $0) },
            onResize: { resize(element, by: $0) },
            onRemove: { remove(element) },
            dragDidChange: { dragChanged(element, mode: $0, translation: $1) },
            dragDidEnd: { dragEnded(element, mode: $0, translation: $1) },
            dragWasCancelled: { dragCancelled(element, mode: $0) }
        )
    }

    /// Sample timer values, with the profile the real overlay starts in (the quick start profile, which is the
    /// current profile unless Settings ▸ Profiles names another): its default label, takeaway and header tag.
    private var previewData: OverlayDisplayData {
        let profile = profiles.quickStartProfile
        let label = LiveStartChoice.defaultLabel(in: labels, profile: profile, settings: settings)
        let status: OverlayDisplayData.Status = (isEditing || previewStatus == .running) ? .running : .idle
        let fields = OverlayDisplayData.profileFields(profile, showsProfile: profiles.hasMultipleProfiles)
        return .sample(status: status, label: label, takeaway: engine.takeaway(for: profiles.quickStartProfileID),
                       profileName: fields.name, profileColorHex: fields.colorHex)
    }

    // MARK: Drag layer (never animated, never hit)

    /// The snap ghost (accent dashed outline + faint fill) and, while moving, the floating copy that follows the
    /// pointer (unrotated, no shadow). Drawn over the panel in the same coordinate space as the row frames.
    @ViewBuilder
    private func dragLayer(_ preview: OverlayGridDragPreview?, data: OverlayDisplayData, isCompact: Bool) -> some View {
        if let preview {
            ZStack(alignment: .topLeading) {
                if let ghost = preview.ghost {
                    RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                        .fill(theme.accent.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: max(0, ghost.width), height: max(0, ghost.height))
                        .offset(x: ghost.minX, y: ghost.minY)
                }
                if let floating = preview.floating {
                    let placement = preview.placement
                    OverlayElementView(element: placement.element, data: data, isCompact: isCompact,
                                       mode: .editing,
                                       alignment: placement.element.overlayCellAlignment(
                                           column: placement.column, span: placement.span,
                                           isActive: data.isActive))
                        .frame(width: max(0, floating.width), height: max(0, floating.height))
                        .background(RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                            .fill(theme.elevatedSurface))
                        .overlay(RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                            .strokeBorder(theme.accent, lineWidth: 1))
                        .opacity(0.9)
                        .offset(x: floating.minX, y: floating.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transaction { $0.animation = nil }
        }
    }

    /// What the drag layer draws for the current drag (nil when there is none).
    private func dragPreview(grid: OverlayGridLayout, geometry: OverlayGridGeometry) -> OverlayGridDragPreview? {
        guard let drag, let placement = grid.placement(of: drag.element) else { return nil }
        switch drag.mode {
        case .move:
            let floating = drag.currentFrame
            guard !isFarOutside(floating), let target = moveTarget(drag, geometry: geometry) else {
                // Released here, the drop cancels: no ghost, nothing pushed.
                return OverlayGridDragPreview(placement: placement, ghost: nil, floating: floating, displaced: [])
            }
            return OverlayGridDragPreview(
                placement: placement,
                ghost: geometry.cellFrame(row: target.row, column: target.column, span: placement.span),
                floating: floating,
                displaced: grid.displaced(byMoving: drag.element, toRow: target.row, column: target.column)
            )
        case .resize:
            let span = resizedGrid(drag, placement: placement, grid: grid, geometry: geometry)
                .placement(of: drag.element)?.span ?? placement.span
            return OverlayGridDragPreview(
                placement: placement,
                ghost: geometry.cellFrame(row: placement.row, column: placement.column, span: span),
                floating: nil,
                displaced: []
            )
        }
    }

    /// The cell under the floating copy: its vertical centre picks the row, its leading edge the column.
    private func moveTarget(_ drag: OverlayGridDragState, geometry: OverlayGridGeometry) -> (row: Int, column: Int)? {
        let frame = drag.currentFrame
        guard let row = geometry.snappedRow(midY: frame.midY) else { return nil }
        let column = geometry.snappedColumn(leadingX: frame.minX, row: row, span: drag.span)
        return (row, column)
    }

    /// The grid with `drag`'s element resized to the span under its dragged trailing edge (clamped by the model).
    private func resizedGrid(_ drag: OverlayGridDragState, placement: OverlayPlacement, grid: OverlayGridLayout,
                             geometry: OverlayGridGeometry) -> OverlayGridLayout {
        let span = geometry.snappedSpan(trailingX: drag.start.maxX + drag.translation.width,
                                        row: placement.row, column: placement.column)
        return grid.resizing(drag.element, toSpan: span)
    }

    /// The floating copy's centre is more than `cancelDistance` outside the panel.
    private func isFarOutside(_ frame: CGRect) -> Bool {
        guard panelSize.width > 0, panelSize.height > 0 else { return false }
        let limit = CGRect(origin: .zero, size: panelSize)
            .insetBy(dx: -Self.cancelDistance, dy: -Self.cancelDistance)
        return !limit.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    // MARK: Drag handling

    private func dragChanged(_ element: OverlayElement, mode: OverlayGridDragMode, translation: CGSize) {
        guard isEditing else { return }
        if var current = drag, current.element == element, current.mode == mode {
            current.translation = translation
            drag = current
        } else {
            drag = startedDrag(element, mode: mode, translation: translation)
        }
        if mode == .resize {
            // The pointer leaves the handle while dragging; keep the resize cursor.
            NSCursor.resizeLeftRight.set()
        }
    }

    private func dragEnded(_ element: OverlayElement, mode: OverlayGridDragMode, translation: CGSize) {
        var state = drag
        if state?.element != element || state?.mode != mode {
            state = startedDrag(element, mode: mode, translation: translation)
        }
        state?.translation = translation
        drag = nil
        guard isEditing, let state else { return }

        let grid = settings.overlayGrid
        switch mode {
        case .move:
            guard !isFarOutside(state.currentFrame),
                  let target = moveTarget(state, geometry: geometry) else { return }   // cancelled: snaps back
            apply(grid.moving(element, toRow: target.row, column: target.column))
        case .resize:
            guard let placement = grid.placement(of: element) else { return }
            apply(resizedGrid(state, placement: placement, grid: grid, geometry: geometry))
        }
    }

    /// The gesture ended without `onEnded` (e.g. the view went away): just forget the drag.
    private func dragCancelled(_ element: OverlayElement, mode: OverlayGridDragMode) {
        if drag?.element == element, drag?.mode == mode {
            drag = nil
        }
    }

    /// The element's cell frame at the start of a drag (from the reported row frames).
    private func startedDrag(_ element: OverlayElement, mode: OverlayGridDragMode,
                             translation: CGSize) -> OverlayGridDragState? {
        guard let placement = settings.overlayGrid.placement(of: element),
              let frame = geometry.cellFrame(row: placement.row, column: placement.column, span: placement.span)
        else { return nil }
        return OverlayGridDragState(element: element, mode: mode, start: frame, span: placement.span,
                                    translation: translation)
    }

    // MARK: Add

    private var addButton: some View {
        let allShown = settings.overlayGrid.hiddenElements.isEmpty
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
            ForEach(settings.overlayGrid.hiddenElements) { element in
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

    // MARK: Changes (each writes settings.overlayGrid, so the real overlay follows)

    private var editAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    private func apply(_ grid: OverlayGridLayout) {
        guard grid != settings.overlayGrid else { return }
        withAnimation(editAnimation) { settings.overlayGrid = grid }
    }

    private func add(_ element: OverlayElement) {
        apply(settings.overlayGrid.adding(element))
        if settings.overlayGrid.hiddenElements.isEmpty { isAddPresented = false }
    }

    private func remove(_ element: OverlayElement) {
        if drag?.element == element { drag = nil }
        apply(settings.overlayGrid.removing(element))
    }

    private func nudge(_ element: OverlayElement, _ direction: OverlayGridDirection) {
        apply(settings.overlayGrid.nudged(element, direction))
        keepFocus(on: element)
    }

    /// Wider (+1) / Narrower (−1).
    private func resize(_ element: OverlayElement, by delta: Int) {
        guard let placement = settings.overlayGrid.placement(of: element) else { return }
        apply(settings.overlayGrid.resizing(element, toSpan: placement.span + delta))
        keepFocus(on: element)
    }

    /// A move to another row rebuilds the element's view; give keyboard focus back once it exists.
    private func keepFocus(on element: OverlayElement) {
        guard focusedElement == element else { return }
        Task { @MainActor in focusedElement = element }
    }

    private func endEditing() {
        isEditing = false
        drag = nil
        isAddPresented = false
        focusedElement = nil
    }
}

private enum OverlayPreviewStatus: Hashable {
    case running, idle
}

// MARK: - Drag state

private enum OverlayGridDragMode: Equatable {
    case move, resize
}

/// One drag: the element, its cell frame when the drag started (in the "overlayGrid" space) and the translation.
private struct OverlayGridDragState: Equatable {
    let element: OverlayElement
    let mode: OverlayGridDragMode
    let start: CGRect
    let span: Int
    var translation: CGSize

    /// Where the floating copy is now.
    var currentFrame: CGRect {
        start.offsetBy(dx: translation.width, dy: translation.height)
    }
}

/// What the drag layer draws.
private struct OverlayGridDragPreview {
    /// The dragged element's placement (before the drop).
    let placement: OverlayPlacement
    /// The snap target (move) or the clamped resized cell (resize); nil when a release would cancel.
    let ghost: CGRect?
    /// The floating copy (move only).
    let floating: CGRect?
    /// Elements the drop would push down (dimmed).
    let displaced: Set<OverlayElement>
}

// MARK: - Editable element

/// Edit-mode chrome around one element: cell extent, wiggle, move drag, resize handle, (−) badge (topmost),
/// keyboard, context menu and accessibility actions. Outside edit mode it is inert (the element ignores hits and there is no hit area).
@MainActor
private struct OverlayEditableElement: View {
    @Environment(\.theme) private var theme

    private let placement: OverlayPlacement
    private let content: OverlayElementView
    private let seed: Int
    private let isEditing: Bool
    private let isDragged: Bool
    private let isDimmed: Bool
    private let directions: [OverlayGridDirection]
    private let canWiden: Bool
    private let canNarrow: Bool
    private let focus: FocusState<OverlayElement?>.Binding
    private let onNudge: (OverlayGridDirection) -> Void
    private let onResize: (Int) -> Void
    private let onRemove: () -> Void
    private let dragDidChange: (OverlayGridDragMode, CGSize) -> Void
    private let dragDidEnd: (OverlayGridDragMode, CGSize) -> Void
    private let dragWasCancelled: (OverlayGridDragMode) -> Void

    @GestureState private var isMoving = false
    @GestureState private var isResizing = false

    init(placement: OverlayPlacement, content: OverlayElementView, seed: Int, isEditing: Bool, isDragged: Bool,
         isDimmed: Bool, directions: [OverlayGridDirection], canWiden: Bool, canNarrow: Bool,
         focus: FocusState<OverlayElement?>.Binding,
         onNudge: @escaping (OverlayGridDirection) -> Void,
         onResize: @escaping (Int) -> Void,
         onRemove: @escaping () -> Void,
         dragDidChange: @escaping (OverlayGridDragMode, CGSize) -> Void,
         dragDidEnd: @escaping (OverlayGridDragMode, CGSize) -> Void,
         dragWasCancelled: @escaping (OverlayGridDragMode) -> Void) {
        self.placement = placement
        self.content = content
        self.seed = seed
        self.isEditing = isEditing
        self.isDragged = isDragged
        self.isDimmed = isDimmed
        self.directions = directions
        self.canWiden = canWiden
        self.canNarrow = canNarrow
        self.focus = focus
        self.onNudge = onNudge
        self.onResize = onResize
        self.onRemove = onRemove
        self.dragDidChange = dragDidChange
        self.dragDidEnd = dragDidEnd
        self.dragWasCancelled = dragWasCancelled
    }

    private var element: OverlayElement { placement.element }
    private var isFocused: Bool { focus.wrappedValue == element }

    var body: some View {
        editChrome
            .focusable(isEditing)
            .focusEffectDisabled()
            .focused(focus, equals: element)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .delete, .deleteForward]) { press in
                handleKey(press)
            }
            .contextMenu { contextMenuItems }
            .onChange(of: isMoving) { _, active in
                if !active { dragWasCancelled(.move) }
            }
            .onChange(of: isResizing) { _, active in
                if !active { dragWasCancelled(.resize) }
            }
    }

    /// The element with its cell extent, hit layer, focus ring and wiggle, then the move gesture, the resize
    /// handle and, last (the topmost layer, so it is always clickable), the (−) badge.
    private var editChrome: some View {
        let dim: Double = isDragged ? 0.35 : (isDimmed ? 0.5 : 1)
        return content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(element.title)
            .accessibilityValue(OverlayGridCopy.position(placement))
            .accessibilityActions { accessibilityActionItems }
            .background { cellExtent }
            .overlay { hitLayer }
            .wiggle(isEditing && !isDragged, seed: seed)
            .opacity(dim)
            .contentShape(Rectangle())
            .gesture(moveGesture, including: isEditing ? .all : .none)
            .editResizeHandle(isEditing, gesture: resizeGesture)
            .editRemoveBadge(isEditing, accessibilityLabel: "Remove \(element.title)", action: onRemove)
    }

    /// Edit mode: the cell's extent (faint fill + separator stroke, 2 pt outside the element), so the badge and the
    /// handle sit on visible cell corners. It wiggles with the element.
    @ViewBuilder
    private var cellExtent: some View {
        if isEditing {
            let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
            shape
                .fill(theme.textPrimary.opacity(0.05))
                .overlay(shape.strokeBorder(theme.separator, lineWidth: 1))
                .padding(-2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The element itself ignores hits; this transparent layer is what the drag and the context menu hit in edit
    /// mode. The focus ring wiggles with the element.
    @ViewBuilder
    private var hitLayer: some View {
        if isEditing {
            Color.clear
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            if isFocused {
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var accessibilityActionItems: some View {
        if isEditing {
            ForEach(directions, id: \.self) { direction in
                Button(direction.title) { onNudge(direction) }
            }
            if canWiden {
                Button("Wider") { onResize(1) }
            }
            if canNarrow {
                Button("Narrower") { onResize(-1) }
            }
            Button("Remove", action: onRemove)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isEditing {
            ForEach(OverlayGridDirection.allCases, id: \.self) { direction in
                Button(direction.title) { onNudge(direction) }
                    .disabled(!directions.contains(direction))
            }
            Divider()
            Button("Wider") { onResize(1) }
                .disabled(!canWiden)
            Button("Narrower") { onResize(-1) }
                .disabled(!canNarrow)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    // MARK: Gestures (in the "overlayGrid" space, like the row frames and the drag layer)

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: OverlayGridSpace.coordinateSpace)
            .updating($isMoving) { _, state, _ in state = true }
            .onChanged { value in dragDidChange(.move, value.translation) }
            .onEnded { value in dragDidEnd(.move, value.translation) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: OverlayGridSpace.coordinateSpace)
            .updating($isResizing) { _, state, _ in state = true }
            .onChanged { value in dragDidChange(.resize, value.translation) }
            .onEnded { value in dragDidEnd(.resize, value.translation) }
    }

    // MARK: Keyboard

    /// ←/→/↑/↓ move, ⇧← narrower, ⇧→ wider, ⌫/⌦ remove.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard isEditing else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        let key = press.key
        if key == .leftArrow {
            if shift { onResize(-1) } else { onNudge(.left) }
        } else if key == .rightArrow {
            if shift { onResize(1) } else { onNudge(.right) }
        } else if key == .upArrow {
            onNudge(.up)
        } else if key == .downArrow {
            onNudge(.down)
        } else if key == .delete || key == .deleteForward {
            onRemove()
        } else {
            return .ignored
        }
        return .handled
    }
}
