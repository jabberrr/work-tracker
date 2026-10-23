import SwiftData
import SwiftUI

/// Trello card activity logged for the running session, newest first (the latest few; the review sheet and History
/// show all). Shown while `TrelloService` logs this session on this Mac, or when the session already has entries
/// (e.g. logged on another Mac). Status line: "Checking…" / "Checked 1 minute ago", plus the last error, subtly;
/// the header's refresh button checks now.
@MainActor
struct LiveTrelloSection: View {
    @Environment(TrelloService.self) private var trello
    @Environment(\.theme) private var theme
    private let session: WorkSession

    private static let visibleLimit = 8

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let activities = newestFirst
        if trello.isTrackingActiveSession || !activities.isEmpty {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                header(count: activities.count)
                if trello.isTrackingActiveSession {
                    LiveTrelloStatusLine()
                }
                if activities.isEmpty {
                    Text("Card activity appears here.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                } else {
                    list(activities)
                }
            }
        }
    }

    private var newestFirst: [TrelloActivity] {
        guard ModelLiveness.isLive(session) else { return [] }
        return Array(ModelLiveness.live(session.sortedTrelloActivities).reversed())
    }

    private func header(count: Int) -> some View {
        SectionHeader("Trello", systemImage: "list.bullet.rectangle") {
            HStack(spacing: theme.spacingS) {
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .accessibilityLabel("\(count) Trello \(count == 1 ? "entry" : "entries")")
                }
                if trello.isTrackingActiveSession {
                    Button {
                        Task { await trello.checkNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .disabled(trello.isChecking)
                    .accessibilityLabel("Check Trello now")
                    .help("Check now")
                }
            }
        }
    }

    private func list(_ activities: [TrelloActivity]) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        let shown = Array(activities.prefix(Self.visibleLimit))
        let hidden = activities.count - shown.count
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            ForEach(shown, id: \.uuid) { activity in
                row(activity)
            }
            if hidden > 0 {
                Text("\(hidden) earlier \(hidden == 1 ? "entry" : "entries")")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, theme.spacingXS)
            }
        }
        .padding(theme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(theme.separator, lineWidth: theme.borderWidth))
    }

    private func row(_ activity: TrelloActivity) -> some View {
        TrelloActivityRow(activity: activity, isCompact: true)
            .help(ModelLiveness.isLive(activity) ? activity.summary : "")
            .contextMenu {
                Button("Open in Trello") { TrelloActivityActions.open(activity) }
                    .disabled(!ModelLiveness.isLive(activity) || activity.cardURL == nil)
                Button("Copy") { TrelloActivityActions.copy(activity) }
            }
    }
}

/// "Checking…" / "Checked 1 minute ago" / "Checks every minute", re-rendered every 30 s; the last error follows
/// in `textSecondary` with a warning-tinted symbol.
@MainActor
private struct LiveTrelloStatusLine: View {
    @Environment(TrelloService.self) private var trello
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                if trello.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(statusText(now: context.date))
                    .foregroundStyle(theme.textTertiary)
                if let error = trello.lastError {
                    errorLabel(error)
                }
                Spacer(minLength: 0)
            }
            .font(theme.captionFont)
            .accessibilityElement(children: .combine)
        }
    }

    private func errorLabel(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(error)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusText(now: Date) -> String {
        if trello.isChecking {
            return "Checking…"
        }
        guard let last = trello.lastCheckedAt else {
            return "Checks every minute"
        }
        // Never "in 2 seconds" when the clocks disagree slightly.
        let shown = min(last, now)
        if now.timeIntervalSince(shown) < 60 {
            return "Checked just now"
        }
        return "Checked \(shown.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }
}
