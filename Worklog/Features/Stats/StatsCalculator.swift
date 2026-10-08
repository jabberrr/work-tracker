import Foundation
import SwiftData

// MARK: - Options

/// Time range shown on the Stats page.
enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case last7Days, last30Days, last90Days, lastYear, all

    var id: String { rawValue }

    /// Short segmented-control title.
    var title: String {
        switch self {
        case .last7Days: "7D"
        case .last30Days: "30D"
        case .last90Days: "90D"
        case .lastYear: "1Y"
        case .all: "All"
        }
    }

    /// Spoken / tooltip name.
    var longTitle: String {
        switch self {
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .lastYear: "Last 12 months"
        case .all: "All time"
        }
    }

    /// Number of calendar days (including today); nil = everything.
    var dayCount: Int? {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        case .lastYear: 365
        case .all: nil
        }
    }

    /// Bucket used when the user hasn't picked one.
    var defaultBucket: StatsBucket {
        switch self {
        case .last7Days, .last30Days: .day
        case .last90Days: .week
        case .lastYear, .all: .month
        }
    }

    /// Buckets that make sense for this range (no 365 daily bars, no single monthly bar).
    var allowedBuckets: [StatsBucket] {
        switch self {
        case .last7Days: [.day]
        case .last30Days: [.day, .week]
        case .last90Days: [.day, .week, .month]
        case .lastYear: [.week, .month]
        case .all: [.day, .week, .month]
        }
    }
}

/// Granularity of the "time over time" chart.
enum StatsBucket: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

struct StatsOptions: Hashable, Sendable {
    var range: StatsRange
    var bucket: StatsBucket
    var weekStartsOnMonday: Bool
    var dailyGoalHours: Double
}

// MARK: - Snapshot (value copies of the models, safe to hand to a background task)

struct StatsLabelInfo: Hashable, Sendable {
    let uuid: UUID
    let name: String
    let colorHex: String
    let sortIndex: Int
}

struct StatsTagInfo: Hashable, Sendable {
    let uuid: UUID
    let name: String
    let colorHex: String
}

struct StatsProfileInfo: Hashable, Sendable {
    let uuid: UUID
    let name: String
    let colorHex: String
    let sortIndex: Int
}

struct StatsSegmentSnapshot: Sendable {
    let start: Date
    /// Already resolved: segment end, else session end, else the snapshot time.
    let end: Date
    let labelID: UUID?
    /// segment.tags ∪ session.tags (unique).
    let tagIDs: [UUID]
}

struct StatsSessionSnapshot: Sendable {
    let start: Date
    let isActive: Bool
    /// Primary label (nil = Unlabeled).
    let labelID: UUID?
    let pauses: [PauseInterval]
    let activeDuration: TimeInterval
    let segments: [StatsSegmentSnapshot]
    /// Session tags ∪ segment tags.
    let allTagIDs: [UUID]
    /// The session's (live) profile; nil = unassigned.
    let profileID: UUID?
}

struct StatsSnapshot: Sendable {
    let takenAt: Date
    let sessions: [StatsSessionSnapshot]
    let labels: [UUID: StatsLabelInfo]
    let tags: [UUID: StatsTagInfo]
    let profiles: [UUID: StatsProfileInfo]

    static let empty = StatsSnapshot(takenAt: .now, sessions: [], labels: [:], tags: [:], profiles: [:])

    /// Copies everything the calculator needs out of the models. Main actor (touches SwiftData objects); linear in
    /// sessions + segments, no fetching.
    @MainActor
    static func make(from sessions: [WorkSession], now: Date = .now) -> StatsSnapshot {
        var labels: [UUID: StatsLabelInfo] = [:]
        var tags: [UUID: StatsTagInfo] = [:]
        var profiles: [UUID: StatsProfileInfo] = [:]
        var result: [StatsSessionSnapshot] = []
        result.reserveCapacity(sessions.count)

        func registerLabel(_ label: WorkLabel?) -> UUID? {
            guard let label else { return nil }
            if labels[label.uuid] == nil {
                labels[label.uuid] = StatsLabelInfo(uuid: label.uuid, name: label.name,
                                                    colorHex: label.colorHex, sortIndex: label.sortIndex)
            }
            return label.uuid
        }
        func registerTags(_ list: [WorkTag]) -> [UUID] {
            var seen = Set<UUID>()
            var ids: [UUID] = []
            for tag in list where seen.insert(tag.uuid).inserted {
                if tags[tag.uuid] == nil {
                    tags[tag.uuid] = StatsTagInfo(uuid: tag.uuid, name: tag.name, colorHex: tag.colorHex)
                }
                ids.append(tag.uuid)
            }
            return ids
        }
        func registerProfile(_ profile: WorkProfile?) -> UUID? {
            guard let profile = ModelLiveness.live(profile) else { return nil }
            if profiles[profile.uuid] == nil {
                profiles[profile.uuid] = StatsProfileInfo(uuid: profile.uuid, name: profile.displayName,
                                                          colorHex: profile.colorHex, sortIndex: profile.sortIndex)
            }
            return profile.uuid
        }

        for session in sessions where !session.isDeleted {
            let sessionEnd = session.endedAt ?? now
            let sessionTags = session.tagList
            var segments: [StatsSegmentSnapshot] = []
            var allTagIDs = registerTags(sessionTags)
            var allTagSet = Set(allTagIDs)
            for segment in session.sortedSegments where !segment.isDeleted {
                let tagIDs = registerTags(segment.tagList + sessionTags)
                for id in tagIDs where allTagSet.insert(id).inserted { allTagIDs.append(id) }
                segments.append(StatsSegmentSnapshot(
                    start: segment.startedAt,
                    end: max(segment.startedAt, segment.endedAt ?? sessionEnd),
                    labelID: registerLabel(segment.effectiveLabel),
                    tagIDs: tagIDs
                ))
            }
            if segments.isEmpty {
                // Defensive: a session always has ≥ 1 segment, but never lose its time if it doesn't.
                segments.append(StatsSegmentSnapshot(start: session.startedAt, end: max(session.startedAt, sessionEnd),
                                                     labelID: registerLabel(session.label), tagIDs: allTagIDs))
            }
            result.append(StatsSessionSnapshot(
                start: session.startedAt,
                isActive: session.endedAt == nil,
                labelID: registerLabel(session.label),
                pauses: session.pauseIntervals,
                activeDuration: session.activeDuration(at: now),
                segments: segments,
                allTagIDs: allTagIDs,
                profileID: registerProfile(session.profile)
            ))
        }
        return StatsSnapshot(takenAt: now, sessions: result, labels: labels, tags: tags, profiles: profiles)
    }
}

// MARK: - Result

/// One stacked bar piece: active seconds of one label in one bucket.
struct StatsBarValue: Identifiable, Sendable {
    let bucketStart: Date
    /// Start of the next bucket (the chart draws each bar across [bucketStart, bucketEnd)).
    let bucketEnd: Date
    let seriesKey: String
    let seriesName: String
    let seconds: TimeInterval
    /// Active seconds of the series stacked below this one in the same bucket.
    let stackOffsetSeconds: TimeInterval
    var id: String { "\(bucketStart.timeIntervalSinceReferenceDate)|\(seriesKey)" }
    var hours: Double { seconds / 3600 }
    /// Bottom and top of this piece of the stacked bar, in hours.
    var stackStartHours: Double { stackOffsetSeconds / 3600 }
    var stackEndHours: Double { (stackOffsetSeconds + seconds) / 3600 }
}

/// A label series (stacked bars + donut). `colorHex == nil` → Unlabeled (theme color).
struct StatsSeries: Identifiable, Hashable, Sendable {
    let key: String
    /// Unique display name (used as the chart series value).
    let name: String
    let colorHex: String?
    let seconds: TimeInterval
    let fraction: Double
    /// Sessions started in range with this primary label.
    let sessionCount: Int
    var id: String { key }
}

struct StatsTagValue: Identifiable, Hashable, Sendable {
    let tagID: UUID
    /// Unique display name (used as the chart category).
    let name: String
    let colorHex: String
    let seconds: TimeInterval
    let sessionCount: Int
    var id: UUID { tagID }
}

/// Active time of one profile in the window ("By profile"). `profileID == nil` → sessions without a profile.
struct StatsProfileValue: Identifiable, Hashable, Sendable {
    let profileID: UUID?
    /// Unique display name (used as the chart category).
    let name: String
    /// nil → no profile (theme color).
    let colorHex: String?
    let seconds: TimeInterval
    let fraction: Double
    /// Sessions started in range in this profile.
    let sessionCount: Int
    var id: String { profileID?.uuidString ?? StatsCalculator.unassignedProfileKey }
}

struct StatsHeatCell: Identifiable, Hashable, Sendable {
    /// 0…6 in display order (Monday-first or Sunday-first).
    let row: Int
    let weekdayName: String
    let hour: Int
    let seconds: TimeInterval
    var id: Int { row * 24 + hour }
}

struct StatsResult: Sendable {
    let options: StatsOptions
    /// Effective bucket (may be coarser than requested when the range is huge).
    let bucket: StatsBucket
    let window: DateInterval
    let computedAt: Date

    // Tiles
    let totalActive: TimeInterval
    let sessionCount: Int
    let averageSessionLength: TimeInterval
    let longestSession: TimeInterval
    let dayCount: Int
    let activeDays: Int
    let averagePerActiveDay: TimeInterval
    let sessionsPerDay: Double
    let goalDaysMet: Int
    let currentStreak: Int
    let bestStreak: Int

    // Charts
    let bucketStarts: [Date]
    /// [first bucket start, end of last bucket]
    let xDomain: ClosedRange<Date>
    let bars: [StatsBarValue]
    let maxBucketSeconds: TimeInterval
    let series: [StatsSeries]
    let tags: [StatsTagValue]
    let heatCells: [StatsHeatCell]
    let heatMax: TimeInterval
    let weekdayNames: [String]
    /// Time per profile, largest first. Empty unless at least two profiles have time in the window.
    let profileTotals: [StatsProfileValue]

    var isEmpty: Bool { sessionCount == 0 && totalActive < 1 }

    var busiestCell: StatsHeatCell? {
        heatCells.max { $0.seconds < $1.seconds }.flatMap { $0.seconds > 0 ? $0 : nil }
    }
}

// MARK: - Calculator

/// Pure aggregation over a `StatsSnapshot`. Not main-actor bound: StatsView runs it in a detached task.
///
/// Time is always *active* time (pauses excluded) and is split at day/hour boundaries, so a session that crosses
/// midnight counts on both days. Time per label uses segments (effective label); time per tag counts a segment's
/// active time when the tag is on the segment or on its session.
enum StatsCalculator {
    /// A day counts as "active" (streaks, active days) with at least this much tracked time.
    static let activeDayThreshold: TimeInterval = 60
    static let unlabeledKey = "unlabeled"
    static let unlabeledName = "Unlabeled"
    static let unassignedProfileKey = "no-profile"
    static let unassignedProfileName = "No profile"
    static let maxTagCount = 10

    /// Longest window (in days) still drawn with daily bars; longer windows use weeks.
    static let maxDailyBucketDays = 400
    /// Longest window (in days) still drawn with weekly bars; longer windows use months.
    static let maxWeeklyBucketDays = 7 * 260

    /// The bucket actually used for a window of `dayCount` days (coarsened to keep the chart readable).
    static func effectiveBucket(_ requested: StatsBucket, dayCount: Int) -> StatsBucket {
        var bucket = requested
        if bucket == .day && dayCount > maxDailyBucketDays { bucket = .week }
        if bucket == .week && dayCount > maxWeeklyBucketDays { bucket = .month }
        return bucket
    }

    /// The range's buckets minus those the calculator would coarsen for this window length.
    static func allowedBuckets(for range: StatsRange, dayCount: Int) -> [StatsBucket] {
        let honored = range.allowedBuckets.filter { effectiveBucket($0, dayCount: dayCount) == $0 }
        return honored.isEmpty ? [.month] : honored
    }

    static func makeCalendar(weekStartsOnMonday: Bool) -> Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsOnMonday ? 2 : 1
        return calendar
    }

    static func compute(_ snapshot: StatsSnapshot, options: StatsOptions) -> StatsResult {
        let calendar = makeCalendar(weekStartsOnMonday: options.weekStartsOnMonday)
        let now = snapshot.takenAt
        let todayStart = calendar.startOfDay(for: now)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)

        // Window: whole days ending today.
        let windowStart: Date
        if let days = options.range.dayCount {
            windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        } else {
            let earliest = snapshot.sessions.map(\.start).min() ?? now
            windowStart = calendar.startOfDay(for: min(earliest, now))
        }
        let window = DateInterval(safeStart: windowStart, end: windowEnd)
        let dayCount = max(1, calendar.dateComponents([.day], from: windowStart, to: windowEnd).day ?? 1)

        // Effective bucket: keep the chart readable.
        let bucket = effectiveBucket(options.bucket, dayCount: dayCount)

        var bucketCache: [Date: Date] = [:]
        func bucketStart(forDay day: Date) -> Date {
            if let cached = bucketCache[day] { return cached }
            let start: Date
            switch bucket {
            case .day: start = day
            case .week, .month: start = calendar.dateInterval(of: bucket.component, for: day)?.start ?? day
            }
            bucketCache[day] = start
            return start
        }

        // Display order of weekdays (calendar weekday 1 = Sunday).
        let weekdayOrder: [Int] = options.weekStartsOnMonday ? [2, 3, 4, 5, 6, 7, 1] : [1, 2, 3, 4, 5, 6, 7]
        let symbols = calendar.shortWeekdaySymbols
        let weekdayNames: [String] = weekdayOrder.map { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : "\($0)" }
        var rowForWeekday: [Int: Int] = [:]
        for (row, weekday) in weekdayOrder.enumerated() { rowForWeekday[weekday] = row }

        // Accumulators.
        var dayTotals: [Date: TimeInterval] = [:]                    // all data (streaks)
        var bucketSeries: [Date: [String: TimeInterval]] = [:]       // window only
        var seriesTotals: [String: TimeInterval] = [:]
        var tagSeconds: [UUID: TimeInterval] = [:]
        var tagSessions: [UUID: Int] = [:]
        var labelSessions: [String: Int] = [:]
        var profileSeconds: [UUID?: TimeInterval] = [:]
        var profileSessions: [UUID?: Int] = [:]
        var heat = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)

        var sessionCount = 0
        var totalSessionLength: TimeInterval = 0
        var longest: TimeInterval = 0

        for session in snapshot.sessions {
            if window.contains(session.start) && session.start < window.end {
                sessionCount += 1
                totalSessionLength += session.activeDuration
                longest = max(longest, session.activeDuration)
                for tagID in session.allTagIDs { tagSessions[tagID, default: 0] += 1 }
                labelSessions[session.labelID?.uuidString ?? unlabeledKey, default: 0] += 1
                profileSessions[session.profileID, default: 0] += 1
            }

            for segment in session.segments where segment.end > segment.start {
                let seriesKey = segment.labelID?.uuidString ?? unlabeledKey
                var cursor = segment.start
                var guardCount = 0
                while cursor < segment.end && guardCount < 20_000 {
                    guardCount += 1
                    let dayStart = calendar.startOfDay(for: cursor)
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                    let pieceEnd = min(max(nextDay, cursor.addingTimeInterval(1)), segment.end)
                    let piece = DateInterval(safeStart: cursor, end: pieceEnd)
                    let active = max(0, piece.duration - session.pauses.totalOverlap(with: piece, now: now))

                    if active > 0 {
                        dayTotals[dayStart, default: 0] += active
                        if dayStart >= window.start && dayStart < window.end {
                            let key = bucketStart(forDay: dayStart)
                            bucketSeries[key, default: [:]][seriesKey, default: 0] += active
                            seriesTotals[seriesKey, default: 0] += active
                            profileSeconds[session.profileID, default: 0] += active
                            for tagID in segment.tagIDs { tagSeconds[tagID, default: 0] += active }
                            addHeat(piece: piece, pauses: session.pauses, now: now, calendar: calendar,
                                    rowForWeekday: rowForWeekday, into: &heat)
                        }
                    }
                    cursor = pieceEnd
                }
            }
        }

        // Day-level figures.
        var totalActive: TimeInterval = 0
        var activeDays = 0
        var goalDaysMet = 0
        let goalSeconds = max(0, options.dailyGoalHours) * 3600
        for (day, seconds) in dayTotals where day >= window.start && day < window.end {
            totalActive += seconds
            if seconds >= activeDayThreshold { activeDays += 1 }
            if goalSeconds > 0 && seconds >= goalSeconds { goalDaysMet += 1 }
        }
        let streaks = streakLengths(dayTotals: dayTotals, today: todayStart, calendar: calendar)

        // Buckets covering the window (including empty ones).
        var bucketStarts: [Date] = []
        var cursor = bucketStart(forDay: window.start)
        var lastEnd = cursor
        var steps = 0
        while cursor < window.end && steps < 2_000 {
            steps += 1
            bucketStarts.append(cursor)
            let next = calendar.date(byAdding: bucket.component, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
            lastEnd = max(next, cursor.addingTimeInterval(1))
            cursor = lastEnd
        }
        let firstStart = bucketStarts.first ?? window.start
        let xDomain = firstStart...max(lastEnd, firstStart.addingTimeInterval(1))

        // Series (labels), ordered like the label list; Unlabeled last.
        let seriesKeys = seriesTotals.filter { $0.value > 0 }.map(\.key).sorted { a, b in
            let la = UUID(uuidString: a).flatMap { snapshot.labels[$0] }
            let lb = UUID(uuidString: b).flatMap { snapshot.labels[$0] }
            switch (la, lb) {
            case let (x?, y?):
                if x.sortIndex != y.sortIndex { return x.sortIndex < y.sortIndex }
                return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }
        var usedNames = Set<String>()
        var nameForKey: [String: String] = [:]
        let rangeTotal = seriesTotals.values.reduce(0, +)
        var series: [StatsSeries] = []
        for key in seriesKeys {
            let info = UUID(uuidString: key).flatMap { snapshot.labels[$0] }
            let base = info.map { $0.name.trimmed.isEmpty ? "Untitled label" : $0.name.trimmed } ?? unlabeledName
            let name = uniqueName(base, used: &usedNames)
            nameForKey[key] = name
            let seconds = seriesTotals[key] ?? 0
            series.append(StatsSeries(key: key, name: name, colorHex: info?.colorHex, seconds: seconds,
                                      fraction: rangeTotal > 0 ? seconds / rangeTotal : 0,
                                      sessionCount: labelSessions[key] ?? 0))
        }

        var bars: [StatsBarValue] = []
        var maxBucket: TimeInterval = 0
        for start in bucketStarts {
            guard let values = bucketSeries[start] else { continue }
            let end = calendar.date(byAdding: bucket.component, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            var bucketTotal: TimeInterval = 0
            for key in seriesKeys {
                guard let seconds = values[key], seconds > 0, let name = nameForKey[key] else { continue }
                bars.append(StatsBarValue(bucketStart: start, bucketEnd: max(end, start.addingTimeInterval(1)),
                                          seriesKey: key, seriesName: name, seconds: seconds,
                                          stackOffsetSeconds: bucketTotal))
                bucketTotal += seconds
            }
            maxBucket = max(maxBucket, bucketTotal)
        }

        // Tags: union of tags with time or sessions in range.
        var tagIDs = Set(tagSeconds.keys)
        tagIDs.formUnion(tagSessions.keys)
        var usedTagNames = Set<String>()
        let tags: [StatsTagValue] = tagIDs.compactMap { id -> StatsTagValue? in
            guard let info = snapshot.tags[id] else { return nil }
            return StatsTagValue(tagID: id, name: info.name, colorHex: info.colorHex,
                                 seconds: tagSeconds[id] ?? 0, sessionCount: tagSessions[id] ?? 0)
        }
        .sorted { ($0.seconds, $0.sessionCount, $1.name) > ($1.seconds, $1.sessionCount, $0.name) }
        .map { value in
            StatsTagValue(tagID: value.tagID, name: uniqueName("#" + value.name, used: &usedTagNames),
                          colorHex: value.colorHex, seconds: value.seconds, sessionCount: value.sessionCount)
        }

        // Profiles: only meaningful with two or more in the window.
        let profileTotals = makeProfileTotals(seconds: profileSeconds, sessions: profileSessions,
                                              profiles: snapshot.profiles)

        // Heatmap cells.
        var cells: [StatsHeatCell] = []
        cells.reserveCapacity(7 * 24)
        var heatMax: TimeInterval = 0
        for row in 0..<7 {
            for hour in 0..<24 {
                let seconds = heat[row][hour]
                heatMax = max(heatMax, seconds)
                cells.append(StatsHeatCell(row: row, weekdayName: weekdayNames[row], hour: hour, seconds: seconds))
            }
        }

        return StatsResult(
            options: options,
            bucket: bucket,
            window: window,
            computedAt: now,
            totalActive: totalActive,
            sessionCount: sessionCount,
            averageSessionLength: sessionCount > 0 ? totalSessionLength / Double(sessionCount) : 0,
            longestSession: longest,
            dayCount: dayCount,
            activeDays: activeDays,
            averagePerActiveDay: activeDays > 0 ? totalActive / Double(activeDays) : 0,
            sessionsPerDay: Double(sessionCount) / Double(dayCount),
            goalDaysMet: goalDaysMet,
            currentStreak: streaks.current,
            bestStreak: streaks.best,
            bucketStarts: bucketStarts,
            xDomain: xDomain,
            bars: bars,
            maxBucketSeconds: maxBucket,
            series: series,
            tags: tags,
            heatCells: cells,
            heatMax: heatMax,
            weekdayNames: weekdayNames,
            profileTotals: profileTotals
        )
    }

    /// "By profile" values, largest first (ties by profile order, then name); [] with fewer than two profiles.
    private static func makeProfileTotals(seconds: [UUID?: TimeInterval], sessions: [UUID?: Int],
                                          profiles: [UUID: StatsProfileInfo]) -> [StatsProfileValue] {
        let keys = seconds.filter { $0.value > 0 }.map(\.key)
        guard keys.count >= 2 else { return [] }
        let total = keys.reduce(TimeInterval(0)) { $0 + (seconds[$1] ?? 0) }
        let ordered = keys.sorted { a, b in
            let sa = seconds[a] ?? 0
            let sb = seconds[b] ?? 0
            if sa != sb { return sa > sb }
            let ia = a.flatMap { profiles[$0] }
            let ib = b.flatMap { profiles[$0] }
            switch (ia, ib) {
            case let (x?, y?):
                if x.sortIndex != y.sortIndex { return x.sortIndex < y.sortIndex }
                return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
        var usedNames = Set<String>()
        return ordered.map { key in
            let info = key.flatMap { profiles[$0] }
            let value = seconds[key] ?? 0
            return StatsProfileValue(profileID: key,
                                     name: uniqueName(info?.name ?? unassignedProfileName, used: &usedNames),
                                     colorHex: info?.colorHex,
                                     seconds: value,
                                     fraction: total > 0 ? value / total : 0,
                                     sessionCount: sessions[key] ?? 0)
        }
    }

    // MARK: Helpers

    /// Splits a (single-day) piece at hour boundaries and adds its active time to the weekday × hour grid.
    private static func addHeat(piece: DateInterval, pauses: [PauseInterval], now: Date, calendar: Calendar,
                                rowForWeekday: [Int: Int], into heat: inout [[TimeInterval]]) {
        var cursor = piece.start
        var guardCount = 0
        while cursor < piece.end && guardCount < 48 {
            guardCount += 1
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? hourStart.addingTimeInterval(3600)
            let end = min(max(nextHour, cursor.addingTimeInterval(1)), piece.end)
            let part = DateInterval(safeStart: cursor, end: end)
            let active = max(0, part.duration - pauses.totalOverlap(with: part, now: now))
            if active > 0 {
                let weekday = calendar.component(.weekday, from: cursor)
                let hour = calendar.component(.hour, from: cursor)
                if let row = rowForWeekday[weekday], (0..<24).contains(hour) {
                    heat[row][hour] += active
                }
            }
            cursor = end
        }
    }

    /// Current streak (ending today, or yesterday when today has nothing yet) and best streak, in days.
    private static func streakLengths(dayTotals: [Date: TimeInterval], today: Date,
                                      calendar: Calendar) -> (current: Int, best: Int) {
        let activeDays = Set(dayTotals.filter { $0.value >= activeDayThreshold }.map(\.key))
        guard !activeDays.isEmpty else { return (0, 0) }

        func previousDay(_ day: Date) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86_400))
        }

        var current = 0
        var day = activeDays.contains(today) ? today : previousDay(today)
        while activeDays.contains(day) && current < 100_000 {
            current += 1
            day = previousDay(day)
        }

        var best = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous, let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(expected, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return (current, max(best, current))
    }

    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var counter = 2
        while used.contains(name) {
            name = "\(base) (\(counter))"
            counter += 1
        }
        used.insert(name)
        return name
    }
}
