import SwiftUI
import SwiftData
import AppKit

/// Menu-style picker of non-archived labels (sorted by sortIndex) with color dot + symbol; optional "None".
/// Shows the current selection even if archived.
///
/// A selection that was deleted (or merged away) while the caller still holds it is treated as nil:
/// it is never read, never offered, and nil is written back to the binding (on appear and whenever
/// the label list changes).
///
/// Native pop-up button (full keyboard support, type-to-select). Its title shows on the left like any
/// macOS picker; add `.labelsHidden()` when the context already says what it is.
@MainActor
struct LabelPicker: View {
    @Query(sort: \WorkLabel.sortIndex) private var allLabels: [WorkLabel]
    @Binding private var selection: WorkLabel?
    private let includeNone: Bool
    private let title: String

    init(selection: Binding<WorkLabel?>, includeNone: Bool = true, title: String = "Label") {
        self._selection = selection
        self.includeNone = includeNone
        self.title = title
    }

    /// The selection when it still exists; nil when it was deleted.
    private var liveSelection: WorkLabel? { ModelLiveness.live(selection) }

    /// Live labels (the query can briefly include deleted-but-unsaved ones).
    private var liveLabels: [WorkLabel] { ModelLiveness.live(allLabels) }

    /// Active labels, plus the current selection when it is archived (so the button can display it).
    private var options: [WorkLabel] {
        var list = liveLabels.filter { !$0.isArchived }
        if let current = liveSelection,
           !list.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            list.append(current)
        }
        return list
    }

    /// Picker binding that never hands a deleted model to the menu.
    private var safeSelection: Binding<WorkLabel?> {
        Binding(
            get: { ModelLiveness.live(selection) },
            set: { selection = $0 }
        )
    }

    var body: some View {
        let items = options
        let current = liveSelection
        Picker(selection: safeSelection) {
            if includeNone || current == nil {
                Text(includeNone ? "None" : "Choose a label")
                    .tag(Optional<WorkLabel>.none)
            }
            if includeNone && !items.isEmpty {
                Divider()
            }
            ForEach(items) { label in
                Label {
                    Text(label.isArchived ? "\(label.name) (archived)" : label.name)
                } icon: {
                    Image(nsImage: LabelMenuIcon.image(symbol: label.symbolName, hex: label.colorHex))
                        .renderingMode(.original)
                }
                .tag(Optional(label))
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
        .accessibilityValue(current?.name ?? "None")
        .onAppear(perform: dropDeletedSelection)
        .onChange(of: liveLabels.map(\.persistentModelID)) { _, _ in
            dropDeletedSelection()
        }
    }

    /// Writes nil back when the bound label no longer exists.
    private func dropDeletedSelection() {
        if let current = selection, !ModelLiveness.isLive(current) {
            selection = nil
        }
    }
}

/// (Extra) Non-template NSImages of a label's SF Symbol drawn in the label color, for native menus
/// (NSMenu renders SwiftUI `Image(systemName:)` as monochrome templates). Use in any `Menu`/`Picker`:
/// `Image(nsImage: LabelMenuIcon.image(symbol: label.symbolName, hex: label.colorHex))`.
/// Call from the main thread (views).
@MainActor
enum LabelMenuIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, hex: String, pointSize: CGFloat = 12) -> NSImage {
        let key = "\(symbol)|\(hex)|\(pointSize)"
        if let cached = cache[key] { return cached }

        let color = NSColor(Color(hex: hex))
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let result: NSImage
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
           let tinted = base.withSymbolConfiguration(config) {
            result = tinted
        } else {
            result = dot(color: color, diameter: pointSize * 0.75)
        }
        result.isTemplate = false
        cache[key] = result
        return result
    }

    /// A plain filled circle (fallback, or for tag menus).
    static func dot(color: NSColor, diameter: CGFloat = 9) -> NSImage {
        let size = NSSize(width: diameter + 2, height: diameter + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
