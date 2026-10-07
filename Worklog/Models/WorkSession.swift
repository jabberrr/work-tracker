import Foundation
import SwiftData

@Model
final class WorkSession {
    var uuid: UUID = UUID()
    var title: String = ""
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    /// JSON-encoded `[PauseInterval]`. Use `pauseIntervals`.
    var pauseIntervalsData: Data? = nil
    /// Cached `activeDuration` (seconds) for sorting. Refresh with `recomputeStoredDuration()` after any time edit/stop.
    var storedActiveDuration: Double = 0
    /// Free-text "what I learned".
    var learningText: String = ""
    /// Optional short user-written takeaway for the next session's overlay.
    var overlaySummary: String = ""
    /// Show this session's takeaway in overlay/menu bar of the next session.
    var showInOverlay: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.sessions)
    var label: WorkLabel?
    @Relationship(deleteRule: .nullify, inverse: \WorkTag.sessions)
    var tags: [WorkTag]? = []
    @Relationship(deleteRule: .cascade, inverse: \Segment.session)
    var segments: [Segment]? = []
    @Relationship(deleteRule: .cascade, inverse: \Note.session)
    var notes: [Note]? = []
    @Relationship(deleteRule: .cascade, inverse: \Attachment.session)
    var attachments: [Attachment]? = []
    @Relationship(deleteRule: .cascade, inverse: \LearningPoint.session)
    var learningPoints: [LearningPoint]? = []

    init(startedAt: Date = .now, title: String = "", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.startedAt = startedAt
        self.title = title
        self.createdAt = .now
        self.modifiedAt = .now
    }
}

extension WorkSession {
    var pauseIntervals: [PauseInterval] {
        get {
            guard let data = pauseIntervalsData else { return [] }
            return (try? JSONDecoder().decode([PauseInterval].self, from: data)) ?? []
        }
        set { pauseIntervalsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue)) }
    }

    var isActive: Bool { endedAt == nil }
    var isPaused: Bool {
        guard isActive, let last = pauseIntervals.last else { return false }
        return last.end == nil
    }
    var displayTitle: String { title.isBlank ? "Untitled session" : title.trimmed }

    func wallDuration(at now: Date = .now) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
    func pausedDuration(at now: Date = .now) -> TimeInterval {
        pauseIntervals.totalOverlap(with: DateInterval(safeStart: startedAt, end: endedAt ?? now), now: now)
    }
    /// Wall time minus pauses.
    func activeDuration(at now: Date = .now) -> TimeInterval {
        max(0, wallDuration(at: now) - pausedDuration(at: now))
    }
    /// Active time clipped to `window` (use for per-day stats; handles midnight crossing).
    func activeDuration(in window: DateInterval, now: Date = .now) -> TimeInterval {
        let own = DateInterval(safeStart: startedAt, end: endedAt ?? now)
        guard let clip = own.intersection(with: window) else { return 0 }
        return max(0, clip.duration - pauseIntervals.totalOverlap(with: clip, now: now))
    }
    func recomputeStoredDuration(now: Date = .now) { storedActiveDuration = activeDuration(at: now) }
    func touch() { modifiedAt = .now }

    var sortedSegments: [Segment] {
        (segments ?? []).sorted { ($0.sortIndex, $0.startedAt) < ($1.sortIndex, $1.startedAt) }
    }
    /// The open segment of an active session.
    var currentSegment: Segment? { sortedSegments.last(where: { $0.endedAt == nil }) }
    /// Segment whose [start, end) contains `date`; falls back to first/last.
    func segment(containing date: Date) -> Segment? {
        let segs = sortedSegments
        if let hit = segs.first(where: { $0.startedAt <= date && date < ($0.endedAt ?? .distantFuture) }) { return hit }
        return date < startedAt ? segs.first : segs.last
    }
    var sortedNotes: [Note] { (notes ?? []).sorted { $0.createdAt < $1.createdAt } }
    var sortedAttachments: [Attachment] { (attachments ?? []).sorted { $0.createdAt < $1.createdAt } }
    var sortedLearningPoints: [LearningPoint] {
        (learningPoints ?? []).sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    /// Session tags ∪ segment tags, unique by uuid, sorted by name.
    var allTags: [WorkTag] {
        var seen = Set<UUID>(); var result: [WorkTag] = []
        for t in tagList + (segments ?? []).flatMap({ $0.tagList }) where seen.insert(t.uuid).inserted { result.append(t) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// overlaySummary if non-blank, else learningText if non-blank, else nil.
    var takeawayText: String? {
        if !overlaySummary.isBlank { return overlaySummary.trimmed }
        if !learningText.isBlank { return learningText.trimmed }
        return nil
    }
    /// Latest of startedAt, segment starts, note times, pause ends (for "forgot to stop").
    var lastActivityDate: Date {
        var d = startedAt
        for s in segments ?? [] { d = max(d, s.startedAt) }
        for n in notes ?? [] { d = max(d, n.createdAt) }
        for p in pauseIntervals { d = max(d, p.end ?? p.start) }
        return d
    }
}
