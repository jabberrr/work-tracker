import SwiftUI

/// (Extra) A thin horizontal bar split into proportional parts on a track — the shared primitive for
/// the live segment strip, the session timeline summary in History rows, label share and goal
/// progress. Parts are drawn in order; zero/negative values are skipped. A 1 pt gap separates parts.
///
///     ProportionBar(parts: segments.map { .init(value: $0.activeDuration(), color: $0.effectiveLabel?.color ?? theme.textTertiary, label: $0.displayFocus) })
///     ProportionBar(parts: [.init(value: today, color: theme.accent, label: "Today")], total: goal)   // goal meter
struct ProportionBar: View {
    struct Part {
        var value: Double
        var color: Color
        var label: String

        init(value: Double, color: Color, label: String) {
            self.value = value
            self.color = color
            self.label = label
        }
    }

    @Environment(\.theme) private var theme
    private let parts: [Part]
    private let total: Double?
    private let height: CGFloat

    /// `total` nil → parts fill the whole bar; otherwise parts are drawn against `total`
    /// (the remainder shows the track; overflow is clipped).
    init(parts: [Part], total: Double? = nil, height: CGFloat = 6) {
        self.parts = parts.filter { $0.value > 0 }
        self.total = total
        self.height = height
    }

    var body: some View {
        let sum = parts.reduce(0) { $0 + $1.value }
        let denominator = max(total ?? sum, 0.000_001)
        GeometryReader { geo in
            let gap: CGFloat = parts.count > 1 ? 1 : 0
            let usable = max(0, geo.size.width - gap * CGFloat(max(parts.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(1, usable * CGFloat(part.value / denominator)))
                        .help(part.label)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(theme.textPrimary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: min(height / 2, theme.radiusS), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(sum: sum))
    }

    private func accessibilitySummary(sum: Double) -> String {
        if let total, total > 0 {
            let pct = Int((min(sum / total, 9.99) * 100).rounded())
            return "\(pct) percent"
        }
        guard sum > 0 else { return "Empty" }
        return parts.map { "\($0.label) \(Int(($0.value / sum * 100).rounded())) percent" }.joined(separator: ", ")
    }
}
