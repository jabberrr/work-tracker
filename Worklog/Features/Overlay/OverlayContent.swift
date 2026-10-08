import AppKit
import SwiftUI

// The floating overlay's renderer, shared by the live panel (`OverlayView`) and the layout editor in
// Settings ▸ Overlay (`OverlayLayoutEditor`), so both always look the same.
//
// Model: `settings.overlayLayout` is an ordered list of `OverlayElement`s. The header (status dot, leading
// content, close button) is chrome, not an element. Consecutive *inline* elements share one wrapping row;
// the others take the full width.

/// Where the overlay content is rendered.
enum OverlayMode {
    /// The real floating panel: controls act on the engine.
    case live
    /// Settings preview: sample data, nothing is interactive.
    case preview
    /// Settings edit mode: like `.preview`, always the running sample with every layout element visible.
    case editing
}

/// Everything the overlay shows, decoupled from `SessionEngine` so the Settings preview can use sample data.
struct OverlayDisplayData {
    enum Status {
        case idle, running, paused
    }

    var status: Status
    var label: WorkLabel?
    var elapsed: TimeInterval
    var segmentElapsed: TimeInterval
    var todayTotal: TimeInterval
    /// The current segment's focus (may be empty; the view falls back to the label name).
    var focus: String
    var takeaway: SessionTakeaway?
    /// The label the idle Start button uses.
    var startLabel: WorkLabel?
    var hasPendingReview: Bool
    var isOnAnotherMac: Bool

    var isActive: Bool { status != .idle }
    var isPaused: Bool { status == .paused }

    /// Preview data: 1:12:40 elapsed, segment 24:10, focus "Refactor parser", today 2h 15m.
    /// `takeaway` nil uses a sample takeaway, so the preview always shows that element.
    static func sample(status: Status, label: WorkLabel?, takeaway: SessionTakeaway?) -> OverlayDisplayData {
        OverlayDisplayData(
            status: status,
            label: status == .idle ? nil : label,
            elapsed: 1 * 3600 + 12 * 60 + 40,
            segmentElapsed: 24 * 60 + 10,
            todayTotal: 2 * 3600 + 15 * 60,
            focus: "Refactor parser",
            takeaway: takeaway ?? sampleTakeaway,
            startLabel: label,
            hasPendingReview: false,
            isOnAnotherMac: false
        )
    }

    static var sampleTakeaway: SessionTakeaway {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return SessionTakeaway(sessionUUID: UUID(), title: "Code review sweep", date: yesterday,
                               text: "Batch review comments before replying.", labelName: nil)
    }
}

/// Live-mode callbacks. Preview and editing use `.none` (and hit testing is off there anyway).
struct OverlayActions {
    var hide: () -> Void = {}
    var togglePause: () -> Void = {}
    var toggleSplit: () -> Void = {}
    var endSplit: () -> Void = {}
    var stop: () -> Void = {}
    var start: () -> Void = {}
    var review: () -> Void = {}

    static var none: OverlayActions { OverlayActions() }
}

// MARK: - Content

/// Renders `layout` in order with `data`. 300 pt wide (220 compact); height is intrinsic.
///
/// `chrome` wraps every rendered element (the editor adds the wiggle, remove badge, drag and drop and the
/// context menu there); the header's dot, status and close button are never passed through it.
/// `panelOpacity` fades the panel (background and content) without fading the chrome the editor adds.
@MainActor
struct OverlayContent<ElementChrome: View>: View {
    @Environment(\.theme) private var theme

    private let layout: [OverlayElement]
    private let data: OverlayDisplayData
    private let isCompact: Bool
    private let mode: OverlayMode
    private let panelOpacity: Double
    private let isSplitting: Bool
    private let noteFocus: FocusState<Bool>.Binding?
    private let actions: OverlayActions
    private let chrome: (OverlayElement, Int, OverlayElementView) -> ElementChrome

    init(layout: [OverlayElement], data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         panelOpacity: Double = 1, isSplitting: Bool = false, noteFocus: FocusState<Bool>.Binding? = nil,
         actions: OverlayActions = .none,
         @ViewBuilder chrome: @escaping (OverlayElement, Int, OverlayElementView) -> ElementChrome) {
        self.layout = layout
        self.data = data
        self.isCompact = isCompact
        self.mode = mode
        self.panelOpacity = panelOpacity
        self.isSplitting = isSplitting
        self.noteFocus = noteFocus
        self.actions = actions
        self.chrome = chrome
    }

    private var isLive: Bool { mode == .live }

    var body: some View {
        let plan = OverlayBlockPlan(layout: layout, data: data, isCompact: isCompact, mode: mode)

        VStack(alignment: .leading, spacing: isCompact ? theme.spacingXS + 2 : theme.spacingS) {
            header(run: plan.headerRun)

            if isLive && data.isActive && data.isOnAnotherMac {
                LiveOtherMacHint()
            }

            if showsSplitForm(after: plan.headerRun) {
                splitForm
            }

            ForEach(plan.blocks) { block in
                blockView(block)
                if showsSplitForm(after: block.items) {
                    splitForm
                }
            }

            if plan.needsStandaloneReview {
                standaloneReview
            }
        }
        .padding(isCompact ? theme.spacingS : theme.spacingM)
        .frame(width: isCompact ? 220 : 300, alignment: .leading)
        .modifier(OverlayPanelSurface(isLive: isLive, opacity: panelOpacity))
    }

    // MARK: Header

    private func header(run: [OverlayBlockItem]) -> some View {
        HStack(spacing: isCompact ? theme.spacingXS : theme.spacingS) {
            Group {
                if data.isActive {
                    LiveDot(isPaused: data.isPaused, size: isCompact ? 7 : 8)
                } else {
                    Image(systemName: "timer")
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .opacity(panelOpacity)

            if run.isEmpty {
                statusText
                    .opacity(panelOpacity)
                Spacer(minLength: theme.spacingXS)
            } else {
                inlineRun(run)
            }

            closeButton
                .opacity(panelOpacity)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if data.isActive {
            Text(data.isPaused ? "Paused" : "Running")
                .font(theme.captionFont.weight(.medium))
                .foregroundStyle(theme.textSecondary)
        } else {
            Text("Not tracking")
                .font(isCompact ? theme.calloutFont.weight(.medium) : theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
        }
    }

    private var closeButton: some View {
        Button(action: actions.hide) {
            Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle(size: 18))
        .foregroundStyle(theme.textTertiary)
        .accessibilityLabel("Hide overlay")
        .help("Hide overlay")
        .allowsHitTesting(isLive)
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: OverlayBlock) -> some View {
        if block.isInline {
            HStack(spacing: theme.spacingXS) {
                inlineRun(block.items)
            }
        } else if let item = block.items.first {
            element(item)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A wrapping row of inline elements; Today's total sits trailing when it ends the row.
    @ViewBuilder
    private func inlineRun(_ items: [OverlayBlockItem]) -> some View {
        if let last = items.last, last.element == .todayTotal {
            let leading = Array(items.dropLast())
            if !leading.isEmpty {
                flow(leading)
            }
            Spacer(minLength: theme.spacingXS)
            element(last)
        } else {
            flow(items)
            Spacer(minLength: theme.spacingXS)
        }
    }

    private func flow(_ items: [OverlayBlockItem]) -> some View {
        FlowLayout(spacing: theme.spacingXS, lineSpacing: theme.spacingXS) {
            ForEach(items) { item in
                element(item)
            }
        }
        .layoutPriority(1)
    }

    private func element(_ item: OverlayBlockItem) -> some View {
        chrome(item.element, item.index, elementView(item.element))
    }

    private func elementView(_ element: OverlayElement) -> OverlayElementView {
        OverlayElementView(element: element, data: data, isCompact: isCompact, mode: mode,
                           opacity: panelOpacity, noteFocus: noteFocus, actions: actions)
    }

    // MARK: Split form (live only)

    private func showsSplitForm(after items: [OverlayBlockItem]) -> Bool {
        isLive && isSplitting && data.isActive && items.contains { $0.element == .split }
    }

    private var splitForm: some View {
        LiveSegmentForm(mode: .split, style: isCompact ? .inlineCompact : .inline, onFinish: actions.endSplit)
            .padding(isCompact ? theme.spacingS : theme.spacingM)
            .background(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                .fill(theme.textPrimary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1))
    }

    /// Idle with a pending review but no Controls element: the review must stay reachable.
    private var standaloneReview: some View {
        HStack {
            Button("Review…", action: actions.review)
                .buttonStyle(QuietButtonStyle())
                .help("Review session")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}

extension OverlayContent where ElementChrome == OverlayElementView {
    /// No per-element chrome (the live panel and the plain preview).
    init(layout: [OverlayElement], data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         panelOpacity: Double = 1, isSplitting: Bool = false, noteFocus: FocusState<Bool>.Binding? = nil,
         actions: OverlayActions = .none) {
        self.init(layout: layout, data: data, isCompact: isCompact, mode: mode, panelOpacity: panelOpacity,
                  isSplitting: isSplitting, noteFocus: noteFocus, actions: actions,
                  chrome: { _, _, view in view })
    }
}

/// Live: the panel background as-is (the panel's alphaValue applies the opacity).
/// Preview/editing: the same background faded by `opacity` behind the content, unclipped so the editor's
/// badges can overhang an element's corner.
private struct OverlayPanelSurface: ViewModifier {
    private let isLive: Bool
    private let opacity: Double
    @Environment(\.theme) private var theme

    init(isLive: Bool, opacity: Double) {
        self.isLive = isLive
        self.opacity = opacity
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLive {
            content.themedPanelBackground(cornerRadius: theme.radiusL)
        } else {
            content.background {
                Color.clear
                    .themedPanelBackground(cornerRadius: theme.radiusL)
                    .opacity(opacity)
            }
        }
    }
}

// MARK: - Block plan

/// One rendered element and its index in the layout (stable across modes; the editor uses it for seeds and moves).
struct OverlayBlockItem: Identifiable, Hashable {
    let element: OverlayElement
    let index: Int
    var id: OverlayElement { element }
}

/// A run of inline elements (one wrapping row) or one full-width element.
struct OverlayBlock: Identifiable {
    let isInline: Bool
    let items: [OverlayBlockItem]
    var id: String { (isInline ? "row." : "full.") + (items.first?.element.rawValue ?? "") }
}

/// Decides which elements render and how they group, for one mode/status.
struct OverlayBlockPlan {
    /// Inline elements that open the layout render in the header (active only).
    private(set) var headerRun: [OverlayBlockItem] = []
    private(set) var blocks: [OverlayBlock] = []
    /// Idle + pending review + no Controls element (live only).
    private(set) var needsStandaloneReview = false

    init(layout: [OverlayElement], data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode) {
        let isIdle = mode != .editing && !data.isActive
        var visible: [OverlayBlockItem] = []
        for (index, element) in layout.enumerated()
        where Self.isVisible(element, data: data, isIdle: isIdle, mode: mode) {
            visible.append(OverlayBlockItem(element: element, index: index))
        }

        var blocks: [OverlayBlock] = []
        var run: [OverlayBlockItem] = []
        for item in visible {
            if Self.isInline(item.element, isCompact: isCompact, isIdle: isIdle) {
                run.append(item)
            } else {
                if !run.isEmpty {
                    blocks.append(OverlayBlock(isInline: true, items: run))
                    run = []
                }
                blocks.append(OverlayBlock(isInline: false, items: [item]))
            }
        }
        if !run.isEmpty {
            blocks.append(OverlayBlock(isInline: true, items: run))
        }

        // The header always says "Not tracking" while idle; while active, a leading inline run replaces the status word.
        if !isIdle, let first = blocks.first, first.isInline {
            headerRun = first.items
            blocks.removeFirst()
        }
        self.blocks = blocks
        needsStandaloneReview = mode == .live && isIdle && data.hasPendingReview && !layout.contains(.controls)
    }

    private static func isVisible(_ element: OverlayElement, data: OverlayDisplayData, isIdle: Bool,
                                  mode: OverlayMode) -> Bool {
        if element == .takeaway && data.takeaway == nil { return false }
        guard isIdle else { return true }
        switch element {
        case .takeaway, .todayTotal, .controls: return true
        case .label, .timer, .segmentFocus, .split, .note: return false
        }
    }

    /// Inline elements share a wrapping row; the others take the full width.
    static func isInline(_ element: OverlayElement, isCompact: Bool, isIdle: Bool) -> Bool {
        switch element {
        case .label, .split, .todayTotal: return true
        case .controls: return !isIdle          // idle: "Review…" + Start take the full row
        case .timer: return isCompact
        case .segmentFocus, .note, .takeaway: return false
        }
    }
}

// MARK: - Element view

/// One element's content in any mode. Outside `.live` it ignores hits, so nothing reaches the engine.
@MainActor
struct OverlayElementView: View {
    @Environment(\.theme) private var theme

    private let element: OverlayElement
    private let data: OverlayDisplayData
    private let isCompact: Bool
    private let mode: OverlayMode
    private let opacity: Double
    private let noteFocus: FocusState<Bool>.Binding?
    private let actions: OverlayActions

    init(element: OverlayElement, data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         opacity: Double = 1, noteFocus: FocusState<Bool>.Binding? = nil, actions: OverlayActions = .none) {
        self.element = element
        self.data = data
        self.isCompact = isCompact
        self.mode = mode
        self.opacity = opacity
        self.noteFocus = noteFocus
        self.actions = actions
    }

    private var isLive: Bool { mode == .live }
    private var iconSize: CGFloat { isCompact ? 22 : 26 }

    var body: some View {
        content
            .opacity(opacity)
            .allowsHitTesting(isLive)
    }

    @ViewBuilder
    private var content: some View {
        switch element {
        case .label:
            LabelBadge(label: data.label, size: .small)
        case .timer:
            TimerText(data.elapsed, style: isCompact ? .compact : .large, isPaused: data.isPaused)
        case .segmentFocus:
            segmentFocus
        case .controls:
            if data.isActive {
                activeControls
            } else {
                idleControls
            }
        case .split:
            iconButton("scissors", title: "Split segment", action: actions.toggleSplit)
        case .todayTotal:
            todayTotal
        case .note:
            note
        case .takeaway:
            if let takeaway = data.takeaway {
                LiveTakeawayView(takeaway: takeaway,
                                 lineLimit: data.isActive ? (isCompact ? 1 : 2) : (isCompact ? 2 : 4),
                                 showsTitle: !data.isActive && !isCompact,
                                 isCompact: true,
                                 showsDone: isLive)
            }
        }
    }

    // MARK: Pieces

    private var focusText: String {
        let focus = data.focus.trimmed
        if !focus.isEmpty { return focus }
        return data.label?.name ?? "No focus"
    }

    private var segmentFocus: some View {
        HStack(spacing: theme.spacingXS) {
            Text(focusText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· seg \(data.segmentElapsed.formattedClock)")
                .monospacedDigit()
                .fixedSize()
        }
        .font(isCompact ? theme.captionFont : theme.calloutFont)
        .foregroundStyle(theme.textSecondary)
        .help(focusText)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var activeControls: some View {
        HStack(spacing: theme.spacingXS) {
            iconButton(data.isPaused ? "play.fill" : "pause.fill",
                       title: data.isPaused ? "Resume" : "Pause",
                       action: actions.togglePause)
            iconButton("stop.fill", title: "Stop", spokenTitle: "Stop session", action: actions.stop)
        }
    }

    private var idleControls: some View {
        HStack(spacing: theme.spacingS) {
            if data.hasPendingReview {
                Button("Review…", action: actions.review)
                    .buttonStyle(QuietButtonStyle())
                    .help("Review session")
            }
            Spacer(minLength: 0)
            Button(action: actions.start) {
                Label(startTitle, systemImage: "play.fill")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Start session")
        }
        .controlSize(.small)
    }

    private var startTitle: String {
        guard let name = data.startLabel?.name.nilIfBlank else { return "Start" }
        return "Start · \(name)"
    }

    private func iconButton(_ systemImage: String, title: String, spokenTitle: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(IconButtonStyle(size: iconSize))
        .accessibilityLabel(spokenTitle ?? title)
        .help(title)
    }

    private var todayTotal: some View {
        HStack(spacing: 3) {
            Image(systemName: "target")
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            Text("Today \(data.todayTotal.formattedShort)")
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .font(theme.captionFont)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today, \(DesignSystemDurationSpeech.spoken(data.todayTotal))")
    }

    @ViewBuilder
    private var note: some View {
        if isLive, let noteFocus {
            LiveQuickNoteField(prompt: "Note…", isCompact: isCompact, isFocused: noteFocus)
        } else if isLive {
            LiveQuickNoteField(prompt: "Note…", isCompact: isCompact)
        } else {
            // Static look-alike: the preview never talks to the engine.
            HStack(spacing: theme.spacingXS) {
                Text("Note…")
                    .font(isCompact ? theme.calloutFont : theme.bodyFont)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "return")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .insetField()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Quick note")
        }
    }
}
