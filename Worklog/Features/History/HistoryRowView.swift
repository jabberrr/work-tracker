import SwiftUI
import SwiftData

/// One session in the History list: title + active duration, label badge + up to 3 tags, a segment strip
/// (when there is more than one segment) and, while searching, a snippet with the match highlighted.
/// Cheap by design: reads only this session's own properties; the snippet is computed only for visible
/// rows and only while a query is active.
@MainActor
struct HistoryRowView: View {
    @Environment(\.theme) private var theme
    private let session: WorkSession
    private let query: String
    private let showsDate: Bool

    init(session: WorkSession, query: String, showsDate: Bool) {
        self.session = session
        self.query = query
        self.showsDate = showsDate
    }

    var body: some View {
        if !ModelLiveness.isLive(session) {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        let duration = HistoryGrouping.duration(of: session)
        let tags = session.tagList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let segments = session.sortedSegments
        let snippet = query.isBlank ? nil : SearchService.snippet(for: session, query: query)
        let timeText = showsDate
            ? session.startedAt.formatted(date: .abbreviated, time: .omitted)
            : session.startedAt.shortTime

        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                Text(session.displayTitle)
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.displayTitle)
                Spacer(minLength: theme.spacingS)
                Text(timeText)
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(duration.formattedShort)
                    .font(theme.timerCompactFont)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(2)
            }

            ViewThatFits(in: .horizontal) {
                badgeLine(tags: tags, maxTags: 3)
                badgeLine(tags: tags, maxTags: 1)
                badgeLine(tags: tags, maxTags: 0)
            }

            if segments.count > 1 {
                ProportionBar(parts: segments.map { segment in
                    ProportionBar.Part(value: segment.interval().duration,
                                       color: segment.effectiveLabel?.color ?? theme.textTertiary,
                                       label: segment.displayFocus)
                }, height: 3)
                .padding(.top, 2)
            }

            if let snippet {
                snippetText(snippet)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, theme.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(duration: duration, timeText: timeText, snippet: snippet))
    }

    private func badgeLine(tags: [WorkTag], maxTags: Int) -> some View {
        let shown = Array(tags.prefix(maxTags))
        let extra = tags.count - shown.count
        return HStack(spacing: theme.spacingXS) {
            LabelBadge(label: session.label, size: .small)
            ForEach(shown) { tag in
                TagChip(tag: tag)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// Snippet with the first query term highlighted in the accent color.
    private func snippetText(_ snippet: SearchSnippet) -> Text {
        let prefix: Text = Text(Self.fieldName(snippet.field) + ": ").foregroundColor(theme.textTertiary)
        let text: String = snippet.text
        guard let term = SearchService.terms(from: query).first,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else {
            return prefix + Text(text)
        }
        // Typed pieces keep the `Text + Text` chain cheap for the type checker.
        let before: Text = Text(String(text[text.startIndex..<range.lowerBound]))
        let match: Text = Text(String(text[range])).foregroundColor(theme.accent).fontWeight(.semibold)
        let after: Text = Text(String(text[range.upperBound..<text.endIndex]))
        let head: Text = prefix + before
        let tail: Text = match + after
        return head + tail
    }

    static func fieldName(_ field: SearchSnippet.Field) -> String {
        switch field {
        case .title: return "Title"
        case .label: return "Label"
        case .tag: return "Tag"
        case .segmentFocus: return "Focus"
        case .note: return "Note"
        case .learning: return "Learning"
        case .learningPoint: return "Learning point"
        case .attachmentCaption: return "Image"
        }
    }

    private func accessibilitySummary(duration: TimeInterval, timeText: String, snippet: SearchSnippet?) -> String {
        var parts = [session.displayTitle,
                     session.label.map { "Label \($0.name)" } ?? "Unlabeled",
                     DesignSystemDurationSpeech.spoken(duration),
                     timeText]
        let tagNames = session.tagList.map(\.name)
        if !tagNames.isEmpty { parts.append("Tags " + tagNames.joined(separator: ", ")) }
        if let snippet { parts.append("\(Self.fieldName(snippet.field)) match: \(snippet.text)") }
        return parts.joined(separator: ", ")
    }
}

/// "Live session in progress" row at the top of the History list (links to Today).
@MainActor
struct HistoryLiveRow: View {
    @Environment(\.theme) private var theme
    @Environment(SessionEngine.self) private var engine
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.spacingS) {
                LiveDot(isPaused: engine.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.isPaused ? "Live session · Paused" : "Live session")
                        .font(theme.headlineFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    LabelBadge(label: engine.currentLabel, size: .small)
                }
                Spacer(minLength: theme.spacingS)
                timer
                Image(systemName: "chevron.right")
                    .font(theme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, theme.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show session")
        .accessibilityHint("Opens Today.")
    }

    private var timer: some View {
        LiveTicker(isTicking: !engine.isPaused) { date in
            TimerText(engine.elapsed(at: date), style: .compact, isPaused: engine.isPaused)
        }
    }
}

/// Sticky section header: caption, semibold, tertiary (uppercase where the theme wants it); label
/// sections get the label's color dot.
@MainActor
struct HistorySectionHeader: View {
    @Environment(\.theme) private var theme
    private let section: HistorySection

    init(section: HistorySection) {
        self.section = section
    }

    var body: some View {
        HStack(spacing: theme.spacingXS + 2) {
            if let hex = section.colorHex {
                ColorDot(hex: hex, size: 7)
            }
            Text(section.title)
                .font(theme.captionFont.weight(.semibold))
                .foregroundStyle(theme.textTertiary)
                .textCase(theme.sectionHeaderUppercased ? .uppercase : nil)
                .lineLimit(1)
            Spacer(minLength: theme.spacingS)
            Text("\(section.sessions.count)")
                .font(theme.captionFont.monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .accessibilityLabel("\(section.sessions.count) sessions")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
