import SwiftUI

/// (Extra) Session status glyph that never relies on color alone:
/// running = filled dot in `theme.timerRunning` (or accent) with a slow, subtle "breathing" fade
/// (disabled under Reduce Motion); paused = a small pause glyph in `theme.timerPaused`.
/// Use next to timers in the sidebar status row, menu bar panel, overlay and History's live row.
struct LiveDot: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private let isPaused: Bool
    private let size: CGFloat

    init(isPaused: Bool, size: CGFloat = 8) {
        self.isPaused = isPaused
        self.size = size
    }

    var body: some View {
        Group {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 1.1, weight: .bold))
                    .foregroundStyle(theme.timerPaused)
                    .frame(width: size * 1.4, height: size * 1.4)
            } else {
                Circle()
                    .fill(theme.timerUsesAccent ? theme.timerRunning : theme.accent)
                    .frame(width: size, height: size)
                    .opacity(dimmed ? 0.45 : 1)
                    .frame(width: size * 1.4, height: size * 1.4)
                    .onAppear { startBreathing() }
                    .onChange(of: reduceMotion) { _, _ in startBreathing() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Paused" : "Running")
    }

    private func startBreathing() {
        guard !reduceMotion else {
            dimmed = false
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}
