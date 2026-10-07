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
struct SettingsView: View {
    @Environment(PersistenceController.self) private var persistence
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
            // The store couldn't be opened: RootView's "Restore from backup…" opens Settings — go straight to Data.
            if case .inMemory(let reason) = persistence.storeMode, reason != "Preview" {
                selectedTab = .data
            }
        }
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
