import Charts
import SwiftUI

/// Bars: learning points per week (per month for long spans), accent colored.
/// Dashed line: average self-rated mastery (1–5) of the rated points in each bucket, on a right-hand 1–5 axis.
/// The line is drawn in the bar scale (mastery / 5 × max count) so both share one plot.
struct LearningPageActivityChart: View {
    @Environment(\.theme) private var theme
    let entries: [LearningPageEntry]
    let mondayFirst: Bool

    private struct Bucket: Identifiable {
        let start: Date
        var count: Int
        var masterySum: Int
        var ratedCount: Int
        var id: Date { start }
        var masteryAverage: Double? { ratedCount > 0 ? Double(masterySum) / Double(ratedCount) : nil }
    }

    private struct Model {
        let unit: Calendar.Component
        let buckets: [Bucket]
        let maxCount: Int
        let hasMastery: Bool
        let domain: ClosedRange<Date>
    }

    /// Weeks from the first point to now (months when that's more than two years), with empty buckets kept.
    private var model: Model {
        var calendar = Calendar.current
        calendar.firstWeekday = mondayFirst ? 2 : 1
        let points = entries.compactMap { entry -> (Date, Int)? in
            guard let point = entry.point else { return nil }
            return (entry.date, point.mastery)
        }
        let now = Date.now
        let first = points.map(\.0).min() ?? now
        let last = max(points.map(\.0).max() ?? now, now)
        let weeks = calendar.dateComponents([.weekOfYear], from: first, to: last).weekOfYear ?? 0
        let unit: Calendar.Component = weeks > 104 ? .month : .weekOfYear

        func start(of date: Date) -> Date {
            calendar.dateInterval(of: unit, for: date)?.start ?? calendar.startOfDay(for: date)
        }

        var byStart: [Date: Bucket] = [:]
        for (date, mastery) in points {
            let key = start(of: date)
            var bucket = byStart[key] ?? Bucket(start: key, count: 0, masterySum: 0, ratedCount: 0)
            bucket.count += 1
            if (1...5).contains(mastery) {
                bucket.masterySum += mastery
                bucket.ratedCount += 1
            }
            byStart[key] = bucket
        }

        var buckets: [Bucket] = []
        var cursor = start(of: first)
        let end = start(of: last)
        var guardCount = 0
        while cursor <= end && guardCount < 1_000 {
            guardCount += 1
            buckets.append(byStart[cursor] ?? Bucket(start: cursor, count: 0, masterySum: 0, ratedCount: 0))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let domainEnd = calendar.date(byAdding: unit, value: 1, to: buckets.last?.start ?? end) ?? now
        let domainStart = buckets.first?.start ?? end
        return Model(
            unit: unit,
            buckets: buckets,
            maxCount: max(1, buckets.map(\.count).max() ?? 1),
            hasMastery: buckets.contains { $0.ratedCount > 0 },
            domain: domainStart...max(domainEnd, domainStart.addingTimeInterval(1))
        )
    }

    var body: some View {
        let model = self.model
        Card {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.unit == .month ? "Points per month" : "Points per week")
                        .font(theme.headlineFont)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.hasMastery {
                        HStack(spacing: theme.spacingXS) {
                            Rectangle()
                                .fill(theme.textSecondary)
                                .frame(width: 14, height: 1.5)
                                .accessibilityHidden(true)
                            Text("Average mastery (1–5)")
                        }
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                    }
                }
                chart(model)
                    .frame(height: 140)
            }
        }
    }

    private func countTicks(_ maxCount: Int) -> [Double] {
        let step = max(1, Int((Double(maxCount) / 4).rounded(.up)))
        return stride(from: 0, through: maxCount, by: step).map { Double($0) }
    }

    private func chart(_ model: Model) -> some View {
        let scale = Double(model.maxCount) / 5
        let masteryTicks = (1...5).map { Double($0) * scale }
        let periodFormat: Date.FormatStyle = model.unit == .month
            ? .dateTime.month(.abbreviated).year()
            : .dateTime.month(.abbreviated).day()
        return Chart {
            ForEach(model.buckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.start, unit: model.unit),
                    y: .value("Points", bucket.count),
                    width: .ratio(0.6)
                )
                .foregroundStyle(theme.accent)
                .cornerRadius(theme.radiusS / 2)
                .accessibilityLabel(bucket.start.formatted(periodFormat))
                .accessibilityValue("\(bucket.count) \(bucket.count == 1 ? "point" : "points")")
            }
            if model.hasMastery {
                ForEach(model.buckets.filter { $0.masteryAverage != nil }) { bucket in
                    LineMark(
                        x: .value("Period", bucket.start, unit: model.unit),
                        y: .value("Mastery", (bucket.masteryAverage ?? 0) * scale)
                    )
                    .foregroundStyle(theme.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                    .symbol {
                        Circle()
                            .fill(theme.textSecondary)
                            .frame(width: 5, height: 5)
                    }
                    .accessibilityLabel("Average mastery, \(bucket.start.formatted(periodFormat))")
                    .accessibilityValue((bucket.masteryAverage ?? 0).formatted(.number.precision(.fractionLength(1))))
                }
            }
        }
        .chartXScale(domain: model.domain)
        .chartYScale(domain: 0...(Double(model.maxCount) * 1.08))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(periodFormat))
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: countTicks(model.maxCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text("\(Int(count.rounded()))")
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
            AxisMarks(position: .trailing, values: model.hasMastery ? masteryTicks : []) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self), scale > 0 {
                        Text("\(Int((raw / scale).rounded()))")
                    }
                }
                .font(theme.captionFont)
                .foregroundStyle(theme.textTertiary)
            }
        }
        .accessibilityLabel(model.unit == .month ? "Learning points per month" : "Learning points per week")
        .accessibilityValue("\(entries.filter { $0.point != nil }.count) points in total")
    }
}
