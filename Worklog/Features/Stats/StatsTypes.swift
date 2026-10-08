import Foundation
import SwiftData

// Value types for the Stats page: options, the snapshot handed to `StatsCalculator` and its result.

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

        for session in sessions where ModelLiveness.isLive(session) {
            let sessionEnd = session.endedAt ?? now
            let sessionTags = session.tagList
            var segments: [StatsSegmentSnapshot] = []
            var allTagIDs = registerTags(sessionTags)
            var allTagSet = Set(allTagIDs)
            for segment in session.sortedSegments where ModelLiveness.isLive(segment) {
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
                profileID: registerProfile(ProfileOps.effectiveProfile(of: session))
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
