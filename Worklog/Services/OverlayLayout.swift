import CoreGraphics
import Foundation

/// One element of the floating overlay. Persisted by rawValue (in `OverlayGridLayout`'s JSON and in the
/// `settings.overlayLayout` reading-order mirror).
enum OverlayElement: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case label, timer, segmentFocus, controls, split, todayTotal, note, takeaway

    var id: String { rawValue }

    /// "Label", "Timer", "Segment focus", "Controls", "Split", "Today’s total", "Quick note", "Takeaway"
    var title: String {
        switch self {
        case .label: "Label"
        case .timer: "Timer"
        case .segmentFocus: "Segment focus"
        case .controls: "Controls"
        case .split: "Split"
        case .todayTotal: "Today\u{2019}s total"
        case .note: "Quick note"
        case .takeaway: "Takeaway"
        }
    }

    /// "tag", "timer", "scope", "playpause", "scissors", "target", "square.and.pencil", "quote.opening"
    var systemImage: String {
        switch self {
        case .label: "tag"
        case .timer: "timer"
        case .segmentFocus: "scope"
        case .controls: "playpause"
        case .split: "scissors"
        case .todayTotal: "target"
        case .note: "square.and.pencil"
        case .takeaway: "quote.opening"
        }
    }

    /// Round-3 ordered list for a fresh install. The grid default is `OverlayGridLayout.defaultLayout`
    /// (= `migrated(from: defaultLayout)`).
    static let defaultLayout: [OverlayElement] = [.label, .timer, .segmentFocus, .controls, .split, .note, .takeaway]

    /// Order used to migrate the legacy `settings.overlayShow…` booleans.
    static let migrationOrder: [OverlayElement] = [.label, .timer, .segmentFocus, .controls, .split, .todayTotal, .note, .takeaway]

    /// Drops unknown raw values and duplicates (first occurrence wins), keeps order.
    static func sanitized(_ rawValues: [String]) -> [OverlayElement] {
        var seen = Set<OverlayElement>()
        var result: [OverlayElement] = []
        for raw in rawValues {
            guard let element = OverlayElement(rawValue: raw), !seen.contains(element) else { continue }
            seen.insert(element)
            result.append(element)
        }
        return result
    }
}

// MARK: - Grid spans

extension OverlayElement {
    /// Columns (of 6) the element takes when added or migrated.
    var defaultSpan: Int {
        switch self {
        case .label: 4
        case .timer, .segmentFocus, .note, .takeaway: 6
        case .controls, .todayTotal: 2
        case .split: 1
        }
    }

    /// Narrowest span (every value fits the compact 204 pt grid).
    var minSpan: Int {
        switch self {
        case .label, .controls, .todayTotal: 2
        case .timer, .segmentFocus, .note, .takeaway: 3
        case .split: 1
        }
    }

    /// true only for `.todayTotal`: added/migrated at the trailing end of its row.
    var prefersTrailing: Bool { self == .todayTotal }

    /// Round-2 "inline" set used only by the list → grid migration: label, controls, split, todayTotal.
    var isInlineInLegacyLayout: Bool {
        switch self {
        case .label, .controls, .split, .todayTotal: true
        case .timer, .segmentFocus, .note, .takeaway: false
        }
    }
}

// MARK: - Placement

/// One element's cell. row 0 = header row; column 0..<columns; span 1...columns; one row high.
struct OverlayPlacement: Codable, Hashable, Identifiable, Sendable {
    /// Encoded as its raw string; an unknown raw value fails decoding.
    var element: OverlayElement
    var row: Int
    var column: Int
    var span: Int

    var id: OverlayElement { element }
    /// `column ..< column + span` (an empty range for a non-positive span, so it never traps).
    var columnRange: Range<Int> { column ..< column + max(0, span) }
    var endColumn: Int { column + span }

    init(element: OverlayElement, row: Int, column: Int, span: Int) {
        self.element = element
        self.row = row
        self.column = column
        self.span = span
    }

    /// Same row and intersecting column ranges.
    func overlaps(_ other: OverlayPlacement) -> Bool {
        row == other.row && columnRange.overlaps(other.columnRange)
    }
}

// MARK: - Direction

enum OverlayGridDirection: CaseIterable, Sendable {
    case left, right, up, down

    /// "Move Left", "Move Right", "Move Up", "Move Down"
    var title: String {
        switch self {
        case .left: "Move Left"
        case .right: "Move Right"
        case .up: "Move Up"
        case .down: "Move Down"
        }
    }
}

// MARK: - Render rows

/// A rendered row: its grid row index and its visible placements (sorted by column, possibly widened).
struct OverlayGridRenderRow: Equatable, Identifiable, Sendable {
    let row: Int
    let placements: [OverlayPlacement]
    var id: Int { row }
}

struct OverlayGridRenderRows: Equatable, Sendable {
    /// Row 0; empty placements when demoted or nothing visible.
    let header: OverlayGridRenderRow
    /// Non-empty rows in order (may include row 0 when demoted).
    let body: [OverlayGridRenderRow]
}

// MARK: - Grid layout

/// The overlay's grid. ALWAYS normalized: no duplicates, spans/columns clamped, no overlaps, header row 0
/// kept (maybe empty), no empty body rows, placements sorted by (row, column). The only ways to build one
/// (init(placements:), Codable, migrated(from:), the "-ing" functions) all normalize.
struct OverlayGridLayout: Codable, Hashable, Sendable {
    static let columns = 6
    static let headerRow = 0
    static let currentFormatVersion = 1

    private(set) var placements: [OverlayPlacement]

    /// Sanitizes and normalizes (ARCHITECTURE §13.2):
    /// 1. drops duplicates (first in input order wins);
    /// 2. clamps span to `max(minSpan, min(span, 6))`, column to `0...(6 − span)`, row to `≥ 0`;
    /// 3. per source row (ascending), sorted by (column, input index), puts each placement in the first "line" it
    ///    overlaps nothing in (else a new line);
    /// 4. row 0's first line is the header, its extra lines the first body rows; other rows' lines follow in order;
    /// 5. drops empty body lines, renumbers (header 0, body 1, 2, …), sorts by (row, column).
    init(placements: [OverlayPlacement]) {
        self.placements = Self.normalized(placements)
    }

    /// No placements.
    static let empty = OverlayGridLayout(placements: [])

    /// Fresh install and "Reset Layout": label(0,0,4), timer(1,0,6), segmentFocus(2,0,6), controls(3,0,2),
    /// split(3,2,1), note(4,0,6), takeaway(5,0,6).
    static let defaultLayout = OverlayGridLayout.migrated(from: OverlayElement.defaultLayout)

    /// Round-3 ordered list → grid. Starts in the header row with cursor 0. An inline element (label, controls,
    /// split, todayTotal) wraps to a new row when `cursor + defaultSpan > 6`, then takes `defaultSpan` at the
    /// cursor. A full-width element starts a new row unless the current row is an empty body row, takes the
    /// whole row, and closes it. Finally a row's last `.todayTotal` moves to the trailing end.
    /// `readingOrder` of the result == `OverlayElement.sanitized(list)`.
    static func migrated(from list: [OverlayElement]) -> OverlayGridLayout {
        let elements = OverlayElement.sanitized(list.map(\.rawValue))
        var result: [OverlayPlacement] = []
        var row = headerRow
        var cursor = 0          // > 0 exactly when the current row holds something
        for element in elements {
            if element.isInlineInLegacyLayout {
                let span = element.defaultSpan
                if cursor + span > columns {
                    row += 1
                    cursor = 0
                }
                result.append(OverlayPlacement(element: element, row: row, column: cursor, span: span))
                cursor += span
            } else {
                if row == headerRow || cursor > 0 {
                    row += 1
                }
                result.append(OverlayPlacement(element: element, row: row, column: 0, span: columns))
                row += 1
                cursor = 0
            }
        }
        // Today's total sat at the trailing end of its inline run in round 3.
        for index in result.indices where result[index].element == .todayTotal {
            let current = result[index]
            let isLastInRow = !result.contains { $0.row == current.row && $0.column > current.column }
            if isLastInRow {
                result[index].column = columns - current.span
            }
        }
        return OverlayGridLayout(placements: result)
    }

    // MARK: Queries

    /// max row + 1, at least 1 (the header row always exists).
    var rowCount: Int { (placements.map(\.row).max() ?? Self.headerRow) + 1 }

    /// Elements in placement order (row, column).
    var readingOrder: [OverlayElement] { placements.map(\.element) }

    var elements: Set<OverlayElement> { Set(placements.map(\.element)) }

    /// `OverlayElement.allCases` not in the grid, in allCases order.
    var hiddenElements: [OverlayElement] { OverlayElement.allCases.filter { !contains($0) } }

    func contains(_ element: OverlayElement) -> Bool {
        placements.contains { $0.element == element }
    }

    func placement(of element: OverlayElement) -> OverlayPlacement? {
        placements.first { $0.element == element }
    }

    /// Sorted by column.
    func placements(inRow row: Int) -> [OverlayPlacement] {
        placements.filter { $0.row == row }.sorted { $0.column < $1.column }
    }

    /// No placement (other than `excluding`) in `row` intersects `columns`. A range outside `0...6` is never free.
    func isFree(row: Int, columns: Range<Int>, excluding: OverlayElement? = nil) -> Bool {
        guard columns.lowerBound >= 0, columns.upperBound <= Self.columns else { return false }
        return !placements.contains {
            $0.row == row && $0.element != excluding && $0.columnRange.overlaps(columns)
        }
    }

    /// First body row (1..<rowCount, top to bottom) with `span` free columns, scanning left→right
    /// (right→left when preferTrailing); none → (rowCount, preferTrailing ? columns - span : 0). Never the header.
    func firstFreeCell(span: Int, preferTrailing: Bool = false) -> (row: Int, column: Int) {
        let span = min(max(span, 1), Self.columns)
        let lastColumn = Self.columns - span
        let candidates: [Int] = preferTrailing ? Array((0...lastColumn).reversed()) : Array(0...lastColumn)
        for row in 1..<max(1, rowCount) {
            for column in candidates where isFree(row: row, columns: column ..< column + span) {
                return (row, column)
            }
        }
        return (rowCount, preferTrailing ? lastColumn : 0)
    }

    /// Largest span `element` can take at its column without overlapping its right neighbour (0 when absent).
    func maxSpan(for element: OverlayElement) -> Int {
        guard let current = placement(of: element) else { return 0 }
        let limit = placements
            .filter { $0.row == current.row && $0.column > current.column }
            .map(\.column)
            .min() ?? Self.columns
        return limit - current.column
    }

    // MARK: Edits (each returns a new normalized layout, or self when the edit doesn't apply)

    /// Adds at `firstFreeCell(span: defaultSpan, preferTrailing: prefersTrailing)`; no-op if present.
    func adding(_ element: OverlayElement) -> OverlayGridLayout {
        guard !contains(element) else { return self }
        let cell = firstFreeCell(span: element.defaultSpan, preferTrailing: element.prefersTrailing)
        let placement = OverlayPlacement(element: element, row: cell.row, column: cell.column, span: element.defaultSpan)
        return OverlayGridLayout(placements: placements + [placement])
    }

    /// Removes the element; its row collapses when it becomes empty (the header row stays).
    func removing(_ element: OverlayElement) -> OverlayGridLayout {
        guard contains(element) else { return self }
        return OverlayGridLayout(placements: placements.filter { $0.element != element })
    }

    /// row in 0...rowCount (rowCount = new trailing row); column clamped to 0...(columns - span). Push-down:
    /// the elements of `row` that overlap the target columns move together into a new row inserted directly below.
    func moving(_ element: OverlayElement, toRow row: Int, column: Int) -> OverlayGridLayout {
        guard let current = placement(of: element) else { return self }
        let target = clampedTarget(current, row: row, column: column)
        var others = placements.filter { $0.element != element }
        if target.row < rowCount {
            let pushed = Set(others.filter { $0.overlaps(target) }.map(\.element))
            if !pushed.isEmpty {
                for index in others.indices {
                    if others[index].row > target.row {
                        others[index].row += 1
                    } else if pushed.contains(others[index].element) {
                        others[index].row = target.row + 1
                    }
                }
            }
        }
        return OverlayGridLayout(placements: others + [target])
    }

    /// Elements `moving(...)` would push down (for the drag ghost). Empty for a free cell or a new row.
    func displaced(byMoving element: OverlayElement, toRow row: Int, column: Int) -> Set<OverlayElement> {
        guard let current = placement(of: element) else { return [] }
        let target = clampedTarget(current, row: row, column: column)
        guard target.row < rowCount else { return [] }
        return Set(placements.filter { $0.element != element && $0.overlaps(target) }.map(\.element))
    }

    /// Clamps `span` to [minSpan, maxSpan(for:)]. Never pushes.
    func resizing(_ element: OverlayElement, toSpan span: Int) -> OverlayGridLayout {
        guard let current = placement(of: element) else { return self }
        let clamped = min(max(span, element.minSpan), maxSpan(for: element))
        guard clamped != current.span else { return self }
        var updated = current
        updated.span = clamped
        return replacing([updated])
    }

    /// ←/→: one free column, else swap with the adjacent neighbour (gaps elsewhere are kept). ↑: `moving` to the
    /// row above (no-op in the header). ↓: `moving` to the row below; when the element is alone in a body row
    /// (so that row collapses), the elements it overlaps in the next row move up into a row of their own above it
    /// instead (the mirror of push-down), so full-width rows swap. No-op when alone in the last row.
    func nudged(_ element: OverlayElement, _ direction: OverlayGridDirection) -> OverlayGridLayout {
        guard let current = placement(of: element) else { return self }
        switch direction {
        case .up:
            guard current.row > Self.headerRow else { return self }
            return moving(element, toRow: current.row - 1, column: current.column)
        case .down:
            let isAloneInBodyRow = current.row != Self.headerRow && placements(inRow: current.row).count == 1
            guard isAloneInBodyRow else {
                return moving(element, toRow: current.row + 1, column: current.column)
            }
            let below = current.row + 1
            guard below < rowCount else { return self }
            var others = placements.filter { $0.element != element }
            var probe = current
            probe.row = below
            let overlapped = Set(others.filter { $0.overlaps(probe) }.map(\.element))
            for index in others.indices
            where others[index].row >= below && !overlapped.contains(others[index].element) {
                others[index].row += 1
            }
            var moved = current
            moved.row = below + 1
            return OverlayGridLayout(placements: others + [moved])
        case .left:
            if current.column > 0,
               isFree(row: current.row, columns: (current.column - 1) ..< current.column, excluding: element) {
                var moved = current
                moved.column -= 1
                return replacing([moved])
            }
            if var neighbour = placements.first(where: {
                $0.row == current.row && $0.element != element && $0.endColumn == current.column
            }) {
                var moved = current
                moved.column = neighbour.column
                neighbour.column = neighbour.column + current.span
                return replacing([moved, neighbour])
            }
            return self
        case .right:
            if current.endColumn < Self.columns,
               isFree(row: current.row, columns: current.endColumn ..< current.endColumn + 1, excluding: element) {
                var moved = current
                moved.column += 1
                return replacing([moved])
            }
            if var neighbour = placements.first(where: {
                $0.row == current.row && $0.element != element && $0.column == current.endColumn
            }) {
                var moved = current
                neighbour.column = current.column
                moved.column = current.column + neighbour.span
                return replacing([moved, neighbour])
            }
            return self
        }
    }

    /// nudged(...) != self
    func canNudge(_ element: OverlayElement, _ direction: OverlayGridDirection) -> Bool {
        nudged(element, direction) != self
    }

    /// resizing(span + delta) != self (false when absent).
    func canResize(_ element: OverlayElement, by delta: Int) -> Bool {
        guard let current = placement(of: element) else { return false }
        return resizing(element, toSpan: current.span + delta) != self
    }

    // MARK: Rendering helper

    /// Visible placements per row. headerInline false (idle): row 0's visible items become the first body row.
    /// Each element in `widening` is expanded over the free columns (among VISIBLE placements) left and right in
    /// its row (processed left to right, so two widened neighbours never overlap).
    func renderRows(isVisible: (OverlayElement) -> Bool, headerInline: Bool,
                    widening: Set<OverlayElement> = []) -> OverlayGridRenderRows {
        var rows: [OverlayGridRenderRow] = []
        for row in 0..<rowCount {
            let visible = placements(inRow: row).filter { isVisible($0.element) }
            var rendered: [OverlayPlacement] = []
            for (index, item) in visible.enumerated() {
                guard widening.contains(item.element) else {
                    rendered.append(item)
                    continue
                }
                let start = rendered.map(\.endColumn).max() ?? 0
                let end = visible[(index + 1)...].map(\.column).min() ?? Self.columns
                var widened = item
                widened.column = min(start, item.column)
                widened.span = max(end, item.endColumn) - widened.column
                rendered.append(widened)
            }
            rows.append(OverlayGridRenderRow(row: row, placements: rendered))
        }
        let headerRow = rows[0]
        let bodyRows = rows.dropFirst().filter { !$0.placements.isEmpty }
        if headerInline {
            return OverlayGridRenderRows(header: headerRow, body: Array(bodyRows))
        }
        let demoted = headerRow.placements.isEmpty ? [] : [headerRow]
        return OverlayGridRenderRows(header: OverlayGridRenderRow(row: Self.headerRow, placements: []),
                                     body: demoted + bodyRows)
    }

    // MARK: Codable
    // {"columns":6,"formatVersion":1,"placements":[{"column":0,"element":"label","row":0,"span":4},…]}

    private enum CodingKeys: String, CodingKey {
        case formatVersion, columns, placements
    }

    /// Skips placements that fail to decode (e.g. an element added by a future version).
    private struct LossyPlacement: Decodable {
        let value: OverlayPlacement?
        init(from decoder: Decoder) throws {
            value = try? OverlayPlacement(from: decoder)
        }
    }

    /// Lenient: unknown elements are skipped, a different `columns` count is rescaled to 6, a higher
    /// `formatVersion` is accepted. Only a missing (or non-array) `placements` throws. Always normalizes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try? container.decodeIfPresent(Int.self, forKey: .formatVersion)   // read, never rejected
        let storedColumns = (try? container.decodeIfPresent(Int.self, forKey: .columns)) ?? Self.columns
        var decoded = try container.decode([LossyPlacement].self, forKey: .placements).compactMap(\.value)
        if storedColumns != Self.columns, storedColumns > 0 {
            for index in decoded.indices {
                decoded[index].column = Self.rescaled(decoded[index].column, from: storedColumns)
                decoded[index].span = max(1, Self.rescaled(decoded[index].span, from: storedColumns))
            }
        }
        self.init(placements: decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(Self.columns, forKey: .columns)
        try container.encode(placements, forKey: .placements)
    }

    // MARK: Private

    /// `Int((Double(value) * 6 / Double(stored)).rounded())`, bounded so absurd stored values can't trap.
    private static func rescaled(_ value: Int, from stored: Int) -> Int {
        let scaled = (Double(value) * Double(columns) / Double(stored)).rounded()
        return Int(min(max(scaled, -1_000_000), 1_000_000))
    }

    /// The element's cell for `moving`/`displaced`: row clamped to 0...rowCount, column to 0...(columns − span).
    private func clampedTarget(_ current: OverlayPlacement, row: Int, column: Int) -> OverlayPlacement {
        let clampedRow = min(max(row, 0), rowCount)
        let clampedColumn = min(max(column, 0), Self.columns - current.span)
        return OverlayPlacement(element: current.element, row: clampedRow, column: clampedColumn, span: current.span)
    }

    /// Replaces the placements of the given elements (keeping input order), then normalizes.
    private func replacing(_ updates: [OverlayPlacement]) -> OverlayGridLayout {
        let byElement = Dictionary(updates.map { ($0.element, $0) }, uniquingKeysWith: { first, _ in first })
        return OverlayGridLayout(placements: placements.map { byElement[$0.element] ?? $0 })
    }

    private static func normalized(_ input: [OverlayPlacement]) -> [OverlayPlacement] {
        // 1–2. Drop duplicates (first wins) and clamp.
        var seen = Set<OverlayElement>()
        var items: [(index: Int, placement: OverlayPlacement)] = []
        for (index, original) in input.enumerated() {
            guard seen.insert(original.element).inserted else { continue }
            var placement = original
            placement.span = max(placement.element.minSpan, min(placement.span, columns))
            placement.column = min(max(placement.column, 0), columns - placement.span)
            placement.row = max(placement.row, 0)
            items.append((index, placement))
        }

        // 3–4. Split each source row into non-overlapping lines.
        let bySourceRow = Dictionary(grouping: items, by: { $0.placement.row })
        var header: [OverlayPlacement] = []
        var bodyLines: [[OverlayPlacement]] = []
        for sourceRow in bySourceRow.keys.sorted() {
            let rowItems = (bySourceRow[sourceRow] ?? []).sorted {
                ($0.placement.column, $0.index) < ($1.placement.column, $1.index)
            }
            var lines: [[OverlayPlacement]] = [[]]
            for item in rowItems {
                let range = item.placement.columnRange
                if let free = lines.firstIndex(where: { line in !line.contains { $0.columnRange.overlaps(range) } }) {
                    lines[free].append(item.placement)
                } else {
                    lines.append([item.placement])
                }
            }
            if sourceRow == headerRow {
                header = lines[0]
                bodyLines.append(contentsOf: lines.dropFirst())
            } else {
                bodyLines.append(contentsOf: lines)
            }
        }

        // 5. Renumber: header 0, non-empty body lines 1, 2, …; sort by (row, column).
        var result: [OverlayPlacement] = header.map { placement in
            var renumbered = placement
            renumbered.row = headerRow
            return renumbered
        }
        var nextRow = headerRow + 1
        for line in bodyLines where !line.isEmpty {
            for placement in line {
                var renumbered = placement
                renumbered.row = nextRow
                result.append(renumbered)
            }
            nextRow += 1
        }
        result.sort { ($0.row, $0.column) < ($1.row, $1.column) }
        return result
    }
}

// MARK: - Geometry

/// Pure drag/snap math for the editor. All frames are in ONE coordinate space.
struct OverlayGridGeometry: Equatable {
    /// Row 0 = header grid region; may include rowCount (trailing drop row).
    var rowFrames: [Int: CGRect]
    var gutter: CGFloat

    init(rowFrames: [Int: CGRect], gutter: CGFloat) {
        self.rowFrames = rowFrames
        self.gutter = gutter
    }

    /// (width + gutter) / columns; 0 for an unknown row.
    func columnStep(row: Int) -> CGFloat {
        guard let frame = rowFrames[row] else { return 0 }
        return (frame.width + gutter) / CGFloat(OverlayGridLayout.columns)
    }

    /// round((leadingX − minX) / step), clamped to 0...(columns − span). 0 for an unknown row.
    func snappedColumn(leadingX: CGFloat, row: Int, span: Int) -> Int {
        let lastColumn = OverlayGridLayout.columns - min(max(span, 1), OverlayGridLayout.columns)
        let step = columnStep(row: row)
        guard let frame = rowFrames[row], step > 0 else { return 0 }
        let raw = ((leadingX - frame.minX) / step).rounded()
        guard raw.isFinite else { return 0 }
        return Int(min(max(raw, 0), CGFloat(lastColumn)))
    }

    /// Row whose frame (extended by half the gap to each neighbour) contains midY; above the first → first key;
    /// below the last → last key. A gap's exact midpoint belongs to the lower row. nil when rowFrames is empty.
    func snappedRow(midY: CGFloat) -> Int? {
        let keys = rowFrames.keys.sorted()
        guard let lastKey = keys.last else { return nil }
        for (index, key) in keys.enumerated() where key != lastKey {
            guard let frame = rowFrames[key], let next = rowFrames[keys[index + 1]] else { continue }
            if midY < (frame.maxY + next.minY) / 2 {
                return key
            }
        }
        return lastKey
    }

    /// x = minX + column·step, width = span·step − gutter, y/height = row frame's. nil for an unknown row.
    func cellFrame(row: Int, column: Int, span: Int) -> CGRect? {
        guard let frame = rowFrames[row] else { return nil }
        let step = columnStep(row: row)
        return CGRect(x: frame.minX + CGFloat(column) * step,
                      y: frame.minY,
                      width: max(0, CGFloat(span) * step - gutter),
                      height: frame.height)
    }

    /// round((trailingX − minX + gutter) / step) − column, clamped to 1...columns (the model clamps further).
    func snappedSpan(trailingX: CGFloat, row: Int, column: Int) -> Int {
        let step = columnStep(row: row)
        guard let frame = rowFrames[row], step > 0 else { return 1 }
        let raw = ((trailingX - frame.minX + gutter) / step).rounded() - CGFloat(column)
        guard raw.isFinite else { return 1 }
        return Int(min(max(raw, 1), CGFloat(OverlayGridLayout.columns)))
    }
}
