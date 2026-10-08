import AppKit
import SwiftUI
import XCTest
@testable import Worklog

final class ShortcutStoreTests: XCTestCase {

    private static let overridesKey = "shortcuts.overrides"

    /// A fresh, empty UserDefaults suite, removed again when the test ends.
    private func makeDefaults() -> UserDefaults {
        let name = "ShortcutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private let commandShiftS = StoredShortcut(key: "s", modifiers: [.command, .shift])
    private let commandShiftP = StoredShortcut(key: "p", modifiers: [.command, .shift])
    private let controlOptionK = StoredShortcut(key: "k", modifiers: [.control, .option])

    // MARK: - Defaults and display strings

    @MainActor
    func testDefaultsAndDisplayStrings() {
        let store = ShortcutStore(defaults: makeDefaults())

        XCTAssertEqual(store.stored(for: .startStop), commandShiftS)
        XCTAssertEqual(store.displayString(for: .startStop), "\u{21E7}\u{2318}S")     // ⇧⌘S
        XCTAssertEqual(store.displayString(for: .saveReview), "\u{2318}\u{21A9}")     // ⌘↩
        XCTAssertEqual(store.displayString(for: .showToday), "\u{2318}1")             // ⌘1
        XCTAssertEqual(store.displayString(for: .findInHistory), "\u{2318}F")         // ⌘F
        XCTAssertEqual(store.displayString(for: .toggleOverlay), "\u{21E7}\u{2318}O") // ⇧⌘O

        // Discard Session has no default shortcut.
        XCTAssertNil(store.stored(for: .discardSession))
        XCTAssertNil(store.shortcut(for: .discardSession))
        XCTAssertNil(store.displayString(for: .discardSession))

        let startStop = store.shortcut(for: .startStop)
        XCTAssertEqual(startStop?.key, KeyEquivalent("s"))
        XCTAssertEqual(startStop?.modifiers, [.command, .shift])
        XCTAssertEqual(store.shortcut(for: .saveReview)?.key, KeyEquivalent.return)

        XCTAssertFalse(store.hasCustomizations)
        for action in ShortcutAction.allCases {
            XCTAssertTrue(store.isDefault(action), "\(action) starts at its default")
        }
    }

    @MainActor
    func testDefaultsAreUniqueAndNotReserved() {
        let defaults = ShortcutAction.allCases.compactMap(\.defaultShortcut)
        XCTAssertEqual(Set(defaults).count, defaults.count, "no two actions share a default")
        for shortcut in defaults {
            XCTAssertFalse(ShortcutStore.reservedShortcuts.contains(shortcut), "\(shortcut.displayString) is reserved")
        }
    }

    func testGroupsCoverEveryAction() {
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.group == .session },
                       [.startStop, .pauseResume, .addNote, .splitSegment, .discardSession, .toggleOverlay])
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.group == .navigation },
                       [.showToday, .showHistory, .showLearning, .showStats, .nextProfile])
        XCTAssertNil(ShortcutAction.nextProfile.defaultShortcut, "Next Profile has no default shortcut")
        XCTAssertEqual(ShortcutAction.nextProfile.title, "Switch to Next Profile")
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.group == .editing }, [.findInHistory, .saveReview])
    }

    // MARK: - StoredShortcut

    func testStoredShortcutNormalizesAndFormats() {
        let upper = StoredShortcut(key: "S", modifiers: [.command, .capsLock])
        XCTAssertEqual(upper.key, "s", "letters are stored lowercase")
        XCTAssertEqual(upper.eventModifiers, .command, "only ⌃⌥⇧⌘ are kept")
        XCTAssertEqual(upper.displayString, "\u{2318}S")

        let all = StoredShortcut(key: "upArrow", modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(all.displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}\u{2191}")  // ⌃⌥⇧⌘↑
        XCTAssertEqual(all.keyboardShortcut?.key, KeyEquivalent.upArrow)

        XCTAssertTrue(StoredShortcut.none.isNone)
        XCTAssertEqual(StoredShortcut.none.displayString, "")
        XCTAssertNil(StoredShortcut.none.keyboardShortcut)
        XCTAssertNil(StoredShortcut(key: "bogus", modifiers: .command).keyboardShortcut, "invalid key")
    }

    func testStoredShortcutCodableRoundTrip() throws {
        let original = StoredShortcut(key: "return", modifiers: [.command, .option])
        let decoded = try JSONDecoder().decode(StoredShortcut.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    @MainActor
    func testStoredShortcutFromEvent() throws {
        // Special keys come from the key code, so this doesn't depend on the keyboard layout.
        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertEqual(StoredShortcut(event: returnEvent), StoredShortcut(key: "return", modifiers: [.command, .shift]))

        // F5 (a function key) is unsupported.
        let f5 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .function], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{F708}", charactersIgnoringModifiers: "\u{F708}", isARepeat: false,
            keyCode: 96))
        XCTAssertNil(StoredShortcut(event: f5))
    }

    // MARK: - Validation

    @MainActor
    func testValidationRejectsConflictsReservedAndMissingModifiers() {
        let store = ShortcutStore(defaults: makeDefaults())

        // Conflict with another action's effective shortcut.
        XCTAssertEqual(store.validate(commandShiftP, for: .startStop), .conflict(.pauseResume))
        XCTAssertEqual(store.set(commandShiftP, for: .startStop), .conflict(.pauseResume))
        XCTAssertEqual(store.stored(for: .startStop), commandShiftS, "a rejected shortcut isn't written")
        XCTAssertEqual(ShortcutValidation.conflict(.pauseResume).message, "Used by Pause / Resume.")

        // Reserved by macOS.
        XCTAssertEqual(store.set(StoredShortcut(key: "q", modifiers: .command), for: .startStop), .reserved)
        XCTAssertEqual(store.validate(StoredShortcut(key: ",", modifiers: .command), for: .addNote), .reserved)
        XCTAssertEqual(ShortcutValidation.reserved.message, "Reserved by macOS.")
        XCTAssertEqual(store.validate(StoredShortcut(key: "space", modifiers: [.control, .command]), for: .addNote),
                       .reserved, "⌃⌘Space opens Emoji & Symbols")
        XCTAssertEqual(store.validate(StoredShortcut(key: "w", modifiers: [.option, .command]), for: .addNote), .reserved)
        XCTAssertEqual(store.validate(StoredShortcut(key: "m", modifiers: [.option, .command]), for: .addNote), .reserved)

        // ⇧ only with a letter or a special key.
        XCTAssertEqual(store.set(StoredShortcut(key: "1", modifiers: [.shift, .command]), for: .startStop),
                       .shiftNeedsLetter)
        XCTAssertEqual(store.validate(StoredShortcut(key: "=", modifiers: [.shift, .command]), for: .addNote),
                       .shiftNeedsLetter)
        XCTAssertEqual(store.validate(StoredShortcut(key: "k", modifiers: [.shift, .control]), for: .addNote), .ok)
        XCTAssertEqual(store.validate(StoredShortcut(key: "return", modifiers: [.shift, .command]), for: .addNote), .ok)
        XCTAssertEqual(store.validate(StoredShortcut(key: "1", modifiers: [.option, .command]), for: .addNote), .ok,
                       "digits are fine without ⇧")
        XCTAssertEqual(ShortcutValidation.shiftNeedsLetter.message, "Use \u{21E7} with a letter.")

        // Needs ⌘ or ⌃.
        XCTAssertEqual(store.set(StoredShortcut(key: "s", modifiers: []), for: .startStop), .needsModifier)
        XCTAssertEqual(store.set(StoredShortcut(key: "s", modifiers: .option), for: .startStop), .needsModifier)
        XCTAssertEqual(store.validate(StoredShortcut(key: "s", modifiers: .shift), for: .startStop), .needsModifier)
        XCTAssertEqual(ShortcutValidation.needsModifier.message, "Include \u{2318} or \u{2303}.")

        // Re-assigning an action its current shortcut is fine; ⌃ alone counts as a modifier.
        XCTAssertEqual(store.validate(commandShiftS, for: .startStop), .ok)
        XCTAssertEqual(store.validate(controlOptionK, for: .startStop), .ok)
        XCTAssertNil(ShortcutValidation.ok.message)

        XCTAssertFalse(store.hasCustomizations, "nothing was written")
    }

    @MainActor
    func testSetCustomShortcut() {
        let store = ShortcutStore(defaults: makeDefaults())

        XCTAssertEqual(store.set(controlOptionK, for: .startStop), .ok)
        XCTAssertEqual(store.stored(for: .startStop), controlOptionK)
        XCTAssertEqual(store.displayString(for: .startStop), "\u{2303}\u{2325}K")
        XCTAssertFalse(store.isDefault(.startStop))
        XCTAssertTrue(store.hasCustomizations)

        // The old default is free now and can go to another action.
        XCTAssertEqual(store.set(commandShiftS, for: .discardSession), .ok)
        XCTAssertEqual(store.displayString(for: .discardSession), "\u{21E7}\u{2318}S")
        // …and is now taken.
        XCTAssertEqual(store.validate(commandShiftS, for: .startStop), .conflict(.discardSession))
    }

    // MARK: - Clearing, defaults and reset

    @MainActor
    func testClearingPersistsNoneAndReloadsAsNil() throws {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)

        XCTAssertEqual(store.set(nil, for: .startStop), .ok)
        XCTAssertNil(store.stored(for: .startStop))
        XCTAssertNil(store.shortcut(for: .startStop))
        XCTAssertNil(store.displayString(for: .startStop))
        XCTAssertFalse(store.isDefault(.startStop))

        XCTAssertEqual(store.set(StoredShortcut.none, for: .findInHistory), .ok, "StoredShortcut.none clears too")
        XCTAssertNil(store.shortcut(for: .findInHistory))

        let data = try XCTUnwrap(defaults.data(forKey: Self.overridesKey))
        let stored = try JSONDecoder().decode([String: StoredShortcut].self, from: data)
        XCTAssertEqual(stored["startStop"], StoredShortcut.none)
        XCTAssertEqual(stored["findInHistory"], StoredShortcut.none)

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertNil(reloaded.stored(for: .startStop))
        XCTAssertNil(reloaded.shortcut(for: .startStop))
        XCTAssertNil(reloaded.shortcut(for: .findInHistory))
        XCTAssertFalse(reloaded.isDefault(.startStop))
    }

    @MainActor
    func testClearingAnActionWithoutDefaultIsTheDefault() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.set(nil, for: .discardSession)
        XCTAssertTrue(store.isDefault(.discardSession))
        XCTAssertFalse(store.hasCustomizations)
    }

    @MainActor
    func testSettingTheDefaultRemovesTheOverride() {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)

        store.set(controlOptionK, for: .startStop)
        XCTAssertNotNil(defaults.data(forKey: Self.overridesKey))

        XCTAssertEqual(store.set(StoredShortcut(key: "S", modifiers: [.shift, .command]), for: .startStop), .ok)
        XCTAssertTrue(store.isDefault(.startStop))
        XCTAssertFalse(store.hasCustomizations)
        XCTAssertNil(defaults.data(forKey: Self.overridesKey), "no overrides → nothing stored")
    }

    @MainActor
    func testResetAndResetAll() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.set(controlOptionK, for: .startStop)
        store.set(nil, for: .showStats)
        store.set(StoredShortcut(key: "j", modifiers: [.command, .option]), for: .addNote)
        XCTAssertTrue(store.hasCustomizations)

        XCTAssertNil(store.reset(.startStop), "nobody else held ⇧⌘S")
        XCTAssertTrue(store.isDefault(.startStop))
        XCTAssertEqual(store.stored(for: .startStop), commandShiftS)
        XCTAssertTrue(store.hasCustomizations, "the other overrides remain")

        store.resetAll()
        XCTAssertFalse(store.hasCustomizations)
        for action in ShortcutAction.allCases {
            XCTAssertTrue(store.isDefault(action))
            XCTAssertEqual(store.stored(for: action), action.defaultShortcut)
        }
    }

    @MainActor
    func testResetWinsOverAnActionThatTookTheDefault() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.set(controlOptionK, for: .startStop)
        XCTAssertEqual(store.set(commandShiftS, for: .pauseResume), .ok)

        XCTAssertEqual(store.reset(.startStop), .pauseResume, "reset reports the action that lost its shortcut")
        XCTAssertEqual(store.stored(for: .startStop), commandShiftS)
        XCTAssertNil(store.stored(for: .pauseResume), "the other action is cleared, so no two actions share a shortcut")
        XCTAssertFalse(store.isDefault(.pauseResume))

        // An action without a default that took the shortcut goes back to its (empty) default.
        store.set(controlOptionK, for: .startStop)
        XCTAssertEqual(store.set(commandShiftS, for: .discardSession), .ok)
        XCTAssertEqual(store.reset(.startStop), .discardSession)
        XCTAssertNil(store.stored(for: .discardSession))
        XCTAssertTrue(store.isDefault(.discardSession))
    }

    @MainActor
    func testResetOfActionWithoutDefaultAffectsNobody() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.set(controlOptionK, for: .discardSession)
        XCTAssertNil(store.reset(.discardSession))
        XCTAssertNil(store.stored(for: .discardSession))
        XCTAssertEqual(store.stored(for: .startStop), commandShiftS)
    }

    // MARK: - Persistence

    @MainActor
    func testOverridesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)
        store.set(controlOptionK, for: .startStop)
        store.set(StoredShortcut(key: "return", modifiers: [.command, .shift]), for: .saveReview)
        store.set(nil, for: .toggleOverlay)

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.stored(for: .startStop), controlOptionK)
        XCTAssertEqual(reloaded.displayString(for: .saveReview), "\u{21E7}\u{2318}\u{21A9}")
        XCTAssertNil(reloaded.shortcut(for: .toggleOverlay))
        XCTAssertTrue(reloaded.isDefault(.pauseResume))

        reloaded.resetAll()
        XCTAssertFalse(ShortcutStore(defaults: defaults).hasCustomizations)
    }

    @MainActor
    func testUnknownKeysAndUndecodableDataAreIgnored() throws {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: Self.overridesKey)
        XCTAssertFalse(ShortcutStore(defaults: defaults).hasCustomizations)

        let custom = StoredShortcut(key: "n", modifiers: [.command, .control])
        let payload: [String: StoredShortcut] = ["bogusAction": controlOptionK, "addNote": custom]
        defaults.set(try JSONEncoder().encode(payload), forKey: Self.overridesKey)
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.stored(for: .addNote), custom)
        XCTAssertEqual(ShortcutAction.allCases.filter { !store.isDefault($0) }, [.addNote])
    }

    @MainActor
    func testLoadDeduplicatesConflictingOverrides() throws {
        let defaults = makeDefaults()
        // Two overrides share ⌃⌥K, and Show Stats' override takes Start / Stop's default ⇧⌘S.
        let payload: [String: StoredShortcut] = [
            "addNote": controlOptionK,
            "saveReview": controlOptionK,
            "showStats": commandShiftS,
            "discardSession": commandShiftP,
        ]
        defaults.set(try JSONEncoder().encode(payload), forKey: Self.overridesKey)
        let store = ShortcutStore(defaults: defaults)

        // Earlier actions (allCases order) keep their shortcut; later duplicates are cleared.
        XCTAssertEqual(store.stored(for: .addNote), controlOptionK)
        XCTAssertNil(store.stored(for: .saveReview))
        XCTAssertEqual(store.stored(for: .startStop), commandShiftS)
        XCTAssertNil(store.stored(for: .showStats))
        XCTAssertEqual(store.stored(for: .pauseResume), commandShiftP)
        XCTAssertNil(store.stored(for: .discardSession))
        XCTAssertTrue(store.isDefault(.discardSession), "no default, so cleared means default")

        let effective = ShortcutAction.allCases.compactMap { store.stored(for: $0) }
        XCTAssertEqual(Set(effective).count, effective.count, "no two actions share a shortcut after loading")
    }
}
