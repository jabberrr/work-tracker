import CoreGraphics
import XCTest
@testable import Worklog

/// Pure model tests for `OverlayGridLayout` and `OverlayGridGeometry` (ARCHITECTURE §13).
final class OverlayGridLayoutTests: XCTestCase {

    private func p(_ element: OverlayElement, _ row: Int, _ column: Int, _ span: Int) -> OverlayPlacement {
        OverlayPlacement(element: element, row: row, column: column, span: span)
    }

    private func grid(_ placements: [OverlayPlacement]) -> OverlayGridLayout {
        OverlayGridLayout(placements: placements)
    }

    /// label(0,0,4), timer(1,0,6), segmentFocus(2,0,6), controls(3,0,2), split(3,2,1), note(4,0,6), takeaway(5,0,6)
    private var defaultPlacements: [OverlayPlacement] {
        [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6), p(.controls, 3, 0, 2),
         p(.split, 3, 2, 1), p(.note, 4, 0, 6), p(.takeaway, 5, 0, 6)]
    }

    private func assertCell(_ cell: (row: Int, column: Int), _ row: Int, _ column: Int, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(cell.row, row, "row " + message, file: file, line: line)
        XCTAssertEqual(cell.column, column, "column " + message, file: file, line: line)
    }

    private func decode(_ json: String) throws -> OverlayGridLayout {
        try JSONDecoder().decode(OverlayGridLayout.self, from: Data(json.utf8))
    }

    // MARK: - Default and migration

    func testDefaultLayoutPlacements() {
        XCTAssertEqual(OverlayGridLayout.defaultLayout.placements, defaultPlacements)
        XCTAssertEqual(OverlayGridLayout.defaultLayout, OverlayGridLayout.migrated(from: OverlayElement.defaultLayout))
        XCTAssertEqual(OverlayGridLayout.defaultLayout.rowCount, 6)
        XCTAssertEqual(OverlayGridLayout.defaultLayout.readingOrder, OverlayElement.defaultLayout)
    }

    func testMigrationOrderPutsTodayTotalTrailing() {
        let migrated = OverlayGridLayout.migrated(from: OverlayElement.migrationOrder)
        XCTAssertEqual(migrated.placements(inRow: 3), [p(.controls, 3, 0, 2), p(.split, 3, 2, 1), p(.todayTotal, 3, 4, 2)])
        XCTAssertEqual(migrated.placements(inRow: 0), [p(.label, 0, 0, 4)])
        XCTAssertEqual(migrated.rowCount, 6)
    }

    func testMigrationPreservesReadingOrder() {
        let empty = OverlayGridLayout.migrated(from: [])
        XCTAssertEqual(empty, .empty)
        XCTAssertEqual(empty.readingOrder, [])
        XCTAssertEqual(empty.rowCount, 1)

        let timerOnly = OverlayGridLayout.migrated(from: [.timer])
        XCTAssertEqual(timerOnly.placements, [p(.timer, 1, 0, 6)], "a full-width element never goes in the header")
        XCTAssertEqual(timerOnly.readingOrder, [.timer])

        let timerLabel = OverlayGridLayout.migrated(from: [.timer, .label])
        XCTAssertEqual(timerLabel.placements, [p(.timer, 1, 0, 6), p(.label, 2, 0, 4)])
        XCTAssertEqual(timerLabel.placements(inRow: 0), [], "header empty")
        XCTAssertEqual(timerLabel.rowCount, 3)
        XCTAssertEqual(timerLabel.readingOrder, [.timer, .label])

        let wrapping: [OverlayElement] = [.todayTotal, .label, .controls, .split]
        let wrapped = OverlayGridLayout.migrated(from: wrapping)
        XCTAssertEqual(wrapped.placements,
                       [p(.todayTotal, 0, 0, 2), p(.label, 0, 2, 4), p(.controls, 1, 0, 2), p(.split, 1, 2, 1)])
        XCTAssertEqual(wrapped.readingOrder, wrapping)

        XCTAssertEqual(OverlayGridLayout.migrated(from: OverlayElement.migrationOrder).readingOrder,
                       OverlayElement.migrationOrder)

        // A trailing today's total alone in a row moves to the end; reading order is unchanged.
        let lone = OverlayGridLayout.migrated(from: [.timer, .todayTotal])
        XCTAssertEqual(lone.placements, [p(.timer, 1, 0, 6), p(.todayTotal, 2, 4, 2)])
        XCTAssertEqual(lone.readingOrder, [.timer, .todayTotal])
    }

    func testMigrationDropsDuplicatesAndUnknowns() {
        let duplicated = OverlayGridLayout.migrated(from: [.timer, .label, .timer, .label])
        XCTAssertEqual(duplicated.readingOrder, [.timer, .label])
        XCTAssertEqual(duplicated, OverlayGridLayout.migrated(from: [.timer, .label]))

        let fromRaw = OverlayGridLayout.migrated(from: OverlayElement.sanitized(["timer", "bogus", "label", "timer"]))
        XCTAssertEqual(fromRaw, OverlayGridLayout.migrated(from: [.timer, .label]))
    }

    // MARK: - Sanitize and normalize

    func testSanitizeClampsSpansAndColumns() {
        XCTAssertEqual(grid([p(.timer, 1, 0, 9)]).placements, [p(.timer, 1, 0, 6)], "span 9 → 6")
        XCTAssertEqual(grid([p(.label, 0, 0, 1)]).placements, [p(.label, 0, 0, 2)], "label span 1 → minSpan 2")
        XCTAssertEqual(grid([p(.note, 1, 5, 3)]).placements, [p(.note, 1, 3, 3)], "column 5 span 3 → column 3")
        XCTAssertEqual(grid([p(.split, -2, 4, 1)]).placements, [p(.split, 0, 4, 1)], "row −2 → 0")
        XCTAssertEqual(grid([p(.controls, 0, -3, -7)]).placements, [p(.controls, 0, 0, 2)])
    }

    func testSanitizeResolvesOverlapsByPushingDown() {
        // Overlapping in row 1: the second (by column) goes to a new row directly below.
        XCTAssertEqual(grid([p(.timer, 1, 0, 6), p(.note, 1, 2, 3), p(.takeaway, 2, 0, 6)]).placements,
                       [p(.timer, 1, 0, 6), p(.note, 2, 2, 3), p(.takeaway, 3, 0, 6)])
        // Sorted by column first: the leftmost keeps the row whatever the input order.
        XCTAssertEqual(grid([p(.note, 1, 3, 3), p(.timer, 1, 0, 6)]).placements,
                       [p(.timer, 1, 0, 6), p(.note, 2, 3, 3)])
        // A non-overlapping element stays in the first line.
        XCTAssertEqual(grid([p(.controls, 1, 0, 2), p(.label, 1, 1, 4), p(.split, 1, 5, 1)]).placements,
                       [p(.controls, 1, 0, 2), p(.split, 1, 5, 1), p(.label, 2, 1, 4)])
        // Header overflow becomes the first body row.
        XCTAssertEqual(grid([p(.label, 0, 0, 4), p(.todayTotal, 0, 2, 2), p(.timer, 1, 0, 6)]).placements,
                       [p(.label, 0, 0, 4), p(.todayTotal, 1, 2, 2), p(.timer, 2, 0, 6)])
        // Duplicates: the first wins.
        XCTAssertEqual(grid([p(.timer, 1, 0, 6), p(.timer, 2, 0, 3)]).placements, [p(.timer, 1, 0, 6)])
    }

    func testNormalizeCollapsesEmptyBodyRowsKeepsHeader() {
        let layout = grid([p(.note, 7, 0, 6), p(.timer, 3, 0, 6)])
        XCTAssertEqual(layout.placements, [p(.timer, 1, 0, 6), p(.note, 2, 0, 6)])
        XCTAssertEqual(layout.placements(inRow: 0), [])
        XCTAssertEqual(layout.rowCount, 3)
    }

    // MARK: - Moving

    func testMoveIntoFreeCell() {
        let base = OverlayGridLayout.defaultLayout
        // Same row.
        XCTAssertEqual(base.moving(.split, toRow: 3, column: 5).placements,
                       [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6), p(.controls, 3, 0, 2),
                        p(.split, 3, 5, 1), p(.note, 4, 0, 6), p(.takeaway, 5, 0, 6)])
        // Other row (the header's free column 5).
        XCTAssertEqual(base.moving(.split, toRow: 0, column: 5).placements,
                       [p(.label, 0, 0, 4), p(.split, 0, 5, 1), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6),
                        p(.controls, 3, 0, 2), p(.note, 4, 0, 6), p(.takeaway, 5, 0, 6)])
        // Moving onto its own cell changes nothing.
        XCTAssertEqual(base.moving(.controls, toRow: 3, column: 0), base)
        // Absent element: no-op.
        XCTAssertEqual(base.moving(.todayTotal, toRow: 1, column: 0), base)
    }

    func testMovePushesOverlappedDown() {
        let moved = OverlayGridLayout.defaultLayout.moving(.split, toRow: 1, column: 0)
        XCTAssertEqual(moved.placements,
                       [p(.label, 0, 0, 4), p(.split, 1, 0, 1), p(.timer, 2, 0, 6), p(.segmentFocus, 3, 0, 6),
                        p(.controls, 4, 0, 2), p(.note, 5, 0, 6), p(.takeaway, 6, 0, 6)])
        XCTAssertEqual(moved.rowCount, 7)
    }

    func testMoveToNewTrailingRow() {
        let base = OverlayGridLayout.defaultLayout
        let expected = [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6), p(.split, 3, 2, 1),
                        p(.note, 4, 0, 6), p(.takeaway, 5, 0, 6), p(.controls, 6, 3, 2)]
        XCTAssertEqual(base.moving(.controls, toRow: base.rowCount, column: 3).placements, expected)
        XCTAssertEqual(base.moving(.controls, toRow: 99, column: 3).placements, expected, "row clamped to rowCount")
    }

    func testMoveRemovesVacatedRow() {
        let layout = grid([p(.label, 0, 0, 4), p(.split, 1, 0, 1), p(.timer, 2, 0, 6)])
        let moved = layout.moving(.split, toRow: 0, column: 5)
        XCTAssertEqual(moved.placements, [p(.label, 0, 0, 4), p(.split, 0, 5, 1), p(.timer, 1, 0, 6)])
        XCTAssertEqual(moved.rowCount, 2)

        let timerLast = OverlayGridLayout.defaultLayout.moving(.timer, toRow: 6, column: 0)
        XCTAssertEqual(timerLast.placements,
                       [p(.label, 0, 0, 4), p(.segmentFocus, 1, 0, 6), p(.controls, 2, 0, 2), p(.split, 2, 2, 1),
                        p(.note, 3, 0, 6), p(.takeaway, 4, 0, 6), p(.timer, 5, 0, 6)])
    }

    func testMoveClampsColumn() {
        let base = OverlayGridLayout.defaultLayout
        XCTAssertEqual(base.moving(.controls, toRow: 3, column: 10).placements(inRow: 3),
                       [p(.split, 3, 2, 1), p(.controls, 3, 4, 2)], "column 10 → 6 − span = 4")
        XCTAssertEqual(base.moving(.label, toRow: 0, column: -5), base, "column −5 → 0")
        XCTAssertEqual(base.moving(.split, toRow: -3, column: 5).placements(inRow: 0),
                       [p(.label, 0, 0, 4), p(.split, 0, 5, 1)], "row −3 → 0")
    }

    func testMoveIntoHeaderPushesHeaderOccupantToRow1() {
        let moved = OverlayGridLayout.defaultLayout.moving(.controls, toRow: 0, column: 1)
        XCTAssertEqual(moved.placements,
                       [p(.controls, 0, 1, 2), p(.label, 1, 0, 4), p(.timer, 2, 0, 6), p(.segmentFocus, 3, 0, 6),
                        p(.split, 4, 2, 1), p(.note, 5, 0, 6), p(.takeaway, 6, 0, 6)])
    }

    func testDisplaced() {
        let base = OverlayGridLayout.defaultLayout
        XCTAssertEqual(base.displaced(byMoving: .split, toRow: 1, column: 0), [.timer])
        XCTAssertEqual(base.displaced(byMoving: .timer, toRow: 3, column: 0), [.controls, .split])
        XCTAssertEqual(base.displaced(byMoving: .controls, toRow: 0, column: 1), [.label])
        XCTAssertEqual(base.displaced(byMoving: .split, toRow: 0, column: 5), [], "free cell")
        XCTAssertEqual(base.displaced(byMoving: .controls, toRow: 3, column: 0), [], "its own cell")
        XCTAssertEqual(base.displaced(byMoving: .split, toRow: base.rowCount, column: 0), [], "new row")
        XCTAssertEqual(base.displaced(byMoving: .todayTotal, toRow: 1, column: 0), [], "absent element")
    }

    // MARK: - Resizing

    func testResizeClampsToNeighbourMinSpanAndColumns() {
        let base = OverlayGridLayout.defaultLayout
        XCTAssertEqual(base.maxSpan(for: .controls), 2)
        XCTAssertEqual(base.maxSpan(for: .split), 4)
        XCTAssertEqual(base.maxSpan(for: .label), 6)
        XCTAssertEqual(base.maxSpan(for: .todayTotal), 0, "absent")

        XCTAssertEqual(base.resizing(.controls, toSpan: 5), base, "clamped at the right neighbour (split)")
        XCTAssertEqual(base.resizing(.split, toSpan: 10).placement(of: .split), p(.split, 3, 2, 4))
        XCTAssertEqual(base.resizing(.label, toSpan: 1).placement(of: .label), p(.label, 0, 0, 2), "minSpan")
        XCTAssertEqual(base.resizing(.label, toSpan: 6).placement(of: .label), p(.label, 0, 0, 6))
        XCTAssertEqual(base.resizing(.timer, toSpan: 2).placement(of: .timer), p(.timer, 1, 0, 3), "minSpan 3")
        XCTAssertEqual(base.resizing(.todayTotal, toSpan: 3), base, "absent")

        XCTAssertFalse(base.canResize(.controls, by: 1))
        XCTAssertFalse(base.canResize(.controls, by: -1))
        XCTAssertTrue(base.canResize(.split, by: 1))
        XCTAssertFalse(base.canResize(.split, by: -1))
        XCTAssertTrue(base.canResize(.timer, by: -1))
        XCTAssertFalse(base.canResize(.timer, by: 1))
        XCTAssertFalse(base.resizing(.timer, toSpan: 3).canResize(.timer, by: -1))
        XCTAssertFalse(base.canResize(.todayTotal, by: 1))
    }

    // MARK: - Nudging

    func testNudgeLeftRightFreeMoveAndSwap() {
        let layout = grid([p(.controls, 1, 0, 2), p(.split, 1, 2, 1), p(.todayTotal, 1, 4, 2)])

        XCTAssertEqual(layout.nudged(.split, .right).placements,
                       [p(.controls, 1, 0, 2), p(.split, 1, 3, 1), p(.todayTotal, 1, 4, 2)], "free column")
        XCTAssertEqual(layout.nudged(.todayTotal, .left).placements,
                       [p(.controls, 1, 0, 2), p(.split, 1, 2, 1), p(.todayTotal, 1, 3, 2)], "free column")

        let swapped = [p(.split, 1, 0, 1), p(.controls, 1, 1, 2), p(.todayTotal, 1, 4, 2)]
        XCTAssertEqual(layout.nudged(.split, .left).placements, swapped, "swap; the gap at column 3 is kept")
        XCTAssertEqual(layout.nudged(.controls, .right).placements, swapped, "swap; the gap at column 3 is kept")

        // Swap to the right keeps the gaps on both sides.
        XCTAssertEqual(grid([p(.split, 1, 2, 1), p(.todayTotal, 1, 3, 2)]).nudged(.split, .right).placements,
                       [p(.todayTotal, 1, 2, 2), p(.split, 1, 4, 1)])

        // Edge no-ops.
        XCTAssertEqual(layout.nudged(.controls, .left), layout)
        XCTAssertEqual(layout.nudged(.todayTotal, .right), layout)
        XCTAssertFalse(layout.canNudge(.controls, .left))
        XCTAssertFalse(layout.canNudge(.todayTotal, .right))
        XCTAssertTrue(layout.canNudge(.split, .left))
        XCTAssertTrue(layout.canNudge(.split, .right))
        XCTAssertFalse(layout.canNudge(.label, .left), "absent")
    }

    func testNudgeUpDown() {
        let base = OverlayGridLayout.defaultLayout
        let swapped = [p(.label, 0, 0, 4), p(.segmentFocus, 1, 0, 6), p(.timer, 2, 0, 6), p(.controls, 3, 0, 2),
                       p(.split, 3, 2, 1), p(.note, 4, 0, 6), p(.takeaway, 5, 0, 6)]
        XCTAssertEqual(base.nudged(.segmentFocus, .up).placements, swapped, "full-width rows swap")
        XCTAssertEqual(base.nudged(.timer, .down).placements, swapped, "full-width rows swap")

        XCTAssertEqual(base.nudged(.label, .up), base, "up from the header")
        XCTAssertFalse(base.canNudge(.label, .up))
        XCTAssertEqual(base.nudged(.takeaway, .down), base, "alone in the last row")
        XCTAssertFalse(base.canNudge(.takeaway, .down))
        XCTAssertTrue(base.canNudge(.takeaway, .up))
        XCTAssertTrue(base.canNudge(.timer, .down))

        // Down from the header (the header row never collapses): push-down into row 1.
        XCTAssertEqual(base.nudged(.label, .down).placements,
                       [p(.label, 1, 0, 4), p(.timer, 2, 0, 6), p(.segmentFocus, 3, 0, 6), p(.controls, 4, 0, 2),
                        p(.split, 4, 2, 1), p(.note, 5, 0, 6), p(.takeaway, 6, 0, 6)])
        // Not alone in its row: push-down into the next row.
        XCTAssertEqual(base.nudged(.split, .down).placements,
                       [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6), p(.controls, 3, 0, 2),
                        p(.split, 4, 2, 1), p(.note, 5, 0, 6), p(.takeaway, 6, 0, 6)])
        XCTAssertEqual(base.nudged(.split, .up).placements,
                       [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.split, 2, 2, 1), p(.segmentFocus, 3, 0, 6),
                        p(.controls, 4, 0, 2), p(.note, 5, 0, 6), p(.takeaway, 6, 0, 6)])

        // Alone in a body row, partly overlapping the next row: only the overlapped element moves up.
        let partial = grid([p(.note, 1, 0, 3), p(.controls, 2, 0, 2), p(.todayTotal, 2, 4, 2)])
        XCTAssertEqual(partial.nudged(.note, .down).placements,
                       [p(.controls, 1, 0, 2), p(.note, 2, 0, 3), p(.todayTotal, 2, 4, 2)])
    }

    // MARK: - Free cells, adding, removing

    func testFirstFreeCell() {
        let base = OverlayGridLayout.defaultLayout
        assertCell(base.firstFreeCell(span: 2), 3, 3)
        assertCell(base.firstFreeCell(span: 2, preferTrailing: true), 3, 4)
        assertCell(base.firstFreeCell(span: 1, preferTrailing: true), 3, 5)
        assertCell(base.firstFreeCell(span: 4), 6, 0, "no room: a new row")
        assertCell(base.firstFreeCell(span: 4, preferTrailing: true), 6, 2, "no room: a new row")

        // Never the header.
        assertCell(grid([p(.label, 0, 0, 2)]).firstFreeCell(span: 2), 1, 0)
        assertCell(OverlayGridLayout.empty.firstFreeCell(span: 6), 1, 0)

        // Finds a hole.
        let holey = grid([p(.timer, 1, 0, 6), p(.controls, 2, 0, 2), p(.todayTotal, 2, 4, 2)])
        assertCell(holey.firstFreeCell(span: 2), 2, 2)
        assertCell(holey.firstFreeCell(span: 3), 3, 0)

        XCTAssertTrue(base.isFree(row: 3, columns: 3..<6))
        XCTAssertFalse(base.isFree(row: 3, columns: 2..<4))
        XCTAssertFalse(base.isFree(row: 3, columns: 0..<3, excluding: .controls), "split still at 2")
        XCTAssertTrue(base.isFree(row: 3, columns: 0..<2, excluding: .controls))
        XCTAssertFalse(base.isFree(row: 3, columns: 5..<7), "outside the grid")
    }

    func testAddingAndRemoving() {
        let base = OverlayGridLayout.defaultLayout
        XCTAssertEqual(base.hiddenElements, [.todayTotal])
        XCTAssertEqual(OverlayGridLayout.empty.hiddenElements, OverlayElement.allCases)

        let added = base.adding(.todayTotal)
        XCTAssertEqual(added.placement(of: .todayTotal), p(.todayTotal, 3, 4, 2))
        XCTAssertEqual(added.hiddenElements, [])
        XCTAssertEqual(added.elements, Set(OverlayElement.allCases))
        XCTAssertEqual(base.adding(.label), base, "already present")

        XCTAssertEqual(OverlayGridLayout.empty.adding(.timer).placements, [p(.timer, 1, 0, 6)])
        XCTAssertEqual(OverlayGridLayout.empty.adding(.label).placements, [p(.label, 1, 0, 4)], "never the header")

        let withoutRow3 = base.removing(.controls).removing(.split)
        XCTAssertEqual(withoutRow3.placements,
                       [p(.label, 0, 0, 4), p(.timer, 1, 0, 6), p(.segmentFocus, 2, 0, 6),
                        p(.note, 3, 0, 6), p(.takeaway, 4, 0, 6)])
        XCTAssertEqual(withoutRow3.rowCount, 5)
        XCTAssertEqual(withoutRow3.hiddenElements, [.controls, .split, .todayTotal])

        let headerless = base.removing(.label)
        XCTAssertEqual(headerless.placements(inRow: 0), [], "the header row stays (empty)")
        XCTAssertEqual(headerless.placement(of: .timer), p(.timer, 1, 0, 6))
        XCTAssertEqual(base.removing(.todayTotal), base, "absent")
        XCTAssertFalse(base.contains(.todayTotal))
        XCTAssertTrue(base.contains(.note))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let layout = OverlayGridLayout.defaultLayout.adding(.todayTotal).resizing(.label, toSpan: 3)
        let data = try encoder.encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(OverlayGridLayout.self, from: data), layout)
        XCTAssertEqual(try encoder.encode(layout), data, "stable")

        let small = try encoder.encode(grid([p(.label, 0, 0, 4)]))
        XCTAssertEqual(String(decoding: small, as: UTF8.self),
                       #"{"columns":6,"formatVersion":1,"placements":[{"column":0,"element":"label","row":0,"span":4}]}"#)
    }

    func testDecodeSkipsUnknownElements() throws {
        let layout = try decode("""
        {"formatVersion":1,"columns":6,"placements":[
          {"element":"hologram","row":0,"column":0,"span":2},
          {"element":"timer","row":1,"column":0,"span":6},
          42
        ]}
        """)
        XCTAssertEqual(layout.placements, [p(.timer, 1, 0, 6)])
    }

    func testDecodeRescalesColumns() throws {
        let layout = try decode("""
        {"formatVersion":1,"columns":12,"placements":[
          {"element":"label","row":0,"column":0,"span":8},
          {"element":"split","row":0,"column":10,"span":2},
          {"element":"timer","row":1,"column":0,"span":12},
          {"element":"controls","row":2,"column":3,"span":3}
        ]}
        """)
        // controls: column 1.5 → 2, span 1.5 → 2 (rounded half away from zero).
        XCTAssertEqual(layout.placements,
                       [p(.label, 0, 0, 4), p(.split, 0, 5, 1), p(.timer, 1, 0, 6), p(.controls, 2, 2, 2)])
    }

    func testDecodeFutureFormatVersionLeniently() throws {
        let layout = try decode("""
        {"formatVersion":7,"columns":6,"extra":true,"placements":[
          {"element":"note","row":1,"column":0,"span":6,"height":2}
        ]}
        """)
        XCTAssertEqual(layout.placements, [p(.note, 1, 0, 6)])
    }

    func testDecodeMissingPlacementsThrows() {
        XCTAssertThrowsError(try decode(#"{"formatVersion":1,"columns":6}"#))
    }

    func testDecodeOverlappingDataIsNormalized() throws {
        // No "columns" key (defaults to 6); an overlap, a duplicate and a gap row.
        let layout = try decode("""
        {"placements":[
          {"element":"timer","row":1,"column":0,"span":6},
          {"element":"note","row":1,"column":0,"span":6},
          {"element":"timer","row":5,"column":0,"span":6},
          {"element":"takeaway","row":9,"column":0,"span":6}
        ]}
        """)
        XCTAssertEqual(layout.placements, [p(.timer, 1, 0, 6), p(.note, 2, 0, 6), p(.takeaway, 3, 0, 6)])
    }

    // MARK: - Render rows

    func testRenderRowsActive() {
        let base = OverlayGridLayout.defaultLayout
        let rows = base.renderRows(isVisible: { $0 != .takeaway }, headerInline: true)
        XCTAssertEqual(rows.header, OverlayGridRenderRow(row: 0, placements: [p(.label, 0, 0, 4)]))
        XCTAssertEqual(rows.body.map(\.row), [1, 2, 3, 4], "the hidden takeaway's row collapses")
        XCTAssertEqual(rows.body[2].placements, [p(.controls, 3, 0, 2), p(.split, 3, 2, 1)])

        let timerOnly = base.renderRows(isVisible: { $0 == .timer }, headerInline: true)
        XCTAssertEqual(timerOnly.header, OverlayGridRenderRow(row: 0, placements: []))
        XCTAssertEqual(timerOnly.body, [OverlayGridRenderRow(row: 1, placements: [p(.timer, 1, 0, 6)])])
    }

    func testRenderRowsIdle() {
        let idleVisible: (OverlayElement) -> Bool = { [OverlayElement.controls, .todayTotal, .takeaway].contains($0) }

        // Row 0's visible items become the first body row; controls widen over the free columns.
        let layout = grid([p(.controls, 0, 2, 2), p(.todayTotal, 0, 4, 2), p(.timer, 1, 0, 6), p(.takeaway, 2, 0, 6)])
        let idle = layout.renderRows(isVisible: idleVisible, headerInline: false, widening: [.controls])
        XCTAssertEqual(idle.header, OverlayGridRenderRow(row: 0, placements: []))
        XCTAssertEqual(idle.body, [
            OverlayGridRenderRow(row: 0, placements: [p(.controls, 0, 0, 4), p(.todayTotal, 0, 4, 2)]),
            OverlayGridRenderRow(row: 2, placements: [p(.takeaway, 2, 0, 6)]),
        ])

        // Inline header: no demotion, no widening requested.
        let active = layout.renderRows(isVisible: idleVisible, headerInline: true)
        XCTAssertEqual(active.header.placements, [p(.controls, 0, 2, 2), p(.todayTotal, 0, 4, 2)])
        XCTAssertEqual(active.body.map(\.row), [2])

        // Widening uses VISIBLE neighbours only.
        let row = grid([p(.label, 1, 0, 2), p(.controls, 1, 2, 2), p(.split, 1, 5, 1)])
        let labelHidden = row.renderRows(isVisible: { $0 != .label }, headerInline: false, widening: [.controls])
        XCTAssertEqual(labelHidden.body.first?.placements, [p(.controls, 1, 0, 5), p(.split, 1, 5, 1)])
        let labelShown = row.renderRows(isVisible: { _ in true }, headerInline: false, widening: [.controls])
        XCTAssertEqual(labelShown.body.first?.placements,
                       [p(.label, 1, 0, 2), p(.controls, 1, 2, 3), p(.split, 1, 5, 1)])

        // Nothing visible in row 0: no demoted row.
        let defaultIdle = OverlayGridLayout.defaultLayout.renderRows(isVisible: idleVisible, headerInline: false,
                                                                     widening: [.controls])
        XCTAssertEqual(defaultIdle.body, [OverlayGridRenderRow(row: 3, placements: [p(.controls, 3, 0, 6)]),
                                          OverlayGridRenderRow(row: 5, placements: [p(.takeaway, 5, 0, 6)])])
    }

    // MARK: - Geometry

    private let regular = OverlayGridGeometry(rowFrames: [
        0: CGRect(x: 40, y: 0, width: 150, height: 20),
        1: CGRect(x: 10, y: 30, width: 276, height: 40),
        2: CGRect(x: 10, y: 80, width: 276, height: 20),
    ], gutter: 4)

    private let compact = OverlayGridGeometry(rowFrames: [1: CGRect(x: 0, y: 0, width: 204, height: 30)], gutter: 4)

    func testGeometrySnappedColumn() {
        XCTAssertEqual(regular.columnStep(row: 1), 280.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(regular.columnStep(row: 9), 0)
        // step 46.67: 115/step = 2.46 → 2; 120/step = 2.57 → 3.
        XCTAssertEqual(regular.snappedColumn(leadingX: 10, row: 1, span: 2), 0)
        XCTAssertEqual(regular.snappedColumn(leadingX: 125, row: 1, span: 2), 2)
        XCTAssertEqual(regular.snappedColumn(leadingX: 130, row: 1, span: 2), 3)
        XCTAssertEqual(regular.snappedColumn(leadingX: 1000, row: 1, span: 2), 4, "clamped to 6 − span")
        XCTAssertEqual(regular.snappedColumn(leadingX: 130, row: 1, span: 6), 0)
        XCTAssertEqual(regular.snappedColumn(leadingX: -100, row: 1, span: 1), 0)
        XCTAssertEqual(regular.snappedColumn(leadingX: 130, row: 9, span: 1), 0, "unknown row")
        // Compact: step 208/6 = 34.67; 50 → 1.44 → 1; 53 → 1.53 → 2; 190 → 5.48 → 5 → clamped to 3.
        XCTAssertEqual(compact.snappedColumn(leadingX: 50, row: 1, span: 1), 1)
        XCTAssertEqual(compact.snappedColumn(leadingX: 53, row: 1, span: 1), 2)
        XCTAssertEqual(compact.snappedColumn(leadingX: 190, row: 1, span: 3), 3)
    }

    func testGeometrySnappedRow() {
        // Boundaries: (20 + 30) / 2 = 25 and (70 + 80) / 2 = 75.
        XCTAssertEqual(regular.snappedRow(midY: 10), 0)
        XCTAssertEqual(regular.snappedRow(midY: 50), 1, "inside")
        XCTAssertEqual(regular.snappedRow(midY: 24.9), 0, "gap, above the midpoint")
        XCTAssertEqual(regular.snappedRow(midY: 25), 1, "gap midpoint belongs to the lower row")
        XCTAssertEqual(regular.snappedRow(midY: 74), 1)
        XCTAssertEqual(regular.snappedRow(midY: 75), 2)
        XCTAssertEqual(regular.snappedRow(midY: -500), 0, "above the first")
        XCTAssertEqual(regular.snappedRow(midY: 900), 2, "below the last")
        XCTAssertNil(OverlayGridGeometry(rowFrames: [:], gutter: 4).snappedRow(midY: 0))
    }

    func testGeometryCellFrame() throws {
        let span2 = try XCTUnwrap(regular.cellFrame(row: 1, column: 0, span: 2))
        XCTAssertEqual(span2.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(span2.width, 89.3333, accuracy: 0.001)
        XCTAssertEqual(span2.minY, 30)
        XCTAssertEqual(span2.height, 40)

        let span3 = try XCTUnwrap(regular.cellFrame(row: 1, column: 3, span: 3))
        XCTAssertEqual(span3.minX, 150, accuracy: 0.0001)
        XCTAssertEqual(span3.width, 136, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(regular.cellFrame(row: 1, column: 0, span: 6)).width, 276, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(regular.cellFrame(row: 1, column: 0, span: 1)).width, 42.6667, accuracy: 0.001)

        XCTAssertEqual(try XCTUnwrap(compact.cellFrame(row: 1, column: 0, span: 2)).width, 65.3333, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(compact.cellFrame(row: 1, column: 0, span: 6)).width, 204, accuracy: 0.0001)
        XCTAssertNil(regular.cellFrame(row: 9, column: 0, span: 1))
    }

    func testGeometrySnappedSpan() {
        let step: CGFloat = 280.0 / 6
        // An element's own trailing edge snaps back to its span.
        XCTAssertEqual(regular.snappedSpan(trailingX: 10 + 2 * step - 4, row: 1, column: 0), 2)
        XCTAssertEqual(regular.snappedSpan(trailingX: 10 + 5 * step - 4, row: 1, column: 2), 3)
        XCTAssertEqual(regular.snappedSpan(trailingX: 286, row: 1, column: 0), 6)
        // 0.4 of a step past span 2 → 2; 0.6 → 3.
        XCTAssertEqual(regular.snappedSpan(trailingX: 10 + 2.4 * step - 4, row: 1, column: 0), 2)
        XCTAssertEqual(regular.snappedSpan(trailingX: 10 + 2.6 * step - 4, row: 1, column: 0), 3)
        XCTAssertEqual(regular.snappedSpan(trailingX: 0, row: 1, column: 2), 1, "clamped to ≥ 1")
        XCTAssertEqual(regular.snappedSpan(trailingX: 200, row: 9, column: 0), 1, "unknown row")
    }
}
