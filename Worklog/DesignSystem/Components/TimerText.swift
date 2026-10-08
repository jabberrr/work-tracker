import SwiftUI

enum TimerTextStyle {
    /// Today page hero (theme.timerHeroFont, ~60–68 pt).
    case hero
    /// Overlay / menu bar panel (theme.timerFont, ~30–34 pt).
    case large
    /// Current-segment timer, cards (theme.timerMediumFont, ~20 pt).
    case medium
    /// Rows, compact overlay, sidebar status (theme.timerCompactFont, ~13 pt).
    case compact
}

/// Pure display (monospaced digits, formattedClock). Caller wraps in TimelineView.
/// One line; takes layout priority 1, shrinks to 70 % and then truncates when its cell is too narrow.
/// Running digits use `theme.timerRunning`; paused digits use `theme.timerPaused`. Pair a paused timer with a visible "Paused" word (color is never the only signal).
struct TimerText: View {
    @Environment(\.theme) private var theme
    private let interval: TimeInterval
    private let style: TimerTextStyle
    private let isPaused: Bool

    init(_ interval: TimeInterval, style: TimerTextStyle = .large, isPaused: Bool = false) {
        self.interval = interval
        self.style = style
        self.isPaused = isPaused
    }

    var body: some View {
        Text(interval.formattedClock)
            .font(font)
            .monospacedDigit()
            .tracking(tracking)
            .foregroundStyle(isPaused ? theme.timerPaused : theme.timerRunning)
            .lineLimit(1)
            // No fixedSize: in a cell too narrow for the digits (compact overlay, sidebar) they shrink a little,
            // then truncate, instead of overflowing. Priority keeps neighbouring text from squeezing them first.
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
            .accessibilityLabel("Elapsed time")
            .accessibilityValue(DesignSystemDurationSpeech.spoken(interval) + (isPaused ? ", paused" : ""))
    }

    private var font: Font {
        switch style {
        case .hero: return theme.timerHeroFont
        case .large: return theme.timerFont
        case .medium: return theme.timerMediumFont
        case .compact: return theme.timerCompactFont
        }
    }

    /// Big digits look better slightly tightened.
    private var tracking: CGFloat {
        switch style {
        case .hero: return -1.5
        case .large: return -0.5
        case .medium, .compact: return 0
        }
    }
}

/// (Extra) Spoken durations for VoiceOver ("1 hour, 5 minutes, 7 seconds").
enum DesignSystemDurationSpeech {
    private static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval.rounded(.down))
        if seconds < 1 { return "0 seconds" }
        return formatter.string(from: seconds) ?? ""
    }
}

#Preview("TimerText") {
    VStack(alignment: .leading, spacing: 12) {
        TimerText(5_207, style: .hero)
        TimerText(5_207, style: .large, isPaused: true)
        TimerText(427, style: .medium)
        TimerText(427, style: .compact)
    }
    .padding(24)
}
