import SwiftData
import SwiftUI

/// Trello card activity logged during the session, oldest first; renders nothing when there is none. Clicking a row
/// shows the card under it (one at a time; Open in Trello is in the card box). Context menu (and the row's ⋯ menu):
/// Open in Trello, Copy, Remove from Session.
@MainActor
struct DetailTrelloSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    private let session: WorkSession
    /// The entry whose card is shown (one at a time).
    @State private var expandedID: UUID?

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

    /// The row shows the card under it when clicked (`TrelloActivityDisclosure`, one at a time); ⋯ menu trailing.
    private func row(_ activity: TrelloActivity) -> some View {
        TrelloActivityDisclosure(activity: activity, expandedID: $expandedID, onRemove: { remove(activity) }) {
            Menu {
                TrelloActivityMenuItems(activity: activity, onRemove: { remove(activity) })
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
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open in Trello") { TrelloActivityActions.open(activity) }
        .accessibilityAction(named: "Remove from Session") { remove(activity) }
    }

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private func remove(_ activity: TrelloActivity) {
        TrelloActivityActions.remove(activity, in: context)
    }
}
