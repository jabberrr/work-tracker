import XCTest
@testable import Worklog

final class OverlayLayoutTests: XCTestCase {

    private static let layoutKey = "settings.overlayLayout"
    private static let gridKey = "settings.overlayGrid"

    /// A fresh, empty UserDefaults suite, removed again when the test ends.
    private func makeDefaults() -> UserDefaults {
        let name = "OverlayLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return defaults
    }

    /// The grid stored under "settings.overlayGrid", decoded (nil when absent or undecodable).
    private func storedGrid(_ defaults: UserDefaults) -> OverlayGridLayout? {
        defaults.data(forKey: Self.gridKey).flatMap { try? JSONDecoder().decode(OverlayGridLayout.self, from: $0) }
    }

    private func mirror(_ defaults: UserDefaults) -> [String]? {
        defaults.array(forKey: Self.layoutKey) as? [String]
    }

    /// A grid with free columns and resized spans (not what any list migration produces).
    private var customGrid: OverlayGridLayout {
        OverlayGridLayout(placements: [
            OverlayPlacement(element: .label, row: 0, column: 1, span: 3),
            OverlayPlacement(element: .timer, row: 1, column: 0, span: 4),
            OverlayPlacement(element: .controls, row: 2, column: 3, span: 2),
            OverlayPlacement(element: .note, row: 3, column: 0, span: 5),
        ])
    }

    // MARK: - Migration

    @MainActor
    func testFreshInstallMigratesToDefaultLayout() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayLayout, OverlayElement.defaultLayout)
        XCTAssertEqual(defaults.array(forKey: Self.layoutKey) as? [String],
                       OverlayElement.defaultLayout.map(\.rawValue),
                       "the migrated layout is written immediately")
    }

    @MainActor
    func testExplicitLegacyDefaultsMigrateToDefaultLayout() {
        let defaults = makeDefaults()
        let legacy: [String: Bool] = [
            "overlayShowLabel": true, "overlayShowTimer": true, "overlayShowSegmentFocus": true,
            "overlayShowControls": true, "overlayShowSplitButton": true, "overlayShowTodayTotal": false,
            "overlayShowNoteField": true, "overlayShowLastTakeaway": true,
        ]
        for (property, value) in legacy {
            defaults.set(value, forKey: "settings." + property)
        }
        XCTAssertEqual(AppSettings(defaults: defaults).overlayLayout, OverlayElement.defaultLayout)
    }

    @MainActor
    func testMigrationKeepsLegacyToggles() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "settings.overlayShowSplitButton")
        defaults.set(true, forKey: "settings.overlayShowTodayTotal")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayLayout, [.label, .timer, .segmentFocus, .controls, .todayTotal, .note, .takeaway])
        XCTAssertFalse(settings.overlayShows(.split))
        XCTAssertTrue(settings.overlayShows(.todayTotal))
        // The legacy keys are left untouched (allows a downgrade).
        XCTAssertEqual(defaults.object(forKey: "settings.overlayShowSplitButton") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "settings.overlayShowTodayTotal") as? Bool, true)
    }

    @MainActor
    func testMigrationRunsOnlyOnce() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "settings.overlayShowNoteField")
        XCTAssertFalse(AppSettings(defaults: defaults).overlayShows(.note))

        // Changing a legacy key after the migration has no effect: the new key wins.
        defaults.set(true, forKey: "settings.overlayShowNoteField")
        defaults.set(false, forKey: "settings.overlayShowTimer")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.overlayShows(.note))
        XCTAssertTrue(reloaded.overlayShows(.timer))
    }

    // MARK: - Sanitizing and persistence

    func testSanitizedDropsUnknownsAndDuplicates() {
        XCTAssertEqual(OverlayElement.sanitized(["timer", "bogus", "label", "timer", "", "note", "label"]),
                       [.timer, .label, .note])
        XCTAssertEqual(OverlayElement.sanitized([]), [])
        XCTAssertEqual(OverlayElement.sanitized(OverlayElement.migrationOrder.map(\.rawValue)),
                       OverlayElement.migrationOrder)
    }

    @MainActor
    func testStoredLayoutIsSanitizedOnLoad() {
        let defaults = makeDefaults()
        defaults.set(["takeaway", "nope", "timer", "takeaway"], forKey: Self.layoutKey)
        XCTAssertEqual(AppSettings(defaults: defaults).overlayLayout, [.takeaway, .timer])
    }

    @MainActor
    func testLayoutRoundTripsThroughFreshSettings() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.overlayLayout = [.takeaway, .todayTotal, .timer]
        XCTAssertEqual(AppSettings(defaults: defaults).overlayLayout, [.takeaway, .todayTotal, .timer])

        // An empty layout is allowed and stays empty (it is not re-migrated).
        settings.overlayLayout = []
        XCTAssertEqual(AppSettings(defaults: defaults).overlayLayout, [])
    }

    // MARK: - Reset

    @MainActor
    func testResetOverlayLayout() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.overlayLayout = [.note]
        settings.resetOverlayLayout()
        XCTAssertEqual(settings.overlayLayout, OverlayElement.defaultLayout)
    }

    @MainActor
    func testResetOverlayDefaults() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.overlayEnabled = true
        settings.overlayLayout = [.timer]
        settings.overlayCompact = true
        settings.overlayOpacity = 0.5
        settings.overlayAlwaysOnTop = false
        settings.overlayShowOnAllSpaces = false
        settings.overlayHideWhenIdle = true

        settings.resetOverlayDefaults()

        XCTAssertEqual(settings.overlayLayout, OverlayElement.defaultLayout)
        XCTAssertFalse(settings.overlayCompact)
        XCTAssertEqual(settings.overlayOpacity, 0.95, accuracy: 0.0001)
        XCTAssertTrue(settings.overlayAlwaysOnTop)
        XCTAssertTrue(settings.overlayShowOnAllSpaces)
        XCTAssertFalse(settings.overlayHideWhenIdle)
        XCTAssertTrue(settings.overlayEnabled, "visibility is unchanged")
        XCTAssertEqual(AppSettings(defaults: defaults).overlayLayout, OverlayElement.defaultLayout, "reset is persisted")
    }

    // MARK: - Grid persistence (round 4)

    @MainActor
    func testFreshInstallWritesDefaultGridAndMirror() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayGrid, .defaultLayout)
        XCTAssertEqual(storedGrid(defaults), .defaultLayout, "the grid is written as JSON Data")
        XCTAssertEqual(mirror(defaults), OverlayElement.defaultLayout.map(\.rawValue), "the mirror is written")
    }

    @MainActor
    func testListKeyAloneMigratesToGrid() {
        let defaults = makeDefaults()
        defaults.set(["takeaway", "todayTotal", "timer"], forKey: Self.layoutKey)
        let settings = AppSettings(defaults: defaults)
        let expected = OverlayGridLayout.migrated(from: [.takeaway, .todayTotal, .timer])
        XCTAssertEqual(settings.overlayGrid, expected)
        XCTAssertEqual(settings.overlayLayout, [.takeaway, .todayTotal, .timer])
        XCTAssertEqual(storedGrid(defaults), expected, "the migrated grid is written")
        XCTAssertEqual(mirror(defaults), ["takeaway", "todayTotal", "timer"])
    }

    @MainActor
    func testLegacyBooleansMigrateToGridWithoutLoss() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "settings.overlayShowSplitButton")
        defaults.set(true, forKey: "settings.overlayShowTodayTotal")
        let settings = AppSettings(defaults: defaults)
        let expected: [OverlayElement] = [.label, .timer, .segmentFocus, .controls, .todayTotal, .note, .takeaway]
        XCTAssertEqual(settings.overlayLayout, expected)
        XCTAssertEqual(settings.overlayGrid.elements, Set(expected), "no element lost")
        XCTAssertEqual(settings.overlayGrid.placement(of: .todayTotal),
                       OverlayPlacement(element: .todayTotal, row: 3, column: 4, span: 2), "trailing, as before")
        XCTAssertEqual(storedGrid(defaults), settings.overlayGrid)
        XCTAssertEqual(defaults.object(forKey: "settings.overlayShowSplitButton") as? Bool, false, "legacy key untouched")
    }

    @MainActor
    func testStoredGridWinsWhenMatchingMirror() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).overlayGrid = customGrid
        XCTAssertEqual(AppSettings(defaults: defaults).overlayGrid, customGrid,
                       "free columns and resized spans survive a reload")

        // No mirror at all: the grid is used too (and the mirror is rewritten).
        defaults.removeObject(forKey: Self.layoutKey)
        XCTAssertEqual(AppSettings(defaults: defaults).overlayGrid, customGrid)
        XCTAssertEqual(mirror(defaults), customGrid.readingOrder.map(\.rawValue))
    }

    @MainActor
    func testMirrorChangedByOlderBuildIsReMigrated() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).overlayGrid = customGrid
        // A round-3 build edits only the list.
        defaults.set(["note", "timer"], forKey: Self.layoutKey)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayGrid, OverlayGridLayout.migrated(from: [.note, .timer]))
        XCTAssertEqual(storedGrid(defaults), OverlayGridLayout.migrated(from: [.note, .timer]), "re-persisted")
    }

    @MainActor
    func testCorruptGridFallsBackToList() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).overlayGrid = customGrid
        defaults.set(Data("not json".utf8), forKey: Self.gridKey)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayGrid.elements, customGrid.elements, "the visible set is unchanged")
        XCTAssertEqual(settings.overlayLayout, customGrid.readingOrder)
        XCTAssertEqual(settings.overlayGrid, OverlayGridLayout.migrated(from: customGrid.readingOrder))
        XCTAssertEqual(storedGrid(defaults), settings.overlayGrid, "a valid grid is written again")
    }

    @MainActor
    func testLaunchDoesNotRewriteStoredGrid() {
        let defaults = makeDefaults()
        let json = #"{"columns":6,"formatVersion":2,"future":"x","placements":[{"column":1,"element":"timer","row":1,"span":5}]}"#
        let data = Data(json.utf8)
        defaults.set(data, forKey: Self.gridKey)
        defaults.set(["timer"], forKey: Self.layoutKey)

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.overlayGrid.placements,
                       [OverlayPlacement(element: .timer, row: 1, column: 1, span: 5)])
        XCTAssertEqual(defaults.data(forKey: Self.gridKey), data, "byte-identical, unknown field kept")
        XCTAssertEqual(mirror(defaults), ["timer"])
    }

    @MainActor
    func testEmptyGridPersistsAsEmpty() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).overlayGrid = .empty
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.overlayGrid, .empty)
        XCTAssertEqual(reloaded.overlayLayout, [])
        XCTAssertEqual(mirror(defaults), [])
    }

    @MainActor
    func testSettingOverlayLayoutRebuildsGrid() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.overlayLayout = [.todayTotal, .note]
        XCTAssertEqual(settings.overlayGrid, OverlayGridLayout.migrated(from: [.todayTotal, .note]))
        XCTAssertEqual(settings.overlayGrid.placements, [
            OverlayPlacement(element: .todayTotal, row: 0, column: 4, span: 2),
            OverlayPlacement(element: .note, row: 1, column: 0, span: 6),
        ])
        XCTAssertEqual(storedGrid(defaults), settings.overlayGrid)
    }

    @MainActor
    func testResetsPersistDefaultGrid() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.overlayGrid = customGrid
        settings.resetOverlayLayout()
        XCTAssertEqual(settings.overlayGrid, .defaultLayout)
        XCTAssertEqual(storedGrid(defaults), .defaultLayout)

        settings.overlayGrid = .empty
        settings.resetOverlayDefaults()
        XCTAssertEqual(settings.overlayGrid, .defaultLayout)
        XCTAssertEqual(storedGrid(defaults), .defaultLayout)
        XCTAssertEqual(mirror(defaults), OverlayElement.defaultLayout.map(\.rawValue))
    }

    @MainActor
    func testGridEditsUpdateMirror() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.overlayGrid = settings.overlayGrid.moving(.split, toRow: 0, column: 5)
        XCTAssertEqual(mirror(defaults), ["label", "split", "timer", "segmentFocus", "controls", "note", "takeaway"])
        XCTAssertEqual(storedGrid(defaults), settings.overlayGrid)
        XCTAssertTrue(settings.overlayShows(.split))
        XCTAssertFalse(settings.overlayShows(.todayTotal))
    }
}
