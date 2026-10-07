import SwiftUI
import SwiftData

/// Read-only FlowLayout of TagChip. Renders nothing when `tags` is empty.
struct TagChipsRow: View {
    private let tags: [WorkTag]

    init(tags: [WorkTag]) {
        self.tags = tags
    }

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(tags) { tag in
                    TagChip(tag: tag)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: " + tags.map { $0.name }.joined(separator: ", "))
        }
    }
}
