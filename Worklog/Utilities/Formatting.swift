import Foundation

// MARK: - TimeInterval

extension TimeInterval {
    /// Whole, non-negative seconds (NaN/infinite → 0).
    private var wholeSecondsClamped: Int {
        guard isFinite, self > 0 else { return 0 }
        return Int(self.rounded(.down))
    }

    /// "05:07" when < 1h, "1:05:07" otherwise; negatives → 0.
    var formattedClock: String {
        let total = wholeSecondsClamped
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// "45s" (<1m), "12m" (<1h), "1h 05m", "2h" (zero minutes).
    var formattedShort: String {
        let total = wholeSecondsClamped
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if minutes == 0 { return "\(hours)h" }
        return String(format: "%dh %02dm", hours, minutes)
    }

    /// "1.5h" (one decimal).
    var formattedHoursDecimal: String {
        let hours = (isFinite && self > 0) ? self / 3600 : 0
        return String(format: "%.1fh", hours)
    }
}

// MARK: - Date

extension Date {
    /// Start of this date's day (Calendar.current).
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    /// Start of the following day (Calendar.current; DST-safe).
    var startOfNextDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
    }

    /// [startOfDay, startOfNextDay)
    var dayInterval: DateInterval { DateInterval(safeStart: startOfDay, end: startOfNextDay) }

    var isToday: Bool { Calendar.current.isDateInToday(self) }

    func isSameDay(as other: Date) -> Bool { Calendar.current.isDate(self, inSameDayAs: other) }

    /// "Today", "Yesterday", "Monday, Oct 5" (+ ", 2025" if not current year).
    var relativeDayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: .now)
        if sameYear {
            return formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    /// e.g. "9:41 AM".
    var shortTime: String { formatted(date: .omitted, time: .shortened) }

    /// e.g. "Oct 7, 2026 at 9:41 AM".
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }

    /// Start of the week containing this date (Monday- or Sunday-first), at midnight.
    func startOfWeek(mondayFirst: Bool) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = mondayFirst ? 2 : 1
        return calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? startOfDay
    }
}

// MARK: - DateInterval

extension DateInterval {
    /// Never traps: end is max(start, end).
    init(safeStart start: Date, end: Date) {
        self.init(start: start, end: Swift.max(start, end))
    }
}

// MARK: - String

extension String {
    /// Trimmed of whitespacesAndNewlines.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when empty or whitespace/newlines only.
    var isBlank: Bool { trimmed.isEmpty }

    /// Trimmed text, or nil when blank.
    var nilIfBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
