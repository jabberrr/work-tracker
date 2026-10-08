import SwiftData
import SwiftUI

/// The "Today" page of the main window: the start form when idle, the live instrument while a session runs.
@MainActor
struct LiveSessionView: View {
    @Environment(SessionEngine.self) private var engine
    @Environment(\.theme) private var theme

    init() {}

    var body: some View {
        Group {
            if let session = engine.activeSession, ModelLiveness.isLive(session) {
                LiveActivePane(session: session, onDiscard: discardActiveSession)
                    .id(session.persistentModelID)
                    .transition(.opacity)
            } else {
                LiveIdlePane()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
    }

    /// `engine.discard()` clears `activeSession` right away (this page switches to the idle pane) and deletes the
    /// session on the next main-actor turn, so no view reads it after deletion. No animation: the active pane
    /// must not linger in a transition while its model goes away.
    private func discardActiveSession() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = engine.discard()
        }
    }
}
