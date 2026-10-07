import Foundation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, history, learning, stats

    var id: String { rawValue }

    /// "Today", "History", "Learning", "Stats"
    var title: String {
        switch self {
        case .today: "Today"
        case .history: "History"
        case .learning: "Learning"
        case .stats: "Stats"
        }
    }

    /// "timer", "clock.arrow.circlepath", "lightbulb", "chart.bar.xaxis"
    var systemImage: String {
        switch self {
        case .today: "timer"
        case .history: "clock.arrow.circlepath"
        case .learning: "lightbulb"
        case .stats: "chart.bar.xaxis"
        }
    }
}
