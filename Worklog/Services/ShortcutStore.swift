import AppKit
import Observation
import SwiftUI

enum ShortcutGroup: String, CaseIterable, Identifiable {
    case session, navigation, editing

    var id: String { rawValue }

    /// "Session", "Navigation", "Editing"
    var title: String {
        switch self {
        case .session: "Session"
        case .navigation: "Navigation"
        case .editing: "Editing"
        }
    }
}

/// Every app-defined shortcut. Titles are also the Settings row titles.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case startStop, pauseResume, addNote, splitSegment, discardSession, toggleOverlay   // .session (menu "Session")
    case showToday, showHistory, showLearning, showStats, nextProfile                 // .navigation (View menu)
    case findInHistory, saveReview                                                    // .editing (in-view)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startStop: "Start / Stop Session"
        case .pauseResume: "Pause / Resume"
        case .addNote: "Add Note"
        case .splitSegment: "Split Segment"
        case .discardSession: "Discard Session"
        case .toggleOverlay: "Toggle Overlay"
        case .showToday: "Show Today"
        case .showHistory: "Show History"
        case .showLearning: "Show Learning"
        case .showStats: "Show Stats"
        case .nextProfile: "Switch to Next Profile"
        case .findInHistory: "Find in History"
        case .saveReview: "Save Session Review"
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .startStop, .pauseResume, .addNote, .splitSegment, .discardSession, .toggleOverlay: .session
        case .showToday, .showHistory, .showLearning, .showStats, .nextProfile: .navigation
        case .findInHistory, .saveReview: .editing
        }
    }

    /// ⇧⌘S, ⇧⌘P, ⇧⌘N, ⇧⌘D, nil, ⇧⌘O, ⌘1, ⌘2, ⌘3, ⌘4, nil (next profile), ⌘F, ⌘↩
    var defaultShortcut: StoredShortcut? {
        switch self {
        case .startStop: StoredShortcut(key: "s", modifiers: [.command, .shift])
        case .pauseResume: StoredShortcut(key: "p", modifiers: [.command, .shift])
        case .addNote: StoredShortcut(key: "n", modifiers: [.command, .shift])
        case .splitSegment: StoredShortcut(key: "d", modifiers: [.command, .shift])
        case .discardSession: nil
        case .toggleOverlay: StoredShortcut(key: "o", modifiers: [.command, .shift])
        case .showToday: StoredShortcut(key: "1", modifiers: .command)
        case .showHistory: StoredShortcut(key: "2", modifiers: .command)
        case .showLearning: StoredShortcut(key: "3", modifiers: .command)
        case .showStats: StoredShortcut(key: "4", modifiers: .command)
        case .nextProfile: nil
        case .findInHistory: StoredShortcut(key: "f", modifiers: .command)
        case .saveReview: StoredShortcut(key: "return", modifiers: .command)
        }
    }
}

/// Persistable shortcut.
/// `key`:
/// - one lowercase character ("s", "1", ",", "/"), or
/// - a token: "return", "escape", "delete", "deleteForward", "tab", "space", "upArrow", "downArrow",
///   "leftArrow", "rightArrow", "home", "end", "pageUp", "pageDown".
/// `modifiers`: an `EventModifiers.rawValue` limited to .command | .shift | .option | .control.
/// `key == ""` is the sentinel for "explicitly no shortcut".
struct StoredShortcut: Codable, Hashable {
    var key: String
    var modifiers: Int

    /// Single characters are lowercased (`KeyEquivalent("S")` would imply Shift); modifiers are limited to ⌃⌥⇧⌘.
    init(key: String, modifiers: EventModifiers) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers.intersection(StoredShortcut.supportedModifiers).rawValue
    }

    /// Explicitly no shortcut (key "", modifiers 0).
    static let none = StoredShortcut(key: "", modifiers: [])

    var isNone: Bool { key.isEmpty }

    var eventModifiers: EventModifiers {
        EventModifiers(rawValue: modifiers).intersection(Self.supportedModifiers)
    }

    /// nil for `.none` or an invalid key.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    /// "⌃⌥⇧⌘S" order; letters uppercased; tokens → ↩ ⎋ ⌫ ⌦ ⇥ Space ← → ↑ ↓ ↖ ↘ ⇞ ⇟; "" for .none.
    var displayString: String {
        guard !isNone else { return "" }
        let mods = eventModifiers
        var text = ""
        if mods.contains(.control) { text += "\u{2303}" }   // ⌃
        if mods.contains(.option) { text += "\u{2325}" }    // ⌥
        if mods.contains(.shift) { text += "\u{21E7}" }     // ⇧
        if mods.contains(.command) { text += "\u{2318}" }   // ⌘
        if let token = Self.tokens[key] {
            text += token.glyph
        } else {
            text += key.uppercased()
        }
        return text
    }

    /// From a keyDown event: key from `event.keyCode` for special keys, else
    /// `event.characters(byApplyingModifiers: [])?.lowercased()` (NOT charactersIgnoringModifiers: that applies Shift).
    /// nil for unsupported keys (F-keys, keypad-only, empty).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        if let token = StoredShortcut.specialKeyCodes[event.keyCode] {
            self.init(key: token, modifiers: mods)
            return
        }
        // F-keys and other function keys (.function), keypad keys (.numericPad; the arrows were handled above).
        if flags.contains(.function) || flags.contains(.numericPad) { return nil }
        guard let characters = event.characters(byApplyingModifiers: [])?.lowercased(),
              characters.count == 1,
              let character = characters.first,
              !character.isWhitespace,
              !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              // AppKit's function-key range (U+F700…U+F8FF) is never a valid key equivalent character here.
              !character.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        self.init(key: String(character), modifiers: mods)
    }

    // MARK: Private

    private static let supportedModifiers: EventModifiers = [.command, .shift, .option, .control]

    private var keyEquivalent: KeyEquivalent? {
        if let token = Self.tokens[key] { return token.equivalent }
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    private static let tokens: [String: (equivalent: KeyEquivalent, glyph: String)] = [
        "return": (.return, "\u{21A9}"),          // ↩
        "escape": (.escape, "\u{238B}"),          // ⎋
        "delete": (.delete, "\u{232B}"),          // ⌫
        "deleteForward": (.deleteForward, "\u{2326}"), // ⌦
        "tab": (.tab, "\u{21E5}"),                // ⇥
        "space": (.space, "Space"),
        "leftArrow": (.leftArrow, "\u{2190}"),    // ←
        "rightArrow": (.rightArrow, "\u{2192}"),  // →
        "upArrow": (.upArrow, "\u{2191}"),        // ↑
        "downArrow": (.downArrow, "\u{2193}"),    // ↓
        "home": (.home, "\u{2196}"),              // ↖
        "end": (.end, "\u{2198}"),                // ↘
        "pageUp": (.pageUp, "\u{21DE}"),          // ⇞
        "pageDown": (.pageDown, "\u{21DF}"),      // ⇟
    ]

    /// Virtual key codes (Carbon kVK_*) of the token keys. Keypad Enter (76) is keypad-only and unsupported.
    private static let specialKeyCodes: [UInt16: String] = [
        36: "return",
        53: "escape",
        51: "delete",
        117: "deleteForward",
        48: "tab",
        49: "space",
        123: "leftArrow",
        124: "rightArrow",
        125: "downArrow",
        126: "upArrow",
        115: "home",
        119: "end",
        116: "pageUp",
        121: "pageDown",
    ]
}

enum ShortcutValidation: Equatable {
    case ok
    case needsModifier                     // "Include ⌘ or ⌃."
    case reserved                          // "Reserved by macOS."
    /// ⇧ with a digit or symbol (⇧⌘1, ⇧⌘=): menus match the shifted character, so it may never fire.
    case shiftNeedsLetter                  // "Use ⇧ with a letter."
    case conflict(ShortcutAction)          // "Used by \(action.title)."

    /// nil for .ok
    var message: String? {
        switch self {
        case .ok: nil
        case .needsModifier: "Include \u{2318} or \u{2303}."
        case .reserved: "Reserved by macOS."
        case .shiftNeedsLetter: "Use \u{21E7} with a letter."
        case .conflict(let action): "Used by \(action.title)."
        }
    }
}

/// The user's shortcut overrides on top of `ShortcutAction.defaultShortcut`.
/// Persisted under "shortcuts.overrides" as JSON `[String: StoredShortcut]` keyed by `ShortcutAction.rawValue`;
/// only overrides are stored, and a cleared action stores `StoredShortcut.none`.
@MainActor @Observable
final class ShortcutStore {
    private static let overridesKey = "shortcuts.overrides"

    private let defaults: UserDefaults
    private var overrides: [ShortcutAction: StoredShortcut]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = Self.load(from: defaults)
    }

    /// Effective shortcut: override (nil if the override is .none) else default.
    func stored(for action: ShortcutAction) -> StoredShortcut? {
        if let override = overrides[action] {
            return override.isNone ? nil : override
        }
        return action.defaultShortcut
    }

    /// For `.keyboardShortcut(_:)` (the optional overload, macOS 12.3+).
    func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        stored(for: action)?.keyboardShortcut
    }

    /// "⇧⌘S", or nil when unassigned.
    func displayString(for action: ShortcutAction) -> String? {
        guard let shortcut = stored(for: action), !shortcut.isNone else { return nil }
        return shortcut.displayString
    }

    func isDefault(_ action: ShortcutAction) -> Bool {
        overrides[action] == nil
    }

    var hasCustomizations: Bool { !overrides.isEmpty }

    /// Rules, in order:
    /// 1. modifiers must contain .command or .control → else .needsModifier
    /// 2. not in reservedShortcuts → else .reserved
    /// 3. ⇧ only with a letter or a token key (↩, arrows…), not a digit or symbol → else .shiftNeedsLetter
    /// 4. not equal to another action's effective shortcut → else .conflict(other)
    /// Re-assigning an action its current shortcut is .ok. `.none` (clearing) is always .ok.
    func validate(_ shortcut: StoredShortcut, for action: ShortcutAction) -> ShortcutValidation {
        let candidate = Self.normalized(shortcut)
        guard !candidate.isNone else { return .ok }
        let mods = candidate.eventModifiers
        guard mods.contains(.command) || mods.contains(.control) else { return .needsModifier }
        guard !Self.reservedShortcuts.contains(candidate) else { return .reserved }
        if mods.contains(.shift), candidate.key.count == 1, let character = candidate.key.first, !character.isLetter {
            return .shiftNeedsLetter
        }
        if let other = holder(of: candidate, excluding: action) {
            return .conflict(other)
        }
        return .ok
    }

    /// nil or .none clears (always ok). Otherwise validates and writes only on .ok.
    /// Setting a value equal to the default removes the override.
    @discardableResult
    func set(_ shortcut: StoredShortcut?, for action: ShortcutAction) -> ShortcutValidation {
        guard let shortcut, !shortcut.isNone else {
            // Discard Session has no default, so clearing it is the default state.
            overrides[action] = action.defaultShortcut == nil ? nil : StoredShortcut.none
            persist()
            return .ok
        }
        let candidate = Self.normalized(shortcut)
        let result = validate(candidate, for: action)
        guard result == .ok else { return result }
        overrides[action] = candidate == action.defaultShortcut ? nil : candidate
        persist()
        return .ok
    }

    /// Back to the default. If another action has since taken that default, the other action is cleared
    /// (the reset wins), so no two actions ever share a shortcut.
    /// - Returns: the other action that lost its shortcut, or nil if none did.
    @discardableResult
    func reset(_ action: ShortcutAction) -> ShortcutAction? {
        overrides[action] = nil
        var affected: ShortcutAction?
        if let defaultShortcut = action.defaultShortcut,
           let other = holder(of: defaultShortcut, excluding: action) {
            overrides[other] = other.defaultShortcut == nil ? nil : StoredShortcut.none
            affected = other
        }
        persist()
        return affected
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    /// Fixed shortcuts:
    /// - app/system: ⌘, ⌘Q ⌘W ⌥⌘W ⌘H ⌥⌘H ⌘M ⌥⌘M ⌃⌘F ⌃⌘S (Toggle Sidebar) ⌘` ⌃⌘Q ⌃⌘Space (Emoji & Symbols)
    /// - text editing: ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A
    /// - Help: ⇧⌘/
    static let reservedShortcuts: [StoredShortcut] = [
        StoredShortcut(key: ",", modifiers: .command),
        StoredShortcut(key: "q", modifiers: .command),
        StoredShortcut(key: "w", modifiers: .command),
        StoredShortcut(key: "w", modifiers: [.option, .command]),
        StoredShortcut(key: "h", modifiers: .command),
        StoredShortcut(key: "h", modifiers: [.option, .command]),
        StoredShortcut(key: "m", modifiers: .command),
        StoredShortcut(key: "m", modifiers: [.option, .command]),
        StoredShortcut(key: "f", modifiers: [.control, .command]),
        StoredShortcut(key: "s", modifiers: [.control, .command]),
        StoredShortcut(key: "`", modifiers: .command),
        StoredShortcut(key: "q", modifiers: [.control, .command]),
        StoredShortcut(key: "space", modifiers: [.control, .command]),
        StoredShortcut(key: "z", modifiers: .command),
        StoredShortcut(key: "z", modifiers: [.shift, .command]),
        StoredShortcut(key: "x", modifiers: .command),
        StoredShortcut(key: "c", modifiers: .command),
        StoredShortcut(key: "v", modifiers: .command),
        StoredShortcut(key: "a", modifiers: .command),
        StoredShortcut(key: "/", modifiers: [.shift, .command]),
    ]

    // MARK: - Private

    /// The other action whose effective shortcut equals `shortcut`.
    private func holder(of shortcut: StoredShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        let target = Self.normalized(shortcut)
        return ShortcutAction.allCases.first { other in
            other != action && stored(for: other).map { Self.normalized($0) } == target
        }
    }

    /// Re-applies the init normalization (lowercase single character, ⌃⌥⇧⌘ only) to values built or decoded elsewhere.
    private static func normalized(_ shortcut: StoredShortcut) -> StoredShortcut {
        StoredShortcut(key: shortcut.key, modifiers: shortcut.eventModifiers)
    }

    /// Unknown actions and undecodable data are ignored; overrides equal to the default are dropped.
    /// Duplicates (e.g. data edited by hand or written by another version) are resolved in `allCases` order:
    /// an action whose effective shortcut equals an earlier action's is cleared, so no two actions share one.
    private static func load(from defaults: UserDefaults) -> [ShortcutAction: StoredShortcut] {
        guard let data = defaults.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: StoredShortcut].self, from: data)
        else { return [:] }
        var result: [ShortcutAction: StoredShortcut] = [:]
        for (rawValue, value) in decoded {
            guard let action = ShortcutAction(rawValue: rawValue) else { continue }
            let shortcut = normalized(value)
            if shortcut.isNone {
                if action.defaultShortcut != nil { result[action] = StoredShortcut.none }
            } else if shortcut != action.defaultShortcut {
                result[action] = shortcut
            }
        }
        var taken: Set<StoredShortcut> = []
        for action in ShortcutAction.allCases {
            let effective = result[action] ?? action.defaultShortcut
            guard let effective, !effective.isNone else { continue }
            if taken.contains(effective) {
                result[action] = action.defaultShortcut == nil ? nil : StoredShortcut.none
            } else {
                taken.insert(effective)
            }
        }
        return result
    }

    private func persist() {
        guard !overrides.isEmpty else {
            defaults.removeObject(forKey: Self.overridesKey)
            return
        }
        let encodable = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            defaults.set(try encoder.encode(encodable), forKey: Self.overridesKey)
        } catch {
            Log.ui.error("Saving shortcuts failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
