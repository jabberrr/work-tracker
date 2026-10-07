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
