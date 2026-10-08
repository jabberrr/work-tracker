import SwiftUI
import SwiftData

/// Sidebar profile switcher (above the account/settings footer, see `RootView`): the current profile's tile +
/// name + `chevron.up.chevron.down`. A click opens a drop-up popover: the non-archived profiles (checkmark on
/// the current one), a divider, "New Profile…" (presents `ProfileCreateSheet`) and "Manage Profiles…"
/// (Settings ▸ Profiles). ↑/↓ move the highlight, Return or Space picks, Esc closes.
///
/// Reads `ProfileStore`, `WindowRouter` and the theme from the environment. Always shown, also with one
/// profile: it is the entry point for creating profiles. The popover holds value snapshots (UUIDs), never models.
@MainActor
struct ProfileSwitcher: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(WindowRouter.self) private var router
    @Environment(\.theme) private var theme
    @State private var isPresented = false
    @State private var isCreating = false
    @State private var anchorWidth: CGFloat = 0

    init() {}

    var body: some View {
        let current = ModelLiveness.live(profiles.activeProfile)
        let name = current?.displayName ?? "No profile"
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: theme.spacingS) {
                ProfileSymbolTile(profile: current)
                Text(verbatim: name)
                    .font(theme.calloutFont.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: theme.spacingXS)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9 * theme.textScale, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ProfileSwitcherButtonStyle(isOpen: isPresented))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { anchorWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in anchorWidth = width }
            }
        }
        .help("Switch profile")
        .accessibilityLabel("Profile")
        .accessibilityValue(name)
        // arrowEdge .top: the popover opens above the switcher (drop-up), whatever room is below.
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ProfileSwitcherMenu(entries: entries,
                                activeID: current?.uuid,
                                width: max(anchorWidth, 220),
                                onPick: pick)
                .environment(\.theme, theme)
                .tint(theme.accent)
        }
        .sheet(isPresented: $isCreating) {
            ProfileCreateSheet()
                .environment(profiles)
                .environment(\.theme, theme)
        }
    }

    /// Value snapshots of the live, non-archived profiles, in order.
    private var entries: [ProfileSwitcherEntry] {
        ModelLiveness.live(profiles.profiles).map {
            ProfileSwitcherEntry(id: $0.uuid, name: $0.displayName, colorHex: $0.colorHex, symbolName: $0.symbolName)
        }
    }

    private func pick(_ row: ProfileSwitcherRow) {
        isPresented = false
        switch row {
        case .profile(let id):
            profiles.select(id: id)
        case .create:
            // Present the sheet once the popover has closed (both can't be up at once).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                isCreating = true
            }
        case .manage:
            router.showSettings(tab: "profiles")
        }
    }
}

// MARK: - Popover

/// A profile as the popover shows it (no model object).
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

@MainActor
private struct ProfileSwitcherMenu: View {
    @Environment(\.theme) private var theme
    private let entries: [ProfileSwitcherEntry]
    private let activeID: UUID?
    private let width: CGFloat
    private let onPick: (ProfileSwitcherRow) -> Void
    @State private var highlighted: Int
    @FocusState private var isFocused: Bool

    init(entries: [ProfileSwitcherEntry], activeID: UUID?, width: CGFloat,
         onPick: @escaping (ProfileSwitcherRow) -> Void) {
        self.entries = entries
        self.activeID = activeID
        self.width = width
        self.onPick = onPick
        self._highlighted = State(initialValue: entries.firstIndex { $0.id == activeID } ?? 0)
    }

    /// Every pickable row in keyboard order: profiles, then the two actions.
    private var rows: [ProfileSwitcherRow] {
        entries.map { ProfileSwitcherRow.profile($0.id) } + [.create, .manage]
    }

    /// More profiles than this scroll (the actions stay visible).
    private static var maxVisibleProfiles: Int { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if entries.count > Self.maxVisibleProfiles {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        profileRows
                    }
                    // Row ≈ 18 pt tile + 2 × 4 pt padding + 1 pt spacing.
                    .frame(height: CGFloat(Self.maxVisibleProfiles) * (18 * theme.textScale + 9))
                    .onAppear { proxy.scrollTo(highlighted, anchor: .center) }
                    .onChange(of: highlighted) { _, index in
                        if index < entries.count { proxy.scrollTo(index) }
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
        .padding(5)
        .frame(width: width)
        .background(theme.elevatedSurface)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
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
        .onAppear {
            // Let the popover window become key before taking focus.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                isFocused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profiles")
    }

    private var profileRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isCurrent = entry.id == activeID
                Button {
                    onPick(.profile(entry.id))
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
                .id(index)
            }
        }
    }

    private func actionRow(index: Int, row: ProfileSwitcherRow, title: String, systemImage: String) -> some View {
        Button {
            onPick(row)
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

    private func pickHighlighted() {
        let all = rows
        guard all.indices.contains(highlighted) else { return }
        onPick(all[highlighted])
    }
}

// MARK: - Styles

/// The switcher row: full width, `radiusS` hover/open fill `textPrimary.opacity(0.06)`, pressed 0.10,
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

/// Popover row: highlight fill (hover or keyboard), pressed accent fill.
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
