import SwiftUI
import SwiftData

/// Read-only FlowLayout of TagChip. Renders nothing when `tags` is empty.
/// Deleted tags (still referenced by a stale array) are skipped.
@MainActor
struct TagChipsRow: View {
    private let tags: [WorkTag]

    init(tags: [WorkTag]) {
        self.tags = tags
    }

    var body: some View {
        let live = ModelLiveness.live(tags)
        if !live.isEmpty {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(live) { tag in
                    TagChip(tag: tag)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: " + live.map { $0.name }.joined(separator: ", "))
        }
    }
}

/// One line of TagChip that never wraps: as many chips as fit, then "+N" for the rest ("+N" alone when not even
/// one chip fits). Renders nothing when `tags` is empty. Deleted tags are skipped. For tight spots such as the
/// overlay's label cell and the menu bar panel.
@MainActor
struct TagChipsLine: View {
    @Environment(\.theme) private var theme
    private let tags: [WorkTag]

    init(tags: [WorkTag]) {
        self.tags = tags
    }

    var body: some View {
        let live = ModelLiveness.live(tags)
        if !live.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: live.count, through: 0, by: -1)), id: \.self) { shown in
                    line(live, shown: shown)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags: " + live.map { $0.name }.joined(separator: ", "))
        }
    }

    private func line(_ tags: [WorkTag], shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(shown)) { tag in
                TagChip(tag: tag)
            }
            if shown < tags.count {
                Text("+\(tags.count - shown)")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
                    .help(tags.dropFirst(shown).map { $0.name }.joined(separator: ", "))
            }
        }
    }
}
