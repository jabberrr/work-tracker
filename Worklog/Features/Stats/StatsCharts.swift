import Charts
import SwiftUI

// Chart cards for StatsView. Styling per docs/DESIGN.md §10.10:
// label series use the label color, everything else theme.chartColor(i), Unlabeled = textTertiary;
// grid lines separator 0.5 pt, axis labels captionFont/textTertiary, no axis lines; bars radiusS/2, width ~0.6;
// goal RuleMark dashed [4, 3] textSecondary; heights 220 (main) / 180 (secondary).

// MARK: - Shared helpers

private extension Theme {
    func statsSeriesColor(_ series: StatsSeries) -> Color {
        series.colorHex.map { Color(hex: $0) } ?? textTertiary
    }
}

private func statsHoursAxisLabel(_ hours: Double) -> String {
    guard hours.isFinite, hours > 0 else { return "0" }
    if hours < 1 { return "\(Int((hours * 60).rounded()))m" }
    return StatsView.hoursText(hours)
}

private func statsPercent(_ fraction: Double) -> String {
    guard fraction.isFinite else { return "0%" }
    return fraction.formatted(.percent.precision(.fractionLength(0)))
}

/// Card title row used inside the chart cards.
private struct StatsCardTitle<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.spacingS)
            trailing()
        }
    }
}

// MARK: - Time by label

struct StatsTimeChartCard: View {
    @Environment(\.theme) private var theme
    let result: StatsResult
    let allowedBuckets: [StatsBucket]
    @Binding var bucket: StatsBucket
    let dailyGoalHours: Double

    private var unit: Calendar.Component { result.bucket.component }
    /// The calculator's calendar (week start from Settings), so Charts bins weeks exactly like the buckets.
    private var calendar: Calendar {
        StatsCalculator.makeCalendar(weekStartsOnMonday: result.options.weekStartsOnMonday)
    }
    private var showsGoal: Bool { result.bucket == .day && dailyGoalHours > 0 }
    private var maxHours: Double { result.maxBucketSeconds / 3600 }
    private var yUpper: Double {
        let top = max(maxHours, showsGoal ? dailyGoalHours : 0)
        return top > 0 ? top * 1.12 : 1
    }

    private var xLabelFormat: Date.FormatStyle {
        switch result.bucket {
        case .day:
            return result.bucketStarts.count <= 7
                ? .dateTime.weekday(.abbreviated)
                : .dateTime.month(.abbreviated).day()
        case .week:
            return .dateTime.month(.abbreviated).day()
        case .month:
            let years = Set(result.bucketStarts.map { calendar.component(.year, from: $0) })
            return years.count > 1 ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated)
        }
    }

    private var title: String {
        switch result.bucket {
        case .day: "Time per day"
        case .week: "Time per week"
        case .month: "Time per month"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingM) {
                StatsCardTitle(title: title, systemImage: "chart.bar.xaxis") {
                    if allowedBuckets.count > 1 {
                        Picker("Group by", selection: $bucket) {
                            ForEach(allowedBuckets) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help("Group bars by day, week or month")
                        .accessibilityLabel("Group by")
                    }
                }
                chart
                    .frame(height: 220)
                if result.bucket != .day && dailyGoalHours > 0 {
                    Text("Daily goal \(StatsView.hoursText(dailyGoalHours)) is shown when grouping by day.")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var chart: some View {
        let names = result.series.map(\.name)
        let colors = result.series.map { theme.statsSeriesColor($0) }
        let format = xLabelFormat
        let calendar = self.calendar
        return Chart {
            ForEach(result.bars) { bar in
                BarMark(
                    x: .value("Date", bar.bucketStart, unit: unit, calendar: calendar),
                    y: .value("Hours", bar.hours),
                    width: .ratio(0.6)
                )
                .foregroundStyle(by: .value("Label", bar.seriesName))
                .cornerRadius(theme.radiusS / 2)
                .accessibilityLabel("\(bar.bucketStart.formatted(format)), \(bar.seriesName)")
                .accessibilityValue(bar.seconds.formattedShort)
            }
            if showsGoal {
                RuleMark(y: .value("Goal", dailyGoalHours))
                    .foregroundStyle(theme.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Goal \(StatsView.hoursText(dailyGoalHours))")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .accessibilityLabel("Daily goal")
                    .accessibilityValue(StatsView.hoursText(dailyGoalHours))
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartXScale(domain: result.xDomain)
        .chartYScale(domain: 0...yUpper)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(statsHoursAxisLabel(hours))
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(format))
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: theme.spacingS)
        .accessibilityLabel("\(title) by label")
        .accessibilityValue("Total \(result.totalActive.formattedShort)")
    }
}

// MARK: - Label share

struct StatsLabelShareCard: View {
    @Environment(\.theme) private var theme
    let result: StatsResult

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingM) {
                StatsCardTitle(title: "Label share", systemImage: "chart.pie") {
                    Text("time · share · sessions")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
                if result.series.isEmpty {
                    Text("No tracked time in this range.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                } else {
                    HStack(alignment: .center, spacing: theme.spacingL) {
                        donut
                            .frame(width: 160, height: 160)
                        legend
                    }
                }
            }
        }
    }

    private var donut: some View {
        let names = result.series.map(\.name)
        let colors = result.series.map { theme.statsSeriesColor($0) }
        return ZStack {
            Chart(result.series) { series in
                SectorMark(angle: .value("Time", series.seconds), innerRadius: .ratio(0.6), angularInset: 1)
                    .cornerRadius(theme.radiusS / 2)
                    .foregroundStyle(by: .value("Label", series.name))
                    .accessibilityLabel(series.name)
                    .accessibilityValue("\(series.seconds.formattedShort), \(statsPercent(series.fraction))")
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(.hidden)
            .accessibilityLabel("Label share")

            VStack(spacing: 0) {
                Text(result.totalActive.formattedShort)
                    .font(theme.headlineFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                Text("total")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
            .accessibilityHidden(true)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS + 2) {
            ForEach(result.series) { series in
                HStack(spacing: theme.spacingS) {
                    Circle()
                        .fill(theme.statsSeriesColor(series))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(series.name)
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(series.name)
                    Spacer(minLength: theme.spacingS)
                    Text(series.seconds.formattedShort)
                        .font(theme.calloutFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .help("\(series.sessionCount) \(series.sessionCount == 1 ? "session" : "sessions") with this primary label")
                    Text(statsPercent(series.fraction))
                        .font(theme.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: 34, alignment: .trailing)
                    Text("\(series.sessionCount)")
                        .font(theme.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: 22, alignment: .trailing)
                        .accessibilityLabel("\(series.sessionCount) sessions")
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Top tags

struct StatsTopTagsCard: View {
    private enum Metric: String, CaseIterable, Identifiable {
        case time, count
        var id: String { rawValue }
        var title: String { self == .time ? "By time" : "By count" }
    }

    @Environment(\.theme) private var theme
    let result: StatsResult
    @State private var metric: Metric = .time

    /// Stable color per tag: its rank by time.
    private var colorIndex: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, tag) in result.tags.enumerated() { map[tag.tagID] = index }
        return map
    }

    private var values: [StatsTagValue] {
        let sorted: [StatsTagValue]
        switch metric {
        case .time:
            sorted = result.tags.filter { $0.seconds > 0 }
        case .count:
            sorted = result.tags.filter { $0.sessionCount > 0 }
                .sorted { ($0.sessionCount, $0.seconds) > ($1.sessionCount, $1.seconds) }
        }
        return Array(sorted.prefix(StatsCalculator.maxTagCount))
    }

    private func value(of tag: StatsTagValue) -> Double {
        metric == .time ? tag.seconds / 3600 : Double(tag.sessionCount)
    }

    private func valueText(of tag: StatsTagValue) -> String {
        metric == .time
            ? tag.seconds.formattedShort
            : "\(tag.sessionCount) \(tag.sessionCount == 1 ? "session" : "sessions")"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingM) {
                StatsCardTitle(title: "Top tags", systemImage: "number") {
                    Picker("Measure", selection: $metric) {
                        ForEach(Metric.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Measure tags")
                }
                if values.isEmpty {
                    Text("No tagged sessions in this range. Add tags when you start or finish a session.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                } else {
                    chart
                        .frame(height: max(120, CGFloat(values.count) * 24 + 24))
                }
            }
        }
    }

    private var chart: some View {
        let items = values
        let names = items.map(\.name)
        let colors = colorIndex
        return Chart {
            ForEach(items) { tag in
                BarMark(
                    x: .value(metric == .time ? "Hours" : "Sessions", value(of: tag)),
                    y: .value("Tag", tag.name),
                    height: .ratio(0.6)
                )
                .foregroundStyle(theme.chartColor(colors[tag.tagID] ?? 0))
                .cornerRadius(theme.radiusS / 2)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(valueText(of: tag))
                        .font(theme.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityLabel(tag.name)
                .accessibilityValue(valueText(of: tag))
            }
        }
        .chartYScale(domain: names)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .time ? statsHoursAxisLabel(number) : StatsView.decimal(number))
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityLabel(metric == .time ? "Top tags by time" : "Top tags by session count")
    }
}

// MARK: - Heatmap

struct StatsHeatmapCard: View {
    @Environment(\.theme) private var theme
    let result: StatsResult

    private static let hourKeys: [String] = (0..<24).map { String(format: "%02d", $0) }

    /// "9 AM" / "09". Uses a fixed reference day (1 Jan 2001) so DST days can't skip an hour.
    private static func hourName(_ hour: Int) -> String {
        let components = DateComponents(year: 2001, month: 1, day: 1, hour: hour)
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }

    private func fill(for cell: StatsHeatCell) -> Color {
        guard cell.seconds > 0, result.heatMax > 0 else { return theme.separator.opacity(0.35) }
        return theme.accent.opacity(0.08 + 0.92 * min(1, cell.seconds / result.heatMax))
    }

    private var summary: String {
        guard let busiest = result.busiestCell else { return "No tracked time in this range." }
        return "Busiest: \(busiest.weekdayName) around \(Self.hourName(busiest.hour))"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingM) {
                StatsCardTitle(title: "When you work", systemImage: "calendar.day.timeline.left") {
                    Text(summary)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                chart
                    .frame(height: 7 * 22 + 28)
                legend
            }
        }
    }

    private var chart: some View {
        Chart(result.heatCells) { cell in
            RectangleMark(
                x: .value("Hour", Self.hourKeys[cell.hour]),
                y: .value("Weekday", cell.weekdayName),
                width: .ratio(0.9),
                height: .ratio(0.85)
            )
            .foregroundStyle(fill(for: cell))
            .cornerRadius(2)
            .accessibilityLabel("\(cell.weekdayName), \(Self.hourName(cell.hour))")
            .accessibilityValue(cell.seconds > 0 ? cell.seconds.formattedShort : "No time")
        }
        .chartXScale(domain: Self.hourKeys)
        .chartYScale(domain: result.weekdayNames)
        .chartXAxis {
            AxisMarks(values: stride(from: 0, to: 24, by: 3).map { Self.hourKeys[$0] }) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let hour = Int(key) {
                        Text(Self.hourName(hour))
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .accessibilityLabel("When you work, by weekday and hour")
        .accessibilityValue(summary)
    }

    private var legend: some View {
        HStack(spacing: theme.spacingXS) {
            Text("Less")
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0 ? theme.separator.opacity(0.35) : theme.accent.opacity(0.08 + 0.92 * level))
                    .frame(width: 12, height: 10)
            }
            Text("More")
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Darker cells mean more tracked time")
    }
}
