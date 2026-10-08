import Foundation

/// One element of the floating overlay. Persisted by rawValue in `AppSettings.overlayLayout`.
enum OverlayElement: String, CaseIterable, Identifiable, Codable, Hashable {
    case label, timer, segmentFocus, controls, split, todayTotal, note, takeaway

    var id: String { rawValue }

    /// "Label", "Timer", "Segment focus", "Controls", "Split", "Today’s total", "Quick note", "Takeaway"
    var title: String {
        switch self {
        case .label: "Label"
        case .timer: "Timer"
        case .segmentFocus: "Segment focus"
        case .controls: "Controls"
        case .split: "Split"
        case .todayTotal: "Today\u{2019}s total"
        case .note: "Quick note"
        case .takeaway: "Takeaway"
        }
    }

    /// "tag", "timer", "scope", "playpause", "scissors", "target", "square.and.pencil", "quote.opening"
    var systemImage: String {
        switch self {
        case .label: "tag"
        case .timer: "timer"
        case .segmentFocus: "scope"
        case .controls: "playpause"
        case .split: "scissors"
        case .todayTotal: "target"
        case .note: "square.and.pencil"
        case .takeaway: "quote.opening"
        }
    }

    /// Fresh install and "Reset layout".
    static let defaultLayout: [OverlayElement] = [.label, .timer, .segmentFocus, .controls, .split, .note, .takeaway]

    /// Order used to migrate the legacy `settings.overlayShow…` booleans.
    static let migrationOrder: [OverlayElement] = [.label, .timer, .segmentFocus, .controls, .split, .todayTotal, .note, .takeaway]

    /// Drops unknown raw values and duplicates (first occurrence wins), keeps order.
    static func sanitized(_ rawValues: [String]) -> [OverlayElement] {
        var seen = Set<OverlayElement>()
        var result: [OverlayElement] = []
        for raw in rawValues {
            guard let element = OverlayElement(rawValue: raw), !seen.contains(element) else { continue }
            seen.insert(element)
            result.append(element)
        }
        return result
    }
}
