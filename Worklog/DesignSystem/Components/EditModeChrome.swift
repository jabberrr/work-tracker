import SwiftUI
import AppKit

// Edit-mode chrome for rearrangeable layouts (Settings ▸ Overlay layout editor), in the spirit of iPhone
// Control Center: items wiggle gently, a small red (−) badge sits on each item's top-trailing corner, a slim
// handle on the bottom-trailing corner resizes it, and a round (+) button adds items.
//
//     element
//         .wiggle(isEditing, seed: index)                       // first: the chrome must not rotate
//         .gesture(moveDrag)                                    // the item's own hit layer
//         .editResizeHandle(isEditing, gesture: resizeDrag)     // the feature owns the gesture
//         .editRemoveBadge(isEditing, accessibilityLabel: "Remove \(element.title)") { remove(element) }  // last
//
// The badge goes on LAST so it is the topmost layer: it stays clickable whatever it overlaps. On top of that the
// two hit areas never overlap: the handle sits on the bottom-trailing corner and moves down on items shorter
// than `EditResizeHandle.clearHeight` (see `EditResizeHandle.center(in:)`).
//
// The wiggle is the app's only looping motion (DESIGN §7): edit mode only, and none under Reduce Motion.

/// 14 pt circle, theme.danger fill, white "minus" (7 pt bold), 1.5 pt elevatedSurface ring, 22 pt hit area,
/// .help("Remove"). Place it with `View.editRemoveBadge(_:accessibilityLabel:action:)`.
struct RemoveBadgeButton: View {
    /// Visual circle.
    nonisolated static let diameter: CGFloat = 14
    /// Square hit area (≥ 20 pt).
    nonisolated static let hitSize: CGFloat = 22
    /// With .overlay(alignment: .topTrailing): badge centre sits 3 pt inside the corner, circle overhangs 4 pt.
    nonisolated static let cornerOffset = CGSize(width: 8, height: -8)

    private let accessibilityLabel: String
    private let action: () -> Void

    init(accessibilityLabel: String, action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 7, weight: .bold))
        }
        .buttonStyle(EditBadgeButtonStyle(kind: .remove))
        .help("Remove")
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 24 pt circle, accent fill, onAccent "plus" (11 pt bold), 28 pt hit area, .help("Add").
///
/// When disabled, the button drops its own "Add" tooltip so the caller's reason shows
/// (`.disabled(allShown).help(allShown ? "All elements shown" : "Add")`).
struct AddBadgeButton: View {
    @Environment(\.isEnabled) private var isEnabled
    private let accessibilityLabel: String
    private let action: () -> Void

    init(accessibilityLabel: String, action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(EditBadgeButtonStyle(kind: .add))
        .accessibilityLabel(accessibilityLabel)

        if isEnabled {
            button.help("Add")
        } else {
            button
        }
    }
}

/// Edit-mode resize handle, the bottom-trailing companion of the (−) badge at the same scale: a 4 × 14 pt accent
/// capsule with a 1.5 pt elevatedSurface ring in a 20 × 18 pt hit frame, `NSCursor.resizeLeftRight` while
/// hovered, .help("Resize"). Hidden from VoiceOver: the element's "Wider"/"Narrower" actions replace it.
/// Purely visual: place it with `View.editResizeHandle(_:gesture:)`, which attaches the caller's drag gesture.
struct EditResizeHandle: View {
    /// Hit frame (the capsule is centred in it).
    nonisolated static let hitSize = CGSize(width: 20, height: 18)
    /// Horizontal offset from the trailing edge: capsule centre 2 pt inside it.
    nonisolated static let edgeOffset: CGFloat = 8
    /// Vertical offset from the bottom edge on items at least `clearHeight` tall: the hit frame overhangs 6 pt.
    nonisolated static let bottomOffset: CGFloat = 6
    /// Where the badge's hit area ends, measured down from the item's top edge (22 − 8 = 14 pt).
    nonisolated static var badgeClearance: CGFloat { RemoveBadgeButton.hitSize + RemoveBadgeButton.cornerOffset.height }
    /// The smallest item height at which the handle keeps its plain bottom-trailing place (18 − 6 + 14 = 26 pt)
    /// without touching the badge's hit area. Shorter items push the handle down instead.
    nonisolated static var clearHeight: CGFloat { hitSize.height - bottomOffset + badgeClearance }

    /// The handle's centre in an item of `size` (top-leading origin): bottom-trailing corner offset by
    /// (`edgeOffset`, `bottomOffset`), moved down just enough on short items that its hit frame starts where the
    /// (−) badge's ends. So the two hit areas never overlap, for any item height (an 18 pt item gets its handle
    /// 8 pt lower; at 26 pt and up the offset is the plain one).
    nonisolated static func center(in size: CGSize) -> CGPoint {
        let top = max(size.height - hitSize.height + bottomOffset, badgeClearance)
        return CGPoint(x: size.width - hitSize.width / 2 + edgeOffset, y: top + hitSize.height / 2)
    }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// Whether this handle pushed the resize cursor (keeps push/pop balanced).
    @State private var pushedCursor = false

    init() {}

    var body: some View {
        let width: CGFloat = 4
        let height: CGFloat = 14
        ZStack {
            // The ring separates the handle from whatever it overlaps.
            Capsule()
                .fill(theme.elevatedSurface)
                .frame(width: width + 3, height: height + 3)
            Capsule()
                .fill(theme.accent.opacity(isHovering ? 0.88 : 1))
                .frame(width: width, height: height)
        }
        .frame(width: Self.hitSize.width, height: Self.hitSize.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            setResizeCursor(hovering)
        }
        .onDisappear { setResizeCursor(false) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .help("Resize")
        .accessibilityHidden(true)
    }

    private func setResizeCursor(_ isOn: Bool) {
        if isOn, !pushedCursor {
            NSCursor.resizeLeftRight.push()
            pushedCursor = true
        } else if !isOn, pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
    }
}

extension View {
    /// Top-trailing (−) badge for edit mode; the only way feature code places `RemoveBadgeButton`.
    /// Apply it after `.wiggle` so the badge doesn't rotate, and last of the chrome (after `editResizeHandle`)
    /// so it is the topmost layer and always clickable.
    func editRemoveBadge(_ isShown: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            if isShown {
                RemoveBadgeButton(accessibilityLabel: accessibilityLabel, action: action)
                    .offset(RemoveBadgeButton.cornerOffset)
            }
        }
    }

    /// Bottom-trailing resize handle for edit mode, carrying `gesture`; the only way feature code places
    /// `EditResizeHandle`. Apply it after `.wiggle` and the item's own gesture, and before `editRemoveBadge`.
    /// Placed at `EditResizeHandle.center(in:)` of the item's size, so its hit area never meets the badge's.
    func editResizeHandle<G: Gesture>(_ isShown: Bool, gesture: G) -> some View {
        overlay {
            if isShown {
                // Edit mode only (never on the live overlay). The reader itself takes no hits.
                GeometryReader { proxy in
                    EditResizeHandle()
                        .gesture(gesture)
                        .position(EditResizeHandle.center(in: proxy.size))
                }
            }
        }
    }

    /// Edit-mode wiggle. Implemented with TimelineView(.animation(paused: !isActive)):
    ///   angle = sin(t · 2π / 0.28 + seed) · 1.2°
    /// No repeatForever animations, which leak into other transitions.
    /// Reduce Motion: no rotation; a 1 pt dashed accent outline (radiusS) while active instead.
    ///
    /// Pass a different `seed` per item (its index) so neighbours don't move in lockstep. The view keeps its
    /// identity when `isActive` changes, so its state survives entering and leaving edit mode.
    func wiggle(_ isActive: Bool, seed: Int = 0) -> some View {
        modifier(WiggleModifier(isActive: isActive, seed: seed))
    }
}

// MARK: - Implementation

private enum EditBadgeKind {
    case remove, add
}

private struct EditBadgeButtonStyle: ButtonStyle {
    let kind: EditBadgeKind

    func makeBody(configuration: Configuration) -> some View {
        EditBadgeBody(configuration: configuration, kind: kind)
    }
}

private struct EditBadgeBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: EditBadgeKind

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, kind: EditBadgeKind) {
        self.configuration = configuration
        self.kind = kind
    }

    private var isPressed: Bool { configuration.isPressed }

    var body: some View {
        let diameter: CGFloat = kind == .remove ? RemoveBadgeButton.diameter : 24
        let hitSize: CGFloat = kind == .remove ? RemoveBadgeButton.hitSize : 28
        ZStack {
            if kind == .remove {
                // The ring separates the badge from whatever it overlaps.
                Circle()
                    .fill(theme.elevatedSurface)
                    .frame(width: diameter + 3, height: diameter + 3)
            }
            Circle()
                .fill(fill)
                .frame(width: diameter, height: diameter)
            configuration.label
                .foregroundStyle(kind == .remove ? Color.white : theme.onAccent)
            if isFocused {
                Circle()
                    .stroke(theme.accent.opacity(0.55), lineWidth: 2)
                    .frame(width: diameter + 6, height: diameter + 6)
            }
        }
        .frame(width: hitSize, height: hitSize)
        // The small (−) badge gets the whole 22 × 22 square; the large (+) keeps a round hit area.
        .contentShape(kind == .remove ? AnyShape(Rectangle()) : AnyShape(Circle()))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering in isHovering = isEnabled && hovering }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
    }

    private var fill: Color {
        let base = kind == .remove ? theme.danger : theme.accent
        if isPressed { return base.opacity(0.75) }
        return isHovering ? base.opacity(0.88) : base
    }
}

private struct WiggleModifier: ViewModifier {
    let isActive: Bool
    let seed: Int

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One full back-and-forth, in seconds.
    private static let period: Double = 0.28
    /// Peak rotation, in degrees.
    private static let amplitude: Double = 1.2

    init(isActive: Bool, seed: Int) {
        self.isActive = isActive
        self.seed = seed
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .padding(-2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { context in
                content
                    .rotationEffect(.degrees(isActive ? Self.angle(at: context.date, seed: seed) : 0))
            }
        }
    }

    private static func angle(at date: Date, seed: Int) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return sin(t * 2 * Double.pi / period + Double(seed)) * amplitude
    }
}

#Preview("Edit mode chrome") {
    VStack(spacing: 24) {
        HStack(spacing: 20) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: index == 0 ? 18 : 44)
                    .wiggle(true, seed: index)
                    .editResizeHandle(true, gesture: DragGesture())
                    .editRemoveBadge(true, accessibilityLabel: "Remove item \(index + 1)") {}
            }
        }
        AddBadgeButton(accessibilityLabel: "Add element") {}
    }
    .padding(32)
}
