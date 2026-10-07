import Foundation
import SwiftData

@Model
final class Segment {
    var uuid: UUID = UUID()
    var startedAt: Date = Date()
    /// nil only for the open segment of the active session.
    var endedAt: Date? = nil
    var sortIndex: Int = 0
    /// Short "what I'm focusing on" text.
    @Attribute(.allowsCloudEncryption) var focus: String = ""

    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.segments)
    var label: WorkLabel?
    @Relationship(deleteRule: .nullify, inverse: \WorkTag.segments)
    var tags: [WorkTag]? = []
    var session: WorkSession?
    @Relationship(deleteRule: .nullify, inverse: \Note.segment)
    var notes: [Note]? = []

    init(startedAt: Date = .now, endedAt: Date? = nil, sortIndex: Int = 0, focus: String = "", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sortIndex = sortIndex
        self.focus = focus
    }
}

extension Segment {
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    var effectiveLabel: WorkLabel? { label ?? session?.label }
    var displayFocus: String { focus.isBlank ? (effectiveLabel?.name ?? "Segment") : focus.trimmed }
    func interval(now: Date = .now) -> DateInterval {
        DateInterval(safeStart: startedAt, end: endedAt ?? session?.endedAt ?? now)
    }
    func activeDuration(at now: Date = .now) -> TimeInterval {
        let iv = interval(now: now)
        return max(0, iv.duration - (session?.pauseIntervals.totalOverlap(with: iv, now: now) ?? 0))
    }
    func activeDuration(in window: DateInterval, now: Date = .now) -> TimeInterval {
        guard let clip = interval(now: now).intersection(with: window) else { return 0 }
        return max(0, clip.duration - (session?.pauseIntervals.totalOverlap(with: clip, now: now) ?? 0))
    }
    var sortedNotes: [Note] { (notes ?? []).sorted { $0.createdAt < $1.createdAt } }
}
