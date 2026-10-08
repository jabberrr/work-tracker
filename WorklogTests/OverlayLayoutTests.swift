import XCTest
@testable import Worklog

final class OverlayLayoutTests: XCTestCase {

    private static let layoutKey = "settings.overlayLayout"

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
}
