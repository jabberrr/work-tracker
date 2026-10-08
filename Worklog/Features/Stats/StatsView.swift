import Combine
import SwiftData
import SwiftUI

/// Stats page (sidebar ▸ Stats): range picker, summary tiles and Swift Charts.
///
/// All aggregation lives in `StatsCalculator` and runs off the main actor (`StatsModel`). The body only reads the
/// cached `StatsResult`. Recomputation is triggered by: range/bucket/goal/week-start changes, a cheap fingerprint of
/// the queried sessions/labels/tags, `ModelContext.didSave`, imports, and once a minute while a session is running.
///
/// Scoped to the current profile. With more than one profile a header menu switches to "All profiles", which
/// adds a "By profile" card.
@MainActor
struct StatsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Environment(WindowRouter.self) private var router
    @Environment(ProfileStore.self) private var profileStore

    @Query(sort: \WorkSession.startedAt) private var sessions: [WorkSession]
    @Query private var labels: [WorkLabel]
    @Query private var tags: [WorkTag]

    @AppStorage("stats.range") private var range: StatsRange = .last30Days
    @AppStorage("stats.allProfiles") private var prefersAllProfiles = false
    @State private var bucketChoice: StatsBucket?
    @State private var model = StatsModel()
    @State private var dataVersion = 0

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacingXL) {
                header
                content
            }
            .padding(theme.spacingXL)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .themedBackground()
        .onChange(of: dataFingerprint) { dataVersion &+= 1 }
        .onChange(of: range) { bucketChoice = nil }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in dataVersion &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .worklogDataDidImport)) { _ in dataVersion &+= 1 }
        .task(id: engine.isActive) {
            // Keep the running session's time roughly current.
            guard engine.isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                dataVersion &+= 1
            }
        }
        .task(id: refreshKey) {
            if model.result != nil {
                // Debounce bursts (typing in another window, several saves in a row).
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            await model.refresh(sessions: sessions, scope: scope, dataVersion: dataVersion, options: options)
        }
    }

    // MARK: - Options

    /// The profile menu is offered when there is more than one profile (archived ones count: their time shows
    /// under "All profiles").
    private var offersProfileScope: Bool {
        profileStore.profiles.count + profileStore.archivedProfiles.count > 1
    }

    private var showsAllProfiles: Bool { prefersAllProfiles && offersProfileScope }

    private var scope: ProfileScope { showsAllProfiles ? .allProfiles : profileStore.activeScope }

    private var effectiveBucket: StatsBucket {
        if let bucketChoice, range.allowedBuckets.contains(bucketChoice) { return bucketChoice }
        return range.defaultBucket
    }

    private var options: StatsOptions {
        StatsOptions(range: range, bucket: effectiveBucket,
                     weekStartsOnMonday: settings.weekStartsOnMonday,
                     dailyGoalHours: settings.dailyGoalHours)
    }

    private struct RefreshKey: Hashable {
        var options: StatsOptions
        var scope: ProfileScope
        var dataVersion: Int
    }

    private var refreshKey: RefreshKey { RefreshKey(options: options, scope: scope, dataVersion: dataVersion) }

    /// Cheap change detector over the queried models (attribute reads only, no relationship traversal).
    private var dataFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(sessions.count)
        for session in sessions {
            hasher.combine(session.uuid)
            hasher.combine(session.modifiedAt)
            hasher.combine(session.endedAt)
            hasher.combine(session.pauseIntervalsData)
        }
        hasher.combine(labels.count)
        for label in labels {
            hasher.combine(label.uuid)
            hasher.combine(label.name)
            hasher.combine(label.colorHex)
            hasher.combine(label.sortIndex)
        }
        hasher.combine(tags.count)
        for tag in tags {
            hasher.combine(tag.uuid)
            hasher.combine(tag.name)
            hasher.combine(tag.colorHex)
        }
        return hasher.finalize()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingL) {
            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text("Stats")
                    .font(theme.largeTitleFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let result = model.result {
                    Text(windowDescription(result))
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer(minLength: theme.spacingM)
            if model.isComputing && model.result != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating stats")
            }
            if offersProfileScope {
                Picker("Profiles", selection: $prefersAllProfiles) {
                    Text(ModelLiveness.live(profileStore.activeProfile)?.displayName ?? "Current profile")
                        .tag(false)
                    Text("All profiles")
                        .tag(true)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Profiles")
                .accessibilityLabel("Profiles")
            }
            Picker("Range", selection: $range) {
                ForEach(StatsRange.allCases) { item in
                    Text(item.title)
                        .tag(item)
                        .accessibilityLabel(item.longTitle)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Time range")
            .accessibilityLabel("Time range")
        }
    }

    private func windowDescription(_ result: StatsResult) -> String {
        let start = result.window.start
        let end = result.window.end.addingTimeInterval(-1)
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(range.longTitle) · \(start.formatted(style)) – \(end.formatted(style))"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            if result.isEmpty && model.hasAnySession {
                EmptyStateView(
                    title: "Not enough data",
                    systemImage: "chart.bar.xaxis",
                    message: "Finish a session in this range."
                )
                .frame(minHeight: 320)
            } else if result.isEmpty {
                EmptyStateView(
                    title: "Not enough data",
                    systemImage: "chart.bar.xaxis",
                    message: "Finish a session to see stats.",
                    actionTitle: "Start session",
                    action: { router.show(.today) }
                )
                .frame(minHeight: 320)
            } else {
                loadedContent(result)
            }
        } else {
            ProgressView("Calculating…")
                .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    @ViewBuilder
    private func loadedContent(_ result: StatsResult) -> some View {
        tiles(result)

        // The calculator may coarsen the bucket for very long windows ("All" over years): offer only buckets it will
        // honor and show the one it actually used, so the picker never says "Day" over weekly bars.
        StatsTimeChartCard(result: result,
                           allowedBuckets: StatsCalculator.allowedBuckets(for: result.options.range,
                                                                          dayCount: result.dayCount),
                           bucket: Binding(get: { result.bucket }, set: { bucketChoice = $0 }),
                           dailyGoalHours: settings.dailyGoalHours)

        if showsAllProfiles && !result.profileTotals.isEmpty {
            StatsProfileShareCard(result: result)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: theme.spacingL, alignment: .top)],
                  alignment: .leading, spacing: theme.spacingL) {
            StatsLabelShareCard(result: result)
            StatsTopTagsCard(result: result)
        }

        StatsHeatmapCard(result: result)
    }

    private func tiles(_ result: StatsResult) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: theme.spacingM)],
                  alignment: .leading, spacing: theme.spacingM) {
            StatTile(title: "Total", value: result.totalActive.formattedShort, systemImage: "clock",
                     caption: "\(result.activeDays) active \(result.activeDays == 1 ? "day" : "days")")
            StatTile(title: "Sessions", value: "\(result.sessionCount)", systemImage: "number",
                     caption: "\(Self.decimal(result.sessionsPerDay)) per day")
            StatTile(title: "Avg length", value: result.averageSessionLength.formattedShort,
                     systemImage: "timer", caption: "per session")
            StatTile(title: "Longest", value: result.longestSession.formattedShort,
                     systemImage: "arrow.up.to.line", caption: "single session")
            StatTile(title: "Daily average", value: result.averagePerActiveDay.formattedShort,
                     systemImage: "calendar", caption: "on active days")
            StatTile(title: "Streak", value: "\(result.currentStreak) \(result.currentStreak == 1 ? "day" : "days")",
                     systemImage: "flame",
                     caption: "best \(result.bestStreak) \(result.bestStreak == 1 ? "day" : "days")")
            if settings.dailyGoalHours > 0 {
                StatTile(title: "Goal met", value: "\(result.goalDaysMet) of \(result.dayCount)",
                         systemImage: "target",
                         caption: "days with \(Self.hoursText(settings.dailyGoalHours))+")
            }
        }
    }

    /// Nonisolated: also used by chart axis labels and file-scope helpers.
    nonisolated static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "4h", "1.5h".
    nonisolated static func hoursText(_ hours: Double) -> String {
        guard hours.isFinite else { return "0h" }
        if abs(hours - hours.rounded()) < 0.05 { return "\(Int(hours.rounded()))h" }
        return hours.formatted(.number.precision(.fractionLength(1))) + "h"
    }
}
