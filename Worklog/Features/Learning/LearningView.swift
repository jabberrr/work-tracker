import SwiftData
import SwiftUI

/// Learning page (sidebar ▸ Learning): follow how learnings evolve per tag.
///
/// Left: search + "All" / "Untagged" / tags with counts. Right: the selected tag's points per week (+ average
/// mastery), then a chronological timeline grouped by month or week, each point linking to its session.
@MainActor
struct LearningView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    @Query(sort: \LearningPoint.createdAt, order: .reverse) private var points: [LearningPoint]
    /// Sessions with free-text learnings (shown under "All" when the session has no learning points).
    @Query(filter: #Predicate<WorkSession> { $0.learningText != "" }, sort: \WorkSession.startedAt, order: .reverse)
    private var reflectionSessions: [WorkSession]
    @Query private var allTags: [WorkTag]

    @State private var selection: LearningPageFilter? = .all
    @State private var searchText = ""
    @State private var appliedQuery = ""
    @AppStorage("learning.grouping") private var grouping: LearningPageGrouping = .month
    @AppStorage("learning.newestFirst") private var newestFirst = true
    @AppStorage("learning.showContext") private var showsContext = true

    init() {}

    var body: some View {
        let index = LearningPageIndex(points: points, reflectionSessions: reflectionSessions, query: appliedQuery)
        Group {
            if index.totalPointCount == 0 && reflectionSessions.allSatisfy({ $0.learningText.isBlank }) {
                LearningPageEmptyState()
            } else {
                HStack(spacing: 0) {
                    tagColumn(index)
                        .frame(width: 230)
                    Divider()
                    detail(index)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .themedBackground()
        .task(id: searchText) {
            // Debounce typing.
            if searchText.isEmpty {
                appliedQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { appliedQuery = searchText }
        }
    }

    private var currentFilter: LearningPageFilter { selection ?? .all }

    private func tag(for id: UUID) -> WorkTag? {
        allTags.first { $0.uuid == id && !$0.isDeleted }
    }

    // MARK: - Left column

    private func tagColumn(_ index: LearningPageIndex) -> some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Search learnings")
                .padding(.horizontal, theme.spacingM)
                .padding(.top, theme.spacingL)
                .padding(.bottom, theme.spacingS)

            List(selection: $selection) {
                Section {
                    filterRow(title: "All", systemImage: "tray.full", count: index.allCount)
                        .tag(LearningPageFilter.all)
                    filterRow(title: "Untagged", systemImage: "circle.dashed", count: index.untaggedCount)
                        .tag(LearningPageFilter.untagged)
                }
                Section("Tags") {
                    if index.tagRows.isEmpty {
                        Text(index.isSearching ? "No tags match." : "No tagged learnings")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectionDisabled()
                    } else {
                        ForEach(index.tagRows) { row in
                            tagRow(row)
                                .tag(LearningPageFilter.tag(row.tag.uuid))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .themedBackground(.sidebar)
    }

    private func filterRow(title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: theme.spacingS) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: theme.spacingXS)
            countText(count)
        }
        .accessibilityElement(children: .combine)
    }

    private func tagRow(_ row: LearningPageTagRow) -> some View {
        HStack(spacing: theme.spacingS) {
            Image(systemName: "number")
                .foregroundStyle(row.tag.hasCustomColor ? row.tag.color : theme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.tag.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let parent = ModelLiveness.live(row.tag.label) {
                    Text(parent.name)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                } else if row.tag.isArchived {
                    Text("Archived")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer(minLength: theme.spacingXS)
            countText(row.count)
        }
        .help(row.tag.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag \(row.tag.name)")
        .accessibilityValue("\(row.count) learnings")
    }

    private func countText(_ count: Int) -> some View {
        Text("\(count)")
            .font(theme.captionFont)
            .monospacedDigit()
            .foregroundStyle(theme.textTertiary)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ index: LearningPageIndex) -> some View {
        let filter = currentFilter
        let entries = index.entries(for: filter)
        let focusedTag: WorkTag? = {
            if case .tag(let id) = filter { return tag(for: id) }
            return nil
        }()

        if case .tag = filter, focusedTag == nil {
            EmptyStateView(title: "Tag not found", systemImage: "number",
                           message: "This tag was deleted or merged.",
                           actionTitle: "Show all", action: { selection = .all })
        } else if entries.isEmpty && index.isSearching {
            EmptyStateView(title: "No matches", systemImage: "magnifyingglass")
        } else if entries.isEmpty {
            EmptyStateView(title: filter == .untagged ? "No untagged learnings" : "No learnings here",
                           systemImage: "lightbulb",
                           message: filter == .untagged ? "Every learning point has a tag." : nil)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingXL) {
                    detailHeader(filter: filter, tag: focusedTag, entries: entries)
                    if !index.hasTaggedPoints && !index.isSearching {
                        LearningPageTaggingHint()
                    }
                    if entries.contains(where: { $0.point != nil }) {
                        LearningPageActivityChart(entries: entries, mondayFirst: settings.weekStartsOnMonday)
                    }
                    timelineControls
                    LearningPageTimeline(
                        groups: LearningPageIndex.groups(entries, by: grouping,
                                                         mondayFirst: settings.weekStartsOnMonday,
                                                         newestFirst: newestFirst),
                        focusedTagID: focusedTag?.uuid,
                        showsContext: showsContext
                    )
                }
                .padding(theme.spacingXL)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func detailHeader(filter: LearningPageFilter, tag: WorkTag?, entries: [LearningPageEntry]) -> some View {
        let pointCount = entries.filter { $0.point != nil }.count
        let reflectionCount = entries.count - pointCount
        let dates = entries.map(\.date)
        let title: String = {
            switch filter {
            case .all: return "All learnings"
            case .untagged: return "Untagged"
            case .tag: return "#" + (tag?.name ?? "")
            }
        }()

        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
                Text(title)
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if let parent = tag?.label {
                    LabelBadge(label: parent, size: .small)
                }
                Spacer(minLength: theme.spacingS)
                Text("\(pointCount) \(pointCount == 1 ? "point" : "points")")
                    .font(theme.calloutFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
            if let first = dates.min(), let last = dates.max() {
                Text(spanDescription(first: first, last: last, reflections: reflectionCount))
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func spanDescription(first: Date, last: Date, reflections: Int) -> String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        var text = first.isSameDay(as: last)
            ? first.formatted(style)
            : "\(first.formatted(style)) – \(last.formatted(style))"
        if reflections > 0 {
            text += " · \(reflections) \(reflections == 1 ? "session note" : "session notes")"
        }
        return text
    }

    private var timelineControls: some View {
        HStack(spacing: theme.spacingM) {
            Picker("Group by", selection: $grouping) {
                ForEach(LearningPageGrouping.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Group by")
            .accessibilityLabel("Group timeline by")

            Picker("Order", selection: $newestFirst) {
                Text("Newest first").tag(true)
                Text("Oldest first").tag(false)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Order")
            .accessibilityLabel("Timeline order")

            Spacer(minLength: theme.spacingS)

            Toggle("Session context", isOn: $showsContext)
                .toggleStyle(.checkbox)
                .help("Show session context")
        }
        .font(theme.calloutFont)
    }
}

// MARK: - Empty states

/// Whole-pane state when there are no learnings at all, with a short how-to.
@MainActor
private struct LearningPageEmptyState: View {
    @Environment(\.theme) private var theme
    @Environment(WindowRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacingL) {
                EmptyStateView(
                    title: "No learnings yet",
                    systemImage: "lightbulb",
                    message: "Add learning points when a session ends."
                )
                .frame(minHeight: 220)
                LearningPageHowToSteps()
                    .frame(maxWidth: 440)
                Button("Open History") { router.show(.history) }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(theme.spacingXL)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Shown above the timeline while no learning point has a tag.
private struct LearningPageTaggingHint: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                Label("No tagged learnings", systemImage: "number")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                Text("Tag points to follow a topic.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                LearningPageHowToSteps()
            }
        }
    }
}

/// The three steps to tag a learning.
private struct LearningPageHowToSteps: View {
    @Environment(\.theme) private var theme

    private let steps: [String] = [
        "Finish a session, or open one in History.",
        "Under Learnings, add a learning point.",
        "Tag the point to give it a timeline here.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                    Text("\(index + 1).")
                        .font(theme.calloutFont.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                    Text(step)
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How to tag learnings")
    }
}
