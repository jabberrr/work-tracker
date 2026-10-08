import Foundation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, history, learning, stats, settings

    var id: String { rawValue }

    /// The List rows: [.today, .history, .learning, .stats] (Settings is pinned in the sidebar footer).
    static let primaryItems: [SidebarItem] = [.today, .history, .learning, .stats]

    /// "Today", "History", "Learning", "Stats", "Settings"
    var title: String {
        switch self {
        case .today: "Today"
        case .history: "History"
        case .learning: "Learning"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    /// "timer", "clock.arrow.circlepath", "lightbulb", "chart.bar.xaxis", "gearshape"
    var systemImage: String {
        switch self {
        case .today: "timer"
        case .history: "clock.arrow.circlepath"
        case .learning: "lightbulb"
        case .stats: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}
