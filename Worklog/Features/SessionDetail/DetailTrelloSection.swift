import SwiftData
import SwiftUI

/// Trello card activity logged during the session, oldest first; renders nothing when there is none. Clicking a row
/// opens the card in the browser. Context menu (and the row's ⋯ menu): Open in Trello, Copy, Remove from Session.
@MainActor
struct DetailTrelloSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    private let session: WorkSession

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let activities = ModelLiveness.isLive(session) ? ModelLiveness.live(session.sortedTrelloActivities) : []
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                SectionHeader("Trello", systemImage: "list.bullet.rectangle") {
                    Text("\(activities.count)")
                        .monospacedDigit()
                        .accessibilityLabel("\(activities.count) Trello \(activities.count == 1 ? "entry" : "entries")")
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activities, id: \.uuid) { activity in
                        row(activity)
                    }
                }
            }
        }
    }

    private func row(_ activity: TrelloActivity) -> some View {
        HStack(alignment: .top, spacing: theme.spacingS) {
            rowBody(activity)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Menu {
                menuItems(activity)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, theme.spacingXS)
            .help("More")
            .accessibilityLabel("Trello entry actions")
        }
        .contextMenu { menuItems(activity) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open in Trello") { TrelloActivityActions.open(activity) }
        .accessibilityAction(named: "Remove from Session") { remove(activity) }
    }

    /// A plain button that opens the card when the entry has a card link; just the row otherwise.
    @ViewBuilder
    private func rowBody(_ activity: TrelloActivity) -> some View {
        if ModelLiveness.isLive(activity), activity.cardURL != nil {
            Button {
                TrelloActivityActions.open(activity)
            } label: {
                TrelloActivityRow(activity: activity)
            }
            .buttonStyle(.plain)
            .help("Open in Trello")
        } else {
            TrelloActivityRow(activity: activity)
        }
    }

    @ViewBuilder
    private func menuItems(_ activity: TrelloActivity) -> some View {
        Button("Open in Trello") { TrelloActivityActions.open(activity) }
            .disabled(!ModelLiveness.isLive(activity) || activity.cardURL == nil)
        Button("Copy") { TrelloActivityActions.copy(activity) }
        Divider()
        Button("Remove from Session", role: .destructive) { remove(activity) }
    }

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private func remove(_ activity: TrelloActivity) {
        TrelloActivityActions.remove(activity, in: context)
    }
}
