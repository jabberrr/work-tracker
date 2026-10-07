import Foundation

/// A pause inside a session. `end == nil` ⇒ currently paused (only valid on the active session's last interval).
struct PauseInterval: Codable, Hashable {
    var start: Date
    var end: Date?

    init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    var isOpen: Bool { end == nil }

    /// Seconds of this pause inside `window`; an open pause is treated as ending at `now`.
    func overlap(with window: DateInterval, now: Date) -> TimeInterval {
        let s = max(start, window.start)
        let e = min(end ?? now, window.end)
        return max(0, e.timeIntervalSince(s))
    }
}

extension Array where Element == PauseInterval {
    func totalOverlap(with window: DateInterval, now: Date) -> TimeInterval {
        reduce(0) { $0 + $1.overlap(with: window, now: now) }
    }
}
