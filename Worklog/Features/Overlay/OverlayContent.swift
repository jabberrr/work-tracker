import AppKit
import SwiftData
import SwiftUI

// The floating overlay's renderer, shared by the live panel (`OverlayView`) and the layout editor in
// Settings ▸ Overlay (`OverlayLayoutEditor`), so both always look the same.
//
// Model: `settings.overlayGrid` (`OverlayGridLayout`) places each `OverlayElement` in a 6-column grid of rows
// with intrinsic height. Row 0 is the header row: it renders inline between the status dot and the profile tag /
// close button (chrome, not elements). Body rows render below it; rows with nothing visible collapse. Idle, the
// header says "Not tracking" and row 0's visible elements become the first body row. Grid helpers live in
// `OverlayGridViews.swift`.

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
    /// The panel profile (running session's profile, else the quick start profile), shown subtly in the header.
    /// Both nil with only one profile.
    var profileName: String? = nil
    var profileColorHex: String? = nil

    var isActive: Bool { status != .idle }
    var isPaused: Bool { status == .paused }

    /// Header profile fields for `profile`: nil unless `showsProfile` (2 or more profiles) and it is live.
    @MainActor
    static func profileFields(_ profile: WorkProfile?, showsProfile: Bool) -> (name: String?, colorHex: String?) {
        guard showsProfile, let profile = ModelLiveness.live(profile) else { return (nil, nil) }
        return (profile.displayName, profile.colorHex)
    }

    /// Preview data: 1:12:40 elapsed, segment 24:10, focus "Refactor parser", today 2h 15m.
    /// `takeaway` nil uses a sample takeaway, so the preview always shows that element.
    static func sample(status: Status, label: WorkLabel?, takeaway: SessionTakeaway?,
                       profileName: String? = nil, profileColorHex: String? = nil) -> OverlayDisplayData {
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
            isOnAnotherMac: false,
            profileName: profileName,
            profileColorHex: profileColorHex
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

/// Edit-mode extras for `OverlayContent`. `.none` (live and preview) adds no geometry readers or preferences.
struct OverlayEditingOptions {
    /// While dragging: an empty row of this height under the last row (grid row `rowCount`), a drop target that
    /// creates a new row.
    var trailingDropRowHeight: CGFloat? = nil
    /// Each row reports its frame in the "overlayGrid" space (`OverlayGridRowFramesKey`).
    var reportsFrames = false

    init(trailingDropRowHeight: CGFloat? = nil, reportsFrames: Bool = false) {
        self.trailingDropRowHeight = trailingDropRowHeight
        self.reportsFrames = reportsFrames
    }

    static let none = OverlayEditingOptions()
}

/// Renders `grid` with `data`. 300 pt wide (220 compact); height is intrinsic.
///
/// `chrome` wraps every rendered element (the editor adds the wiggle, remove badge, resize handle, drag gesture
/// and the context menu there); the header's dot, status and close button are never passed through it.
/// `panelOpacity` fades the panel (background and content) without fading the chrome the editor adds.
@MainActor
struct OverlayContent<ElementChrome: View>: View {
    @Environment(\.theme) private var theme

    private let grid: OverlayGridLayout
    private let data: OverlayDisplayData
    private let isCompact: Bool
    private let mode: OverlayMode
    private let panelOpacity: Double
    private let isSplitting: Bool
    private let noteFocus: FocusState<Bool>.Binding?
    private let actions: OverlayActions
    private let editing: OverlayEditingOptions
    private let chrome: (OverlayPlacement, OverlayElementView) -> ElementChrome

    init(grid: OverlayGridLayout, data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         panelOpacity: Double = 1, isSplitting: Bool = false, noteFocus: FocusState<Bool>.Binding? = nil,
         actions: OverlayActions = .none, editing: OverlayEditingOptions = .none,
         @ViewBuilder chrome: @escaping (OverlayPlacement, OverlayElementView) -> ElementChrome) {
        self.grid = grid
        self.data = data
        self.isCompact = isCompact
        self.mode = mode
        self.panelOpacity = panelOpacity
        self.isSplitting = isSplitting
        self.noteFocus = noteFocus
        self.actions = actions
        self.editing = editing
        self.chrome = chrome
    }

    private var isLive: Bool { mode == .live }
    /// Idle outside edit mode (edit mode always shows the running sample).
    private var isIdle: Bool { mode != .editing && !data.isActive }
    /// Frames are an edit-mode affair: never in the live overlay.
    private var reportsFrames: Bool { editing.reportsFrames && !isLive }

    var body: some View {
        let rows = renderRows

        VStack(alignment: .leading, spacing: isCompact ? theme.spacingXS + 2 : theme.spacingS) {
            header(rows.header)

            if isLive && data.isActive && data.isOnAnotherMac {
                LiveOtherMacHint()
            }

            if showsSplitForm(after: rows.header) {
                splitForm
            }

            ForEach(rows.body) { row in
                gridRow(row)
                    .overlayGridRowFrame(row.row, isActive: reportsFrames)
                if showsSplitForm(after: row) {
                    splitForm
                }
            }

            if !isLive, let height = editing.trailingDropRowHeight {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: max(height, 1))
                    .overlayGridRowFrame(grid.rowCount, isActive: reportsFrames)
                    .accessibilityHidden(true)
            }

            if needsStandaloneReview {
                standaloneReview
            }
        }
        .padding(isCompact ? theme.spacingS : theme.spacingM)
        .frame(width: isCompact ? 220 : 300, alignment: .leading)
        .modifier(OverlayPanelSurface(isLive: isLive, opacity: panelOpacity))
    }

    // MARK: Rows

    /// Visible placements per row. Idle: the header shows "Not tracking", row 0's visible elements become the first
    /// body row, and the idle controls (Review… / Start) widen over the free columns of their row.
    private var renderRows: OverlayGridRenderRows {
        let sample = self.data
        let idle = self.isIdle
        let widening: Set<OverlayElement> = idle ? [.controls] : []
        return grid.renderRows(isVisible: { Self.isVisible($0, data: sample, isIdle: idle) },
                               headerInline: !idle,
                               widening: widening)
    }

    /// Same rule as before the grid: a takeaway needs one; idle shows only the takeaway, today's total and the
    /// controls.
    private static func isVisible(_ element: OverlayElement, data: OverlayDisplayData, isIdle: Bool) -> Bool {
        if element == .takeaway && data.takeaway == nil { return false }
        guard isIdle else { return true }
        switch element {
        case .takeaway, .todayTotal, .controls: return true
        case .label, .timer, .segmentFocus, .split, .note: return false
        }
    }

    /// Idle + pending review + no Controls element (live only): the review must stay reachable.
    private var needsStandaloneReview: Bool {
        isLive && isIdle && data.hasPendingReview && !grid.contains(.controls)
    }

    private func gridRow(_ row: OverlayGridRenderRow) -> some View {
        OverlayGridRowLayout(gutter: theme.spacingXS) {
            ForEach(row.placements) { placement in
                chrome(placement, elementView(placement))
                    .overlayGridCell(column: placement.column, span: placement.span)
            }
        }
    }

    private func elementView(_ placement: OverlayPlacement) -> OverlayElementView {
        OverlayElementView(element: placement.element, data: data, isCompact: isCompact, mode: mode,
                           opacity: panelOpacity, noteFocus: noteFocus, actions: actions,
                           alignment: placement.element.overlayCellAlignment(column: placement.column,
                                                                             span: placement.span,
                                                                             isActive: data.isActive))
    }

    // MARK: Header

    /// Dot, the header row (row 0) or the status word when nothing in it is visible, profile tag, close button.
    private func header(_ row: OverlayGridRenderRow) -> some View {
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

            ZStack(alignment: .leading) {
                if row.placements.isEmpty {
                    statusText
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(panelOpacity)
                }
                gridRow(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayGridRowFrame(OverlayGridLayout.headerRow, isActive: reportsFrames)

            if let name = data.profileName {
                profileTag(name)
                    .opacity(panelOpacity)
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

    /// Subtle: a 6 pt dot in the profile color and the name (caption, tertiary), truncating.
    private func profileTag(_ name: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(data.profileColorHex.map { Color(hex: $0) } ?? theme.textTertiary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(name)
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Ideal width, capped: long names truncate instead of crowding the header.
        .frame(maxWidth: isCompact ? 64 : 96, alignment: .trailing)
        .fixedSize()
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile")
        .accessibilityValue(name)
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

    // MARK: Split form (live only)

    private func showsSplitForm(after row: OverlayGridRenderRow) -> Bool {
        isLive && isSplitting && data.isActive && row.placements.contains { $0.element == .split }
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
    init(grid: OverlayGridLayout, data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         panelOpacity: Double = 1, isSplitting: Bool = false, noteFocus: FocusState<Bool>.Binding? = nil,
         actions: OverlayActions = .none) {
        self.init(grid: grid, data: data, isCompact: isCompact, mode: mode, panelOpacity: panelOpacity,
                  isSplitting: isSplitting, noteFocus: noteFocus, actions: actions, editing: .none,
                  chrome: { _, view in view })
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

// MARK: - Element view

/// One element's content in any mode, filling its grid cell (`alignment` places hug elements inside it; they
/// truncate rather than overflow a narrow cell). Outside `.live` it ignores hits, so nothing reaches the engine.
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
    private let alignment: Alignment

    init(element: OverlayElement, data: OverlayDisplayData, isCompact: Bool, mode: OverlayMode,
         opacity: Double = 1, noteFocus: FocusState<Bool>.Binding? = nil, actions: OverlayActions = .none,
         alignment: Alignment = .leading) {
        self.element = element
        self.data = data
        self.isCompact = isCompact
        self.mode = mode
        self.opacity = opacity
        self.noteFocus = noteFocus
        self.actions = actions
        self.alignment = alignment
    }

    private var isLive: Bool { mode == .live }
    private var iconSize: CGFloat { isCompact ? 22 : 26 }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(opacity)
            .allowsHitTesting(isLive)
    }

    @ViewBuilder
    private var content: some View {
        switch element {
        case .label:
            LabelBadge(label: data.label, size: .small)
        case .timer:
            timer
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

    /// Large digits when they fit the cell, else the compact style (compact mode: always compact).
    @ViewBuilder
    private var timer: some View {
        if isCompact {
            TimerText(data.elapsed, style: .compact, isPaused: data.isPaused)
        } else {
            ViewThatFits(in: .horizontal) {
                TimerText(data.elapsed, style: .large, isPaused: data.isPaused)
                TimerText(data.elapsed, style: .compact, isPaused: data.isPaused)
            }
        }
    }

    /// The focus truncates first, then the segment time.
    private var segmentFocus: some View {
        HStack(spacing: theme.spacingXS) {
            Text(focusText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· seg \(data.segmentElapsed.formattedClock)")
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
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

    /// "Today 2h 15m", then "2h 15m" when the cell is narrow, then the bare value (truncating).
    private var todayTotal: some View {
        let value = data.todayTotal.formattedShort
        return ViewThatFits(in: .horizontal) {
            todayTotalRow("Today \(value)", showsIcon: true)
            todayTotalRow(value, showsIcon: true)
            todayTotalRow(value, showsIcon: false)
        }
        .font(theme.captionFont)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today, \(DesignSystemDurationSpeech.spoken(data.todayTotal))")
    }

    private func todayTotalRow(_ text: String, showsIcon: Bool) -> some View {
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: "target")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .truncationMode(.tail)
        }
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
