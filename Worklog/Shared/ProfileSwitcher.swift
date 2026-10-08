import SwiftUI
import SwiftData

/// Sidebar profile switcher (above the account/settings footer, see `RootView`): the current profile's tile +
/// name + a `chevron.up` disclosure. A click expands an **inline list** directly above the row (no popover):
/// the non-archived profiles (checkmark on the current one), a divider, "New Profile…" (presents
/// `ProfileCreateSheet` right away) and "Manage Profiles…" (Settings ▸ Profiles). ↑/↓ move the highlight,
/// Return or Space picks, Esc collapses (DESIGN §16.4, §17).
///
/// The list grows the sidebar's bottom inset upward; the footer below never moves. Its height is capped by
/// `maxMenuHeight` (see `menuHeightLimit(sidebarHeight:)`): profile rows scroll only when they don't fit, and
/// the two actions always stay visible.
///
/// Reads `ProfileStore`, `WindowRouter` and the theme from the environment. Always shown, also with one
/// profile: it is the entry point for creating profiles. The list holds value snapshots (UUIDs), never models.
@MainActor
struct ProfileSwitcher: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(WindowRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localExpanded = false
    @State private var isCreating = false
    @FocusState private var rowFocused: Bool
    private let externalExpanded: Binding<Bool>?
    private let maxMenuHeight: CGFloat

    /// RootView: the sidebar owns `isExpanded` (so a click elsewhere in the sidebar can collapse it) and passes
    /// the height limit from `menuHeightLimit(sidebarHeight:)`.
    init(isExpanded: Binding<Bool>, maxMenuHeight: CGFloat) {
        self.externalExpanded = isExpanded
        self.maxMenuHeight = maxMenuHeight
    }

    /// Standalone/previews: internal expansion state, `maxMenuHeight` 280.
    init() {
        self.externalExpanded = nil
        self.maxMenuHeight = 280
    }

    /// The list's height limit for a sidebar of `sidebarHeight`: `min(360, max(120, sidebarHeight * 0.5))`.
    nonisolated static func menuHeightLimit(sidebarHeight: CGFloat) -> CGFloat {
        min(360, max(120, sidebarHeight * 0.5))
    }

    private var isExpanded: Bool {
        get { externalExpanded?.wrappedValue ?? localExpanded }
        nonmutating set {
            if let externalExpanded {
                externalExpanded.wrappedValue = newValue
            } else {
                localExpanded = newValue
            }
        }
    }

    private var toggleAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var body: some View {
        let current = ModelLiveness.live(profiles.activeProfile)
        let name = current?.displayName ?? "No profile"
        VStack(spacing: 0) {
            // Always-present clip container: its height animates with the inset while the list slides up from
            // behind the row, so the list never draws over the row or the footer.
            VStack(spacing: 0) {
                if isExpanded {
                    ProfileSwitcherList(entries: entries,
                                        activeID: current?.uuid,
                                        maxHeight: maxMenuHeight,
                                        onPick: pick,
                                        onDismiss: { setExpanded(false, restoreFocus: true) })
                        .padding(.bottom, theme.spacingXS)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            switcherRow(current: current, name: name)
        }
        .onExitCommand {
            if isExpanded { setExpanded(false, restoreFocus: true) }
        }
        .sheet(isPresented: $isCreating) {
            ProfileCreateSheet()
                .environment(profiles)
                .environment(\.theme, theme)
        }
    }

    private func switcherRow(current: WorkProfile?, name: String) -> some View {
        Button {
            setExpanded(!isExpanded, restoreFocus: false)
        } label: {
            HStack(spacing: theme.spacingS) {
                ProfileSymbolTile(profile: current)
                Text(verbatim: name)
                    .font(theme.calloutFont.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: theme.spacingXS)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9 * theme.textScale, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(toggleAnimation, value: isExpanded)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ProfileSwitcherButtonStyle(isOpen: isExpanded))
        .focused($rowFocused)
        .help("Switch profile")
        .accessibilityLabel("Profile")
        .accessibilityValue(name)
        .accessibilityHint(isExpanded ? "Hides the profile list." : "Shows the profile list.")
    }

    /// Value snapshots of the live, non-archived profiles, in order.
    private var entries: [ProfileSwitcherEntry] {
        ModelLiveness.live(profiles.profiles).map {
            ProfileSwitcherEntry(id: $0.uuid, name: $0.displayName, colorHex: $0.colorHex, symbolName: $0.symbolName)
        }
    }

    private func setExpanded(_ value: Bool, restoreFocus: Bool) {
        if value != isExpanded {
            withAnimation(toggleAnimation) { isExpanded = value }
        }
        // Best effort: the row only takes focus with Full Keyboard Access on.
        if restoreFocus { rowFocused = true }
    }

    private func pick(_ row: ProfileSwitcherRow, viaKeyboard: Bool) {
        setExpanded(false, restoreFocus: viaKeyboard)
        switch row {
        case .profile(let id):
            profiles.select(id: id)
        case .create:
            // Inline list, no popover to wait for: the sheet can open right away.
            isCreating = true
        case .manage:
            router.showSettings(tab: "profiles")
        }
    }
}

// MARK: - Inline list

/// A profile as the list shows it (no model object).
private struct ProfileSwitcherEntry: Hashable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let symbolName: String
}

private enum ProfileSwitcherRow: Hashable {
    case profile(UUID)
    case create
    case manage
}

/// The expanded list: `textPrimary.opacity(0.04)` fill, `radiusM`, 1 pt `separator` stroke, padding `spacingXS`.
/// No shadow and no `elevatedSurface`: it is part of the sidebar, not a floating menu.
@MainActor
private struct ProfileSwitcherList: View {
    @Environment(\.theme) private var theme
    private let entries: [ProfileSwitcherEntry]
    private let activeID: UUID?
    private let maxHeight: CGFloat
    private let onPick: (ProfileSwitcherRow, Bool) -> Void
    private let onDismiss: () -> Void
    @State private var highlighted: Int
    @FocusState private var listFocused: Bool
    @AccessibilityFocusState private var voiceOverFocus: UUID?

    init(entries: [ProfileSwitcherEntry], activeID: UUID?, maxHeight: CGFloat,
         onPick: @escaping (ProfileSwitcherRow, Bool) -> Void, onDismiss: @escaping () -> Void) {
        self.entries = entries
        self.activeID = activeID
        self.maxHeight = maxHeight
        self.onPick = onPick
        self.onDismiss = onDismiss
        self._highlighted = State(initialValue: entries.firstIndex { $0.id == activeID } ?? 0)
    }

    /// Every pickable row in keyboard order: profiles, then the two actions.
    private var rows: [ProfileSwitcherRow] {
        entries.map { ProfileSwitcherRow.profile($0.id) } + [.create, .manage]
    }

    /// One row: an 18 pt (× textScale) line + 2 × 4 pt padding + 1 pt spacing.
    private var rowHeight: CGFloat { 18 * theme.textScale + 9 }

    /// The two actions, the divider (1 pt + its padding) and the container padding.
    private var actionsBlock: CGFloat {
        2 * rowHeight + (1 + 2 * theme.spacingXS) + 2 * theme.spacingXS
    }

    /// Profile rows that fit under the limit next to the actions (at least one).
    private var visibleRows: Int {
        max(1, Int((maxHeight - actionsBlock) / rowHeight))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            if entries.count > visibleRows {
                // Only when needed: a short list is never padded out to the limit.
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        profileRows
                    }
                    .frame(height: CGFloat(visibleRows) * rowHeight)
                    .onAppear {
                        if entries.indices.contains(highlighted) {
                            proxy.scrollTo(entries[highlighted].id, anchor: .center)
                        }
                    }
                    .onChange(of: highlighted) { _, index in
                        if entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                    }
                }
            } else {
                profileRows
            }
            if !entries.isEmpty {
                Divider()
                    .padding(.vertical, theme.spacingXS)
                    .padding(.horizontal, theme.spacingS)
            }
            actionRow(index: entries.count, row: .create, title: "New Profile…", systemImage: "plus")
            actionRow(index: entries.count + 1, row: .manage, title: "Manage Profiles…", systemImage: "gearshape")
        }
        .padding(theme.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.textPrimary.opacity(0.04)))
        .overlay(shape.strokeBorder(theme.separator, lineWidth: theme.borderWidth))
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) {
            move(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            pickHighlighted()
            return .handled
        }
        .onKeyPress(.space) {
            pickHighlighted()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: entries) { _, _ in clampHighlight() }
        .onAppear {
            // Next main-actor turn: the list must be in the hierarchy before it can take focus.
            Task { @MainActor in
                listFocused = true
                voiceOverFocus = activeID
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profiles")
        .accessibilityAction(.escape) { onDismiss() }
    }

    private var profileRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isCurrent = entry.id == activeID
                Button {
                    onPick(.profile(entry.id), false)
                } label: {
                    HStack(spacing: theme.spacingS) {
                        checkmark(isCurrent)
                        ProfileSymbolTile(colorHex: entry.colorHex, symbolName: entry.symbolName)
                        Text(verbatim: entry.name)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(ProfileMenuRowStyle(isHighlighted: index == highlighted))
                .onHover { if $0 { highlighted = index } }
                .help(entry.name)
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityFocused($voiceOverFocus, equals: entry.id)
                .id(entry.id)
            }
        }
    }

    private func actionRow(index: Int, row: ProfileSwitcherRow, title: String, systemImage: String) -> some View {
        Button {
            onPick(row, false)
        } label: {
            HStack(spacing: theme.spacingS) {
                checkmark(false)
                Image(systemName: systemImage)
                    .font(.system(size: 11 * theme.textScale, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ProfileMenuRowStyle(isHighlighted: index == highlighted))
        .onHover { if $0 { highlighted = index } }
        .accessibilityLabel(title)
    }

    private func checkmark(_ visible: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10 * theme.textScale, weight: .bold))
            .foregroundStyle(theme.accent)
            .opacity(visible ? 1 : 0)
            .frame(width: 12)
            .accessibilityHidden(true)
    }

    private func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    /// The profile list changed while open (sync, archive, another window): keep the highlight in range.
    private func clampHighlight() {
        highlighted = min(max(highlighted, 0), rows.count - 1)
    }

    private func pickHighlighted() {
        let all = rows
        guard all.indices.contains(highlighted) else { return }
        onPick(all[highlighted], true)
    }
}

// MARK: - Styles

/// The switcher row: full width, `radiusS` hover/expanded fill `textPrimary.opacity(0.06)`, pressed 0.10,
/// accent focus ring for keyboard focus.
private struct ProfileSwitcherButtonStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        ProfileSwitcherButtonBody(configuration: configuration, isOpen: isOpen)
    }
}

private struct ProfileSwitcherButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOpen: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    init(configuration: ButtonStyleConfiguration, isOpen: Bool) {
        self.configuration = configuration
        self.isOpen = isOpen
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay {
                if isFocused {
                    shape.stroke(theme.accent.opacity(0.55), lineWidth: 2)
                }
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if configuration.isPressed { return theme.textPrimary.opacity(0.10) }
        return (isHovering || isOpen) ? theme.textPrimary.opacity(0.06) : Color.clear
    }
}

/// List row: highlight fill (hover or keyboard), pressed accent fill. The label is at least 18 pt (× textScale)
/// tall, so every row is exactly `18 * textScale + 8` and the list's height math holds.
private struct ProfileMenuRowStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        ProfileMenuRowBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct ProfileMenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        configuration.label
            .font(theme.bodyFont)
            .frame(minHeight: 18 * theme.textScale)
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.accent.opacity(0.18)
                          : (isHighlighted ? theme.textPrimary.opacity(0.07) : Color.clear))
            )
            .contentShape(Rectangle())
    }
}
