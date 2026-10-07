import AppKit
import SwiftData
import SwiftUI

/// Month/week groups of learning entries (lazy, so thousands of points stay cheap).
struct LearningPageTimeline: View {
    @Environment(\.theme) private var theme
    let groups: [LearningPageGroup]
    /// Tag currently shown (hidden from each row's chips).
    let focusedTagID: UUID?
    let showsContext: Bool

    var body: some View {
        LazyVStack(alignment: .leading, spacing: theme.spacingXL) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: theme.spacingM) {
                    SectionHeader(group.title) {
                        Text("\(group.entries.count)")
                            .monospacedDigit()
                            .accessibilityLabel("\(group.entries.count) entries")
                    }
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        LearningPageRow(
                            entry: entry,
                            focusedTagID: focusedTagID,
                            showsContext: showsContext && isFirstOfSession(entry, at: index, in: group.entries)
                        )
                    }
                }
            }
        }
    }

    /// Context (the session's "What I learned" text) is shown once per session within a group.
    private func isFirstOfSession(_ entry: LearningPageEntry, at index: Int, in entries: [LearningPageEntry]) -> Bool {
        guard let session = entry.session else { return false }
        let id = session.persistentModelID
        return !entries[..<index].contains { $0.session?.persistentModelID == id }
    }
}

/// One learning point (or a session's free-text learning) on the timeline.
@MainActor
struct LearningPageRow: View {
    @Environment(\.theme) private var theme
    @Environment(WindowRouter.self) private var router
    let entry: LearningPageEntry
    let focusedTagID: UUID?
    let showsContext: Bool

    @State private var isExpanded = false
    @State private var isHovering = false

    private static let collapsedLineLimit = 6

    private var text: String {
        switch entry.kind {
        case .point(let point): return point.text.trimmed
        case .reflection(let session): return session.learningText.trimmed
        }
    }

    /// Heuristic: long enough that 6 lines might truncate.
    private var isLong: Bool {
        text.count > 420 || text.filter { $0 == "\n" }.count >= Self.collapsedLineLimit
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingL) {
            Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .frame(width: 52 * theme.textScale, alignment: .leading)
                .help(entry.date.formatted(date: .complete, time: .shortened))

            VStack(alignment: .leading, spacing: theme.spacingXS + 2) {
                mainText
                metaLine
                if showsContext, let context = contextText {
                    contextQuote(context)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, theme.spacingXS)
        .padding(.horizontal, theme.spacingS)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                .fill(isHovering ? theme.textPrimary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    @ViewBuilder
    private var mainText: some View {
        switch entry.kind {
        case .point:
            Text(text)
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .reflection:
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS + 2) {
                Image(systemName: "quote.opening")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(theme.bodyFont)
                    .italic()
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Session learning: \(text)")
        }
        if isLong {
            Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                .buttonStyle(.plain)
                .font(theme.captionFont)
                .foregroundStyle(theme.accent)
        }
    }

    private var otherTags: [WorkTag] {
        guard let point = entry.point else { return [] }
        return point.tagList
            .filter { $0.uuid != focusedTagID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var metaLine: some View {
        FlowLayout(spacing: theme.spacingS, lineSpacing: theme.spacingXS) {
            if let point = entry.point, (1...5).contains(point.mastery) {
                LearningPageMasteryDots(rating: point.mastery)
            }
            if case .reflection = entry.kind {
                Text("Session notes")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
            if let session = entry.session {
                Button {
                    router.showSession(session)
                } label: {
                    HStack(spacing: 2) {
                        Text(session.displayTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .font(theme.captionFont)
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open “\(session.displayTitle)” in History")
                .accessibilityLabel("Open session \(session.displayTitle)")
            }
            ForEach(otherTags) { tag in
                TagChip(tag: tag)
            }
        }
    }

    private var contextText: String? {
        guard case .point = entry.kind, let session = entry.session else { return nil }
        return session.learningText.nilIfBlank
    }

    private func contextQuote(_ context: String) -> some View {
        HStack(alignment: .top, spacing: theme.spacingS) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 2)
                .accessibilityHidden(true)
            Text(context)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(context)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session context: \(context)")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let session = entry.session {
            Button("Open Session") { router.showSession(session) }
        }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Five small circles, filled up to the rating (accent) — read-only mastery display.
struct LearningPageMasteryDots: View {
    @Environment(\.theme) private var theme
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { level in
                Image(systemName: level <= rating ? "circle.fill" : "circle")
                    .font(.system(size: 6 * theme.textScale))
                    .foregroundStyle(level <= rating ? theme.accent : theme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mastery \(rating) of 5")
        .help("Mastery \(rating) of 5")
    }
}
