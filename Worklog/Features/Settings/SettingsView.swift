import SwiftData
import SwiftUI

/// Tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, overlay, labels, account, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .overlay: "Overlay & Menu Bar"
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
        case .labels: "tag"
        case .account: "person.crop.circle"
        case .data: "externaldrive"
        }
    }
}

/// Root of the `Settings` scene (⌘,). Native TabView, ~680 × 520, a grouped Form per tab.
///
/// `WindowRouter.showSettings(tab:)` sets `router.settingsTabRequest` to a `SettingsTab.rawValue`; this view selects
/// that tab (on appear and whenever the request changes) and clears the request.
@MainActor
struct SettingsView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(WindowRouter.self) private var router
    @AppStorage("settingsWindow.selectedTab") private var selectedTab: SettingsTab = .general

    init() {}

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsGeneralTab()
                .settingsTabItem(.general)
            SettingsAppearanceTab()
                .settingsTabItem(.appearance)
            SettingsOverlayTab()
                .settingsTabItem(.overlay)
            SettingsLabelsTab()
                .settingsTabItem(.labels)
            SettingsAccountTab()
                .settingsTabItem(.account)
            SettingsDataTab()
                .settingsTabItem(.data)
        }
        .frame(width: 680, height: 520)
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

    /// Selects the requested tab (unknown raw values are ignored) and clears the request.
    private func applyTabRequest() {
        guard let raw = router.settingsTabRequest else { return }
        if let tab = SettingsTab(rawValue: raw) {
            selectedTab = tab
        }
        router.settingsTabRequest = nil
    }
}

private extension View {
    func settingsTabItem(_ tab: SettingsTab) -> some View {
        self
            .themedBackground()
            .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            .tag(tab)
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
