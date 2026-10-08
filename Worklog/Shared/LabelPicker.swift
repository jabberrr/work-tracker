import SwiftUI
import SwiftData
import AppKit

/// Menu-style picker of the non-archived labels offered in a profile (global + local to `profileID`, by sortIndex)
/// with color dot + symbol; optional "None". `profileID == nil` offers every label (no profile scope).
/// Shows the current selection even when it is archived ("Name (archived)") or not offered in the profile
/// ("Name (Personal)"); other profiles' local labels are never offered otherwise.
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
    private let profileID: UUID?

    init(selection: Binding<WorkLabel?>, includeNone: Bool = true, title: String = "Label", profileID: UUID?) {
        self._selection = selection
        self.includeNone = includeNone
        self.title = title
        self.profileID = profileID
    }

    /// The selection when it still exists; nil when it was deleted.
    private var liveSelection: WorkLabel? { ModelLiveness.live(selection) }

    /// Live labels (the query can briefly include deleted-but-unsaved ones).
    private var liveLabels: [WorkLabel] { ModelLiveness.live(allLabels) }

    /// Offered active labels, plus the current selection when it is archived or not offered (so the button can
    /// display it).
    private func options(in scope: ProfileScope) -> [WorkLabel] {
        var list = liveLabels.filter { !$0.isArchived && scope.offers($0) }
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
        let scope = ProfileScope(profileID: profileID)
        let items = options(in: scope)
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
                    Text(ScopedItemTitle.title(for: label, in: scope))
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

/// Settings-style label picker: "Default label **Work** ⌄" (a `ValuePicker`: value bold in the accent color,
/// popover list). Same options as `LabelPicker`: "None", then the non-archived labels offered in `profileID`
/// (global + local; nil = every label) in sortIndex order, plus the current selection when it is archived or
/// not offered. A selection that was deleted reads as "None" and nil is written back.
///
/// `globalOnly` (e.g. the parent label of a global tag) offers only global labels; a local selection stays listed
/// as "Name (Work)".
@MainActor
struct LabelValuePicker: View {
    @Query(sort: \WorkLabel.sortIndex) private var allLabels: [WorkLabel]
    @Binding private var selection: WorkLabel?
    private let prefix: String
    private let profileID: UUID?
    private let globalOnly: Bool

    init(_ prefix: String, selection: Binding<WorkLabel?>, profileID: UUID?, globalOnly: Bool = false) {
        self.prefix = prefix
        self._selection = selection
        self.profileID = profileID
        self.globalOnly = globalOnly
    }

    private var liveLabels: [WorkLabel] { ModelLiveness.live(allLabels) }

    /// Whether `label` (live) is offered: in the profile scope, and global when `globalOnly`.
    private func isOffered(_ label: WorkLabel, in scope: ProfileScope) -> Bool {
        guard scope.offers(label) else { return false }
        return !globalOnly || ModelLiveness.live(label.profile) == nil
    }

    /// Offered active labels, plus the current selection when it is archived or not offered.
    private func options(in scope: ProfileScope) -> [WorkLabel] {
        var list = liveLabels.filter { !$0.isArchived && isOffered($0, in: scope) }
        if let current = ModelLiveness.live(selection),
           !list.contains(where: { $0.persistentModelID == current.persistentModelID }) {
            list.append(current)
        }
        return list
    }

    /// The picker works on label UUIDs so the popover never holds a model object.
    private var idSelection: Binding<UUID?> {
        Binding(
            get: { ModelLiveness.live(selection)?.uuid },
            set: { id in
                selection = id.flatMap { id in liveLabels.first { $0.uuid == id } }
            }
        )
    }

    var body: some View {
        let scope = ProfileScope(profileID: profileID)
        let items = options(in: scope)
        let names = Dictionary(items.map { ($0.uuid, ScopedItemTitle.title(for: $0, offered: isOffered($0, in: scope))) },
                               uniquingKeysWith: { first, _ in first })
        let ids: [UUID?] = [nil] + items.map { $0.uuid }
        ValuePicker(prefix, selection: idSelection, options: ids,
                    title: { id in id.flatMap { names[$0] } ?? "None" })
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

/// (Extra, round 3) Option titles for scoped label/tag pickers: "Name"; "Name (Personal)" when the item is not
/// offered in the picker's profile (local to another profile); "Name (archived)" when it is archived.
/// Pass live models only (the pickers filter with `ModelLiveness` first).
@MainActor
enum ScopedItemTitle {
    static func title(for label: WorkLabel, in scope: ProfileScope) -> String {
        title(for: label, offered: scope.offers(label))
    }

    /// `offered: false` names the profile that owns the label ("Name (Work)"), if any.
    static func title(for label: WorkLabel, offered: Bool) -> String {
        title(name: label.name, isArchived: label.isArchived,
              owner: offered ? nil : ModelLiveness.live(label.profile))
    }

    static func title(for tag: WorkTag, in scope: ProfileScope) -> String {
        title(name: tag.name, isArchived: tag.isArchived,
              owner: scope.offers(tag) ? nil : ModelLiveness.live(tag.profile))
    }

    /// The name of the profile a not-offered item belongs to, or nil when it is offered (or its profile is gone).
    static func foreignProfileName(of tag: WorkTag, in scope: ProfileScope) -> String? {
        scope.offers(tag) ? nil : ModelLiveness.live(tag.profile)?.displayName
    }

    private static func title(name: String, isArchived: Bool, owner: WorkProfile?) -> String {
        if let owner {
            return "\(name) (\(owner.displayName))"
        }
        return isArchived ? "\(name) (archived)" : name
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
