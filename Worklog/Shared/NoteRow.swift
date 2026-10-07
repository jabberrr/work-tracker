import SwiftUI
import SwiftData

/// Read-only note row: time (shortTime), text (lineLimit 6, expandable), optional segment focus caption.
///
///     10:42   Text of the note, selectable, up to six lines…
///             ● Refactor parser · Edited          Show more
///
/// Editing (context menu, inline editor) is added by the feature that hosts the row.
struct NoteRow: View {
    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    private let note: Note
    private let showsSegment: Bool

    init(note: Note, showsSegment: Bool = false) {
        self.note = note
        self.showsSegment = showsSegment
    }

    /// Heuristic for "longer than six lines" (SwiftUI can't report truncation directly).
    private var needsExpansion: Bool {
        let text = note.text
        if text.count > 420 { return true }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count > 6
    }

    var body: some View {
        let time = note.createdAt.shortTime
        let expandable = needsExpansion
        let segment = showsSegment ? note.segment : nil

        HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
            Text(time)
                .font(theme.captionFont.monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 54, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text(note.text)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(isExpanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Note at \(time): \(note.text)")

                if segment != nil || note.editedAt != nil || expandable {
                    HStack(spacing: theme.spacingS) {
                        if let segment {
                            HStack(spacing: 4) {
                                ColorDot(hex: segment.effectiveLabel?.colorHex ?? LabelPalette.defaultTagHex, size: 6)
                                Text(segment.displayFocus)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Segment: \(segment.displayFocus)")
                        }
                        if let edited = note.editedAt {
                            Text("Edited")
                                .help("Edited \(edited.shortDateTime)")
                        }
                        Spacer(minLength: 0)
                        if expandable {
                            Button(isExpanded ? "Show less" : "Show more") {
                                isExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accent)
                        }
                    }
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.vertical, theme.spacingXS)
        .contentShape(Rectangle())
    }
}
