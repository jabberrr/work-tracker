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

/// One row of the timeline: a learning point, or a session's own notes (its free-text "What I learned" and/or its
/// takeaway). Every session with notes gets one notes entry, whether or not it also has points.
struct LearningPageEntry: Identifiable {
    enum Kind {
        case point(LearningPoint)
        case reflection(WorkSession)
    }

    let id: PersistentIdentifier
    let kind: Kind
    /// Timeline date: the session's start (else the point's createdAt).
    let date: Date
    /// Tie-breaker inside one session (notes come first).
    let order: Int

    var session: WorkSession? {
        switch kind {
        case .point(let point): return ModelLiveness.live(point.session)
        case .reflection(let session): return session
        }
    }

    var point: LearningPoint? {
        if case .point(let point) = kind { return point }
        return nil
    }

    /// Live tags of a point; session notes carry none.
    var tags: [WorkTag] {
        guard let point else { return [] }
        return LearningPageIndex.liveTags(of: point)
    }

    /// Listed under "Untagged": points without a (live) tag, and every session's notes.
    var isUntagged: Bool { tags.isEmpty }

    func hasTag(_ id: UUID) -> Bool {
        tags.contains { $0.uuid == id }
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
/// number of points and sessions.
///
/// Counts and `entries(for:)` share one rule (`LearningPageEntry.isUntagged` / `hasTag`), so a filter's count is
/// always the number of rows it lists. Tags are counted as they are on the point, archived or local to another
/// profile included (tag rows derive from the points, not from the tags the profile offers).
struct LearningPageIndex {
    /// Every matching entry, newest first.
    let entries: [LearningPageEntry]
    let allCount: Int
    let untaggedCount: Int
    let tagRows: [LearningPageTagRow]
    /// Total number of learning points (ignores search).
    let totalPointCount: Int
    /// Total number of sessions with notes (ignores search).
    let totalReflectionCount: Int
    /// Points with at least one tag exist (ignores search).
    let hasTaggedPoints: Bool
    let isSearching: Bool

    /// Nothing at all to show (ignores search).
    var isEmpty: Bool { totalPointCount == 0 && totalReflectionCount == 0 }

    init(points: [LearningPoint], reflectionSessions: [WorkSession], query: String) {
        let terms = SearchService.terms(from: query)
        isSearching = !terms.isEmpty

        var entries: [LearningPageEntry] = []
        var anyTagged = false
        var pointTotal = 0
        var reflectionTotal = 0

        for point in points where ModelLiveness.isLive(point) {
            pointTotal += 1
            if !Self.liveTags(of: point).isEmpty { anyTagged = true }
            guard terms.isEmpty || SearchService.matches(point, terms: terms) else { continue }
            let date = ModelLiveness.live(point.session)?.startedAt ?? point.createdAt
            entries.append(LearningPageEntry(id: point.persistentModelID, kind: .point(point),
                                             date: date, order: point.sortIndex))
        }

        for session in reflectionSessions where ModelLiveness.isLive(session) && Self.hasNotes(session) {
            reflectionTotal += 1
            guard terms.isEmpty || Self.matches(session, terms: terms) else { continue }
            entries.append(LearningPageEntry(id: session.persistentModelID, kind: .reflection(session),
                                             date: session.startedAt, order: Int.min))
        }

        entries.sort { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.order < b.order
        }
        self.entries = entries
        allCount = entries.count
        untaggedCount = entries.filter(\.isUntagged).count
        totalPointCount = pointTotal
        totalReflectionCount = reflectionTotal
        hasTaggedPoints = anyTagged
        tagRows = Self.tagRows(for: entries)
    }

    /// Entries for a filter, newest first. Session notes have no tags: they appear under "All" and "Untagged".
    func entries(for filter: LearningPageFilter) -> [LearningPageEntry] {
        switch filter {
        case .all: return entries
        case .untagged: return entries.filter(\.isUntagged)
        case .tag(let id): return entries.filter { $0.hasTag(id) }
        }
    }

    // MARK: - Rules

    /// A point's live tags (a tag deleted but not yet saved is skipped), once per uuid.
    static func liveTags(of point: LearningPoint) -> [WorkTag] {
        var seen = Set<UUID>()
        return ModelLiveness.live(point.tagList).filter { seen.insert($0.uuid).inserted }
    }

    /// The session's free-text learning, trimmed; nil when blank.
    static func notesText(of session: WorkSession) -> String? { session.learningText.nilIfBlank }

    /// The session's takeaway for next time, trimmed; nil when blank.
    static func takeaway(of session: WorkSession) -> String? { session.overlaySummary.nilIfBlank }

    /// The session has notes of its own: "What I learned" or a takeaway.
    static func hasNotes(_ session: WorkSession) -> Bool {
        notesText(of: session) != nil || takeaway(of: session) != nil
    }

    /// Sessions whose points are listed in `entries` while their notes entry is not (a tag view, or a search that
    /// matched only the points): their notes can be shown as context under their first point.
    static func sessionsNeedingContext(in entries: [LearningPageEntry]) -> Set<PersistentIdentifier> {
        var listedNotes = Set<PersistentIdentifier>()
        var withPoints: [WorkSession] = []
        for entry in entries {
            switch entry.kind {
            case .reflection(let session): listedNotes.insert(session.persistentModelID)
            case .point: if let session = entry.session { withPoints.append(session) }
            }
        }
        return Set(withPoints.filter { !listedNotes.contains($0.persistentModelID) && hasNotes($0) }
            .map(\.persistentModelID))
    }

    /// Points in `scope`. A point whose session is missing (e.g. synced before its session) has no profile; like an
    /// unassigned session it is shown in the home profile. `homeProfileID` is only asked when such a point exists.
    @MainActor
    static func scopedPoints(_ points: [LearningPoint], in scope: ProfileScope,
                             homeProfileID: () -> UUID?) -> [LearningPoint] {
        guard !scope.isAllProfiles else { return points.filter { scope.contains($0) } }
        var homeID: UUID?
        var didResolveHome = false
        return points.filter { point in
            if scope.contains(point) { return true }
            // A session deleted but not yet saved takes its points with it (cascade): not an orphan.
            guard ModelLiveness.isLive(point), point.session == nil else { return false }
            if !didResolveHome {
                homeID = homeProfileID()
                didResolveHome = true
            }
            return homeID == scope.profileID
        }
    }

    private static func tagRows(for entries: [LearningPageEntry]) -> [LearningPageTagRow] {
        var counts: [UUID: (tag: WorkTag, count: Int)] = [:]
        for entry in entries {
            for tag in entry.tags {
                let existing = counts[tag.uuid]
                counts[tag.uuid] = (existing?.tag ?? tag, (existing?.count ?? 0) + 1)
            }
        }
        return counts.values
            .map { LearningPageTagRow(tag: $0.tag, count: $0.count) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.tag.name.localizedCaseInsensitiveCompare(b.tag.name) == .orderedAscending
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

    /// Search over a session's free-text learning, takeaway and title (same folding as SearchService).
    private static func matches(_ session: WorkSession, terms: [String]) -> Bool {
        let haystack = [session.learningText, session.overlaySummary, session.title].map {
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
