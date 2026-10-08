import Foundation
import SwiftData

/// Sort (and grouping) options of the History list.
/// - Date sorts group by the session's start day (`relativeDayTitle`; midnight-crossing sessions stay on
///   their start day).
/// - Length sorts use `storedActiveDuration` and group into duration buckets.
/// - Label A–Z groups by primary label (Unlabeled last), newest first inside each label.
/// - Focus A–Z groups by the first segment's focus (falling back to the session title; sessions with
///   neither come last), newest first inside each group.
enum HistorySort: String, CaseIterable, Identifiable {
    case dateNewest, dateOldest, longest, shortest, labelAZ, focusAZ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateNewest: "Newest first"
        case .dateOldest: "Oldest first"
        case .longest: "Longest"
        case .shortest: "Shortest"
        case .labelAZ: "Label A–Z"
        case .focusAZ: "Focus A–Z"
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest: "calendar.badge.clock"
        case .dateOldest: "calendar"
        case .longest: "arrow.down.right.and.arrow.up.left"
        case .shortest: "arrow.up.left.and.arrow.down.right"
        case .labelAZ: "textformat"
        case .focusAZ: "scope"
        }
    }

    /// True when sections are days (rows then show only times, not dates).
    var groupsByDay: Bool { self == .dateNewest || self == .dateOldest }
}

/// One sticky section of the History list.
struct HistorySection: Identifiable {
    let id: String
    let title: String
    /// Label color for label sections (decorative dot), nil otherwise.
    let colorHex: String?
    var sessions: [WorkSession]
}

/// Pure grouping/sorting of already-filtered sessions. Runs only when the inputs change (never in `body`).
@MainActor enum HistoryGrouping {
    /// Active seconds used for length sorting: the cached value, or a computed one for rows that never had it set.
    static func duration(of session: WorkSession) -> TimeInterval {
        session.storedActiveDuration > 0 ? session.storedActiveDuration : session.activeDuration()
    }

    static func sections(for sessions: [WorkSession], sort: HistorySort) -> [HistorySection] {
        switch sort {
        case .dateNewest:
            return byDay(sessions.sorted { $0.startedAt > $1.startedAt })
        case .dateOldest:
            return byDay(sessions.sorted { $0.startedAt < $1.startedAt })
        case .longest, .shortest:
            return byLength(sessions, longestFirst: sort == .longest)
        case .labelAZ:
            return byLabel(sessions)
        case .focusAZ:
            return byFocus(sessions)
        }
    }

    // MARK: - Private

    private static func byDay(_ sorted: [WorkSession]) -> [HistorySection] {
        var result: [HistorySection] = []
        var currentDay: Date?
        for session in sorted {
            let day = session.startedAt.startOfDay
            if day != currentDay || result.isEmpty {
                currentDay = day
                result.append(HistorySection(id: "day-\(Int(day.timeIntervalSince1970))",
                                             title: day.relativeDayTitle,
                                             colorHex: nil,
                                             sessions: [session]))
            } else {
                result[result.count - 1].sessions.append(session)
            }
        }
        return result
    }

    private struct Bucket {
        let id: String
        let title: String
        let lowerBound: TimeInterval   // inclusive, seconds
    }

    /// Longest bucket first.
    private static let buckets: [Bucket] = [
        Bucket(id: "len-4h", title: "4 hours or more", lowerBound: 4 * 3600),
        Bucket(id: "len-2h", title: "2 to 4 hours", lowerBound: 2 * 3600),
        Bucket(id: "len-1h", title: "1 to 2 hours", lowerBound: 3600),
        Bucket(id: "len-30m", title: "30 minutes to 1 hour", lowerBound: 30 * 60),
        Bucket(id: "len-0", title: "Under 30 minutes", lowerBound: 0),
    ]

    private static func byLength(_ sessions: [WorkSession], longestFirst: Bool) -> [HistorySection] {
        let keyed = sessions.map { (session: $0, duration: duration(of: $0)) }
        let sorted = keyed.sorted { a, b in
            if a.duration != b.duration { return longestFirst ? a.duration > b.duration : a.duration < b.duration }
            return a.session.startedAt > b.session.startedAt
        }
        var grouped: [String: [WorkSession]] = [:]
        for item in sorted {
            let bucket = buckets.first { item.duration >= $0.lowerBound } ?? buckets[buckets.count - 1]
            grouped[bucket.id, default: []].append(item.session)
        }
        let order = longestFirst ? buckets : Array(buckets.reversed())
        return order.compactMap { bucket in
            guard let list = grouped[bucket.id], !list.isEmpty else { return nil }
            return HistorySection(id: bucket.id, title: bucket.title, colorHex: nil, sessions: list)
        }
    }

    private static func byLabel(_ sessions: [WorkSession]) -> [HistorySection] {
        var groups: [String: (title: String, hex: String?, sessions: [WorkSession])] = [:]
        for session in sessions {
            let key: String
            let title: String
            let hex: String?
            if let label = session.label {
                key = "label-\(label.uuid.uuidString)"
                title = label.name.isBlank ? "Untitled label" : label.name.trimmed
                hex = label.colorHex
            } else {
                key = "label-none"
                title = "Unlabeled"
                hex = nil
            }
            if groups[key] == nil {
                groups[key] = (title, hex, [])
            }
            groups[key]?.sessions.append(session)
        }
        let sortedKeys = groups.keys.sorted { a, b in
            if a == "label-none" { return false }
            if b == "label-none" { return true }
            let ta = groups[a]?.title ?? "", tb = groups[b]?.title ?? ""
            let order = ta.localizedCaseInsensitiveCompare(tb)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        return sortedKeys.compactMap { key in
            guard let group = groups[key] else { return nil }
            return HistorySection(id: key, title: group.title, colorHex: group.hex,
                                  sessions: group.sessions.sorted { $0.startedAt > $1.startedAt })
        }
    }

    /// Group title of a session for Focus A–Z: the first segment's focus, else the session title,
    /// else nil ("No focus or title", sorted last).
    static func focusTitle(of session: WorkSession) -> String? {
        if let focus = session.sortedSegments.first(where: { ModelLiveness.isLive($0) })?.focus, !focus.isBlank {
            return focus.trimmed
        }
        return session.title.isBlank ? nil : session.title.trimmed
    }

    private static func byFocus(_ sessions: [WorkSession]) -> [HistorySection] {
        let noneKey = "focus-none"
        var groups: [String: (title: String, sessions: [WorkSession])] = [:]
        for session in sessions {
            let title = focusTitle(of: session)
            // Case- and diacritic-insensitive key so "Bug fixing" and "bug fixing" share a section.
            let key = title.map { "focus-" + $0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                         locale: .current) } ?? noneKey
            if groups[key] == nil {
                groups[key] = (title ?? "No focus or title", [])
            }
            groups[key]?.sessions.append(session)
        }
        let sortedKeys = groups.keys.sorted { a, b in
            if a == noneKey { return false }
            if b == noneKey { return true }
            let ta = groups[a]?.title ?? "", tb = groups[b]?.title ?? ""
            let order = ta.localizedCaseInsensitiveCompare(tb)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        return sortedKeys.compactMap { key in
            guard let group = groups[key] else { return nil }
            return HistorySection(id: key, title: group.title, colorHex: nil,
                                  sessions: group.sessions.sorted { $0.startedAt > $1.startedAt })
        }
    }
}
