import SwiftUI

/// The menu bar extra's label: a status icon, plus the elapsed time while a session is active and
/// `settings.menuBarShowsTimer` is on. The only view that reads `engine.tick` (a 1 s Timer in .common mode,
/// which keeps ticking while menus are open, unlike TimelineView in the status item).
struct MenuBarLabelView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(WindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    init() {}

    var body: some View {
        content
            .onAppear { router.register(openWindow: openWindow) }
    }

    @ViewBuilder
    private var content: some View {
        if engine.isActive && settings.menuBarShowsTimer {
            let elapsed = engine.elapsed(at: engine.tick)
            Text("\(Image(systemName: icon)) \(elapsed.formattedClock)")
                .monospacedDigit()
                .accessibilityLabel(engine.isPaused ? "Worklog, paused" : "Worklog, running")
                .accessibilityValue(DesignSystemDurationSpeech.spoken(elapsed))
        } else {
            Image(systemName: icon)
                .accessibilityLabel(accessibilityStatus)
        }
    }

    private var icon: String {
        if !engine.isActive { return "timer" }
        return engine.isPaused ? "pause.circle" : "record.circle"
    }

    private var accessibilityStatus: String {
        if !engine.isActive { return "Worklog, not tracking" }
        return engine.isPaused ? "Worklog, paused" : "Worklog, running"
    }
}
