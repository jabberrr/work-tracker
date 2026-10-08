import SwiftData
import SwiftUI

/// Sections of the in-app Settings page. Raw values are persisted (`settingsWindow.selectedTab`) and used by
/// `WindowRouter.showSettings(tab:)`, so they never change.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, overlay, shortcuts, labels, account, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .overlay: "Overlay"
        case .shortcuts: "Shortcuts"
        case .labels: "Labels & Tags"
        case .account: "Account"
        case .data: "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .overlay: "rectangle.inset.topright.filled"
        case .shortcuts: "keyboard"
        case .labels: "tag"
        case .account: "person.crop.circle"
        case .data: "externaldrive"
        }
    }
}

/// Settings, shown in the main window's detail column (`SidebarItem.settings`). A `PillTabBar` switches sections;
/// each section fills the column below it, wrapped in a `SettingsPage`.
///
/// `WindowRouter.showSettings(tab:)` sets `router.settingsTabRequest` to a `SettingsTab.rawValue`; this view selects
/// that section (on appear and whenever the request changes) and clears the request.
@MainActor
struct SettingsView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(WindowRouter.self) private var router
    @Environment(\.theme) private var theme
    @AppStorage("settingsWindow.selectedTab") private var selectedTab: SettingsTab = .general

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            PillTabBar(items: SettingsTab.allCases, selection: $selectedTab,
                       title: { $0.title }, systemImage: { $0.systemImage })
                .padding(.horizontal, theme.spacingXL)
                .padding(.top, theme.spacingL)
                .padding(.bottom, theme.spacingM)
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
            content(for: selectedTab)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .themedBackground()
        .onAppear {
            if router.settingsTabRequest != nil {
                applyTabRequest()
            } else if SettingsRecovery.isNeeded(persistence) {
                // The store couldn't be opened: go straight to Data, where "Recover…" lives.
                selectedTab = .data
            }
        }
        .onChange(of: router.settingsTabRequest) {
            applyTabRequest()
        }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            SettingsPage { SettingsGeneralTab() }
        case .appearance:
            SettingsPage { SettingsAppearanceTab() }
        case .overlay:
            // F2's view wraps itself in a SettingsPage.
            SettingsOverlayTab()
        case .shortcuts:
            SettingsPage { SettingsShortcutsTab() }
        case .labels:
            SettingsPage(maxWidth: nil) { SettingsLabelsTab() }
        case .account:
            SettingsPage { SettingsAccountTab() }
        case .data:
            SettingsPage { SettingsDataTab() }
        }
    }

    /// Selects the requested section (unknown raw values are ignored) and clears the request.
    private func applyTabRequest() {
        guard let raw = router.settingsTabRequest else { return }
        if let tab = SettingsTab(rawValue: raw) {
            selectedTab = tab
        }
        router.settingsTabRequest = nil
    }
}

/// Wraps one Settings section's content: caps the width (nil = full width), top-aligned, centred, themed background.
struct SettingsPage<Content: View>: View {
    private let maxWidth: CGFloat?
    private let content: Content

    init(maxWidth: CGFloat? = 720, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        content
            .frame(minWidth: 0, maxWidth: maxWidth ?? .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .themedBackground()
    }
}

/// Small explanatory text under a Form row.
struct SettingsFootnote: View {
    @Environment(\.theme) private var theme
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.captionFont)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
