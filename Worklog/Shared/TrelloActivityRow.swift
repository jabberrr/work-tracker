import AppKit
import SwiftData
import SwiftUI

/// Read-only row for one logged Trello entry: time (shortTime), the kind's symbol, the one-line summary and a caption
/// (comment excerpt · board name).
///
///     10:42  →  Moved “Fix login” from Doing to Done
///               Website
///
/// `isCompact` (live list, review sheet): callout font, one line each. Actions (open, copy, remove) are added by the
/// feature that hosts the row, through `TrelloActivityActions`. A deleted entry renders nothing.
@MainActor
struct TrelloActivityRow: View {
    @Environment(\.theme) private var theme
    private let activity: TrelloActivity
    private let isCompact: Bool

    init(activity: TrelloActivity, isCompact: Bool = false) {
        self.activity = activity
        self.isCompact = isCompact
    }

    var body: some View {
        if ModelLiveness.isLive(activity) {
            content
        }
    }

    private var content: some View {
        let time = activity.occurredAt.shortTime
        let summary = activity.summary
        let caption = captionText
        return HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
            Text(time)
                .font(theme.captionFont.monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 54, alignment: .leading)
            Image(systemName: activity.systemImage)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(isCompact ? theme.calloutFont : theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(isCompact ? 1 : 3)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let caption {
                    Text(caption)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(isCompact ? 1 : 2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, isCompact ? 2 : theme.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(summary: summary, time: time, caption: caption))
    }

    /// "“Looks good to me”" (comments and description edits) · board name, or nil.
    private var captionText: String? {
        var parts: [String] = []
        if activity.kind == .commented || activity.kind == .editedDescription, !activity.detail.isBlank {
            parts.append("\u{201C}\(activity.detail.trimmed)\u{201D}")
        }
        if !activity.boardName.isBlank {
            parts.append(activity.boardName.trimmed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func accessibilityText(summary: String, time: String, caption: String?) -> String {
        if let caption {
            return "\(summary), \(caption), at \(time)"
        }
        return "\(summary), at \(time)"
    }
}

/// Open / copy / remove for a logged Trello entry (live list, review sheet, session detail).
@MainActor
enum TrelloActivityActions {
    /// Opens the card in the browser (nothing when the entry has no card link).
    static func open(_ activity: TrelloActivity) {
        guard ModelLiveness.isLive(activity), let url = activity.cardURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// The summary, plus the card link on a second line when there is one.
    static func copy(_ activity: TrelloActivity) {
        guard ModelLiveness.isLive(activity) else { return }
        var text = activity.summary
        if let url = activity.cardURL {
            text += "\n" + url.absoluteString
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Removes the entry from its session and saves (`SessionEditor.deleteTrelloActivity`, like the other child
    /// deletes; `SafeSave`: rolled back and reported on failure).
    static func remove(_ activity: TrelloActivity, in context: ModelContext) {
        SessionEditor.deleteTrelloActivity(activity, in: context)
    }
}
