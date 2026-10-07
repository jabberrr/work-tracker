import Foundation
import SwiftData

/// What the Learning page's left column selects.
enum LearningPageFilter: Hashable {
    case all
    case untagged
    case tag(UUID)
}

/// How the timeline groups entries.
enum LearningPageGrouping: String, CaseIterable, Identifiable {
    case month, week
    var id: String { rawValue }
    var title: String { self == .month ? "Month" : "Week" }
}

/// One row of the timeline: a learning point, or the free-text "What I learned" of a session that has no points.
struct LearningPageEntry: Identifiable {
    enum Kind {
        case point(LearningPoint)
        case reflection(WorkSession)
    }

    let id: PersistentIdentifier
    let kind: Kind
    /// Timeline date: the session's start (else the point's createdAt).
    let date: Date
    /// Tie-breaker inside one session.
    let order: Int

    var session: WorkSession? {
        switch kind {
        case .point(let point): return point.session
        case .reflection(let session): return session
        }
    }

    var point: LearningPoint? {
        if case .point(let point) = kind { return point }
        return nil
    }
}

/// A tag row in the left column.
struct LearningPageTagRow: Identifiable {
    let tag: WorkTag
    let count: Int
    var id: UUID { tag.uuid }
}

/// A timeline group (month or week).
struct LearningPageGroup: Identifiable {
    let start: Date
    let title: String
    let entries: [LearningPageEntry]
    var id: Date { start }
}

/// Derived, search-filtered view of the learning data. Built from @Query results (no fetching); linear in the
/// number of points.
struct LearningPageIndex {
    /// Every matching entry, newest first.
    let entries: [LearningPageEntry]
    let allCount: Int
    let untaggedCount: Int
    let tagRows: [LearningPageTagRow]
    /// Total number of learning points (ignores search).
    let totalPointCount: Int
    /// Points with at least one tag exist (ignores search).
    let hasTaggedPoints: Bool
    let isSearching: Bool

    init(points: [LearningPoint], reflectionSessions: [WorkSession], query: String) {
        let terms = SearchService.terms(from: query)
        isSearching = !terms.isEmpty

        var entries: [LearningPageEntry] = []
        var untagged = 0
        var counts: [UUID: (tag: WorkTag, count: Int)] = [:]
        var anyTagged = false
        var total = 0

        for point in points where !point.isDeleted {
            total += 1
            let tags = point.tagList
            if !tags.isEmpty { anyTagged = true }
            guard terms.isEmpty || SearchService.matches(point, terms: terms) else { continue }
            entries.append(LearningPageEntry(id: point.persistentModelID, kind: .point(point),
                                             date: point.effectiveDate, order: point.sortIndex))
            if tags.isEmpty {
                untagged += 1
            } else {
                var seen = Set<UUID>()
                for tag in tags where seen.insert(tag.uuid).inserted {
                    if let existing = counts[tag.uuid] {
                        counts[tag.uuid] = (existing.tag, existing.count + 1)
                    } else {
                        counts[tag.uuid] = (tag, 1)
                    }
                }
            }
        }

        for session in reflectionSessions where !session.isDeleted {
            guard !session.learningText.isBlank, (session.learningPoints ?? []).isEmpty else { continue }
            guard terms.isEmpty || Self.matches(session, terms: terms) else { continue }
            entries.append(LearningPageEntry(id: session.persistentModelID, kind: .reflection(session),
                                             date: session.startedAt, order: -1))
        }

        entries.sort { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.order < b.order
        }
        self.entries = entries
        allCount = entries.count
        untaggedCount = untagged
        totalPointCount = total
        hasTaggedPoints = anyTagged
        tagRows = counts.values
            .map { LearningPageTagRow(tag: $0.tag, count: $0.count) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.tag.name.localizedCaseInsensitiveCompare(b.tag.name) == .orderedAscending
            }
    }

    /// Entries for a filter, newest first. Reflections (no tags) only appear under "All".
    func entries(for filter: LearningPageFilter) -> [LearningPageEntry] {
        switch filter {
        case .all:
            return entries
        case .untagged:
            return entries.filter { entry in
                guard let point = entry.point else { return false }
                return point.tagList.isEmpty
            }
        case .tag(let id):
            return entries.filter { entry in
                entry.point?.tagList.contains(where: { $0.uuid == id }) ?? false
            }
        }
    }

    /// Groups entries (already filtered) by month or week, preserving the requested order.
    static func groups(_ entries: [LearningPageEntry], by grouping: LearningPageGrouping,
                       mondayFirst: Bool, newestFirst: Bool) -> [LearningPageGroup] {
        var calendar = Calendar.current
        calendar.firstWeekday = mondayFirst ? 2 : 1
        let ordered = newestFirst ? entries : entries.sortedStable()

        var groups: [LearningPageGroup] = []
        var currentStart: Date?
        var bucket: [LearningPageEntry] = []

        func flush() {
            guard let start = currentStart, !bucket.isEmpty else { return }
            groups.append(LearningPageGroup(start: start, title: title(for: start, grouping: grouping, calendar: calendar),
                                            entries: bucket))
        }

        for entry in ordered {
            let start: Date
            switch grouping {
            case .month: start = calendar.dateInterval(of: .month, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
            case .week: start = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
            }
            if start != currentStart {
                flush()
                currentStart = start
                bucket = []
            }
            bucket.append(entry)
        }
        flush()
        return groups
    }

    private static func title(for start: Date, grouping: LearningPageGrouping, calendar: Calendar) -> String {
        switch grouping {
        case .month:
            return start.formatted(.dateTime.month(.wide).year())
        case .week:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: .now)
            let style: Date.FormatStyle = sameYear
                ? .dateTime.month(.abbreviated).day()
                : .dateTime.month(.abbreviated).day().year()
            return "Week of \(start.formatted(style))"
        }
    }

    /// Search over a session's free-text learning and title (same folding as SearchService).
    private static func matches(_ session: WorkSession, terms: [String]) -> Bool {
        let haystack = [session.learningText, session.title].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        }
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }
}

private extension Array where Element == LearningPageEntry {
    /// Oldest first; inside one session keep the points' own order.
    func sortedStable() -> [LearningPageEntry] {
        sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.order < b.order
        }
    }
}
