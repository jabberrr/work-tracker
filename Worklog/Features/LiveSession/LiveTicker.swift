import SwiftUI

/// The one "tick while running" view: re-renders `content` once per second while `isTicking`
/// (`.periodic(from:by: 1)`), and renders it once, with the current date, while paused or idle. It keeps the same
/// view identity when ticking starts or stops (a branch between a TimelineView and plain content would reset text
/// fields and forms inside it on pause). Always compute durations from the date passed in (never accumulate).
@MainActor
struct LiveTicker<Content: View>: View {
    private let isTicking: Bool
    private let content: (Date) -> Content

    init(isTicking: Bool, @ViewBuilder content: @escaping (Date) -> Content) {
        self.isTicking = isTicking
        self.content = content
    }

    var body: some View {
        TimelineView(LiveTickSchedule(isTicking: isTicking)) { context in
            // Paused/idle: no timeline entries after the first, so a re-render (engine change) reads the clock.
            content(isTicking ? context.date : Date())
        }
    }
}

/// `.periodic(from: start, by: 1)` while ticking; a single entry (no further updates) while paused.
struct LiveTickSchedule: TimelineSchedule {
    let isTicking: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if isTicking {
            var iterator = PeriodicTimelineSchedule(from: startDate, by: 1)
                .entries(from: startDate, mode: mode)
                .makeIterator()
            return AnyIterator { iterator.next() }
        }
        var delivered = false
        return AnyIterator {
            guard !delivered else { return nil }
            delivered = true
            return startDate
        }
    }
}
