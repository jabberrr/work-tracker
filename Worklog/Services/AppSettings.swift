import Foundation
import Observation

enum BackupInterval: String, CaseIterable, Identifiable, Codable {
    case off, every15Minutes, hourly, every6Hours, daily
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .every15Minutes: "Every 15 minutes"
        case .hourly: "Hourly"
        case .every6Hours: "Every 6 hours"
        case .daily: "Daily"
        }
    }

    /// nil for .off
    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .every15Minutes: 15 * 60
        case .hourly: 60 * 60
        case .every6Hours: 6 * 60 * 60
        case .daily: 24 * 60 * 60
        }
    }
}

/// UserDefaults-backed app preferences. Every property writes through to `defaults` under "settings.<propertyName>".
@MainActor @Observable
final class AppSettings {
    /// The backing store (exposed so other CORE services persist their own small state next to the settings).
    let defaults: UserDefaults

    // MARK: General
    var defaultLabelID: UUID? = nil {
        didSet { defaults.set(defaultLabelID?.uuidString, forKey: Self.key("defaultLabelID")) }
    }
    var showMenuBarExtra: Bool { didSet { write(showMenuBarExtra, "showMenuBarExtra") } }
    var menuBarShowsTimer: Bool { didSet { write(menuBarShowsTimer, "menuBarShowsTimer") } }
    var menuBarShowLastTakeaway: Bool { didSet { write(menuBarShowLastTakeaway, "menuBarShowLastTakeaway") } }
    var showEndSessionSheet: Bool { didSet { write(showEndSessionSheet, "showEndSessionSheet") } }
    var confirmBeforeDiscard: Bool { didSet { write(confirmBeforeDiscard, "confirmBeforeDiscard") } }
    var pauseOnSleep: Bool { didSet { write(pauseOnSleep, "pauseOnSleep") } }
    var pauseOnQuit: Bool { didSet { write(pauseOnQuit, "pauseOnQuit") } }
    var longSessionWarningHours: Double { didSet { write(longSessionWarningHours, "longSessionWarningHours") } }
    var dailyGoalHours: Double { didSet { write(dailyGoalHours, "dailyGoalHours") } }
    var weekStartsOnMonday: Bool { didSet { write(weekStartsOnMonday, "weekStartsOnMonday") } }
    /// Applies at next launch (PersistenceController reads it once).
    var iCloudSyncEnabled: Bool { didSet { write(iCloudSyncEnabled, "iCloudSyncEnabled") } }
    /// true: a takeaway is shown only during the next session after it was written, and retired when that session's
    /// review completes. false: shown until a newer takeaway replaces it (or it is dismissed).
    var takeawayNextSessionOnly: Bool { didSet { write(takeawayNextSessionOnly, "takeawayNextSessionOnly") } }
    /// Switch to an accessory app (no Dock icon) while the main window is closed; the menu bar extra stays.
    var hideDockIconWhenClosed: Bool { didSet { write(hideDockIconWhenClosed, "hideDockIconWhenClosed") } }
    /// The local-only storage reason whose banner the user dismissed ("" = none). A different reason shows again.
    var dismissedLocalOnlyBannerReason: String {
        didSet { write(dismissedLocalOnlyBannerReason, "dismissedLocalOnlyBannerReason") }
    }

    // MARK: Overlay
    /// Source of truth for overlay visibility.
    var overlayEnabled: Bool { didSet { write(overlayEnabled, "overlayEnabled") } }
    /// Ordered elements the overlay shows. Persisted as [String] (raw values) under "settings.overlayLayout".
    /// Replaces the round-1 `overlayShow…` booleans (migrated once in `init`; the legacy keys are left untouched).
    var overlayLayout: [OverlayElement] { didSet { write(overlayLayout.map(\.rawValue), "overlayLayout") } }
    var overlayCompact: Bool { didSet { write(overlayCompact, "overlayCompact") } }
    /// Clamped to 0.4…1.0 on every write.
    var overlayOpacity: Double {
        get { storedOverlayOpacity }
        set {
            storedOverlayOpacity = Self.clampOpacity(newValue)
            write(storedOverlayOpacity, "overlayOpacity")
        }
    }
    var overlayAlwaysOnTop: Bool { didSet { write(overlayAlwaysOnTop, "overlayAlwaysOnTop") } }
    var overlayShowOnAllSpaces: Bool { didSet { write(overlayShowOnAllSpaces, "overlayShowOnAllSpaces") } }
    var overlayHideWhenIdle: Bool { didSet { write(overlayHideWhenIdle, "overlayHideWhenIdle") } }

    // MARK: Backups
    var backupInterval: BackupInterval { didSet { write(backupInterval.rawValue, "backupInterval") } }
    /// Clamped to 1…100 on every write.
    var backupRetentionCount: Int {
        get { storedBackupRetentionCount }
        set {
            storedBackupRetentionCount = Self.clampRetention(newValue)
            write(storedBackupRetentionCount, "backupRetentionCount")
        }
    }
    var backupIncludesAttachments: Bool { didSet { write(backupIncludesAttachments, "backupIncludesAttachments") } }

    // Backing storage for the clamped properties (observable, so views tracking the computed wrappers update).
    private var storedOverlayOpacity: Double
    private var storedBackupRetentionCount: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarExtra = Self.bool(defaults, "showMenuBarExtra", true)
        menuBarShowsTimer = Self.bool(defaults, "menuBarShowsTimer", true)
        menuBarShowLastTakeaway = Self.bool(defaults, "menuBarShowLastTakeaway", true)
        showEndSessionSheet = Self.bool(defaults, "showEndSessionSheet", true)
        confirmBeforeDiscard = Self.bool(defaults, "confirmBeforeDiscard", true)
        pauseOnSleep = Self.bool(defaults, "pauseOnSleep", true)
        pauseOnQuit = Self.bool(defaults, "pauseOnQuit", false)
        longSessionWarningHours = Self.double(defaults, "longSessionWarningHours", 10)
        dailyGoalHours = Self.double(defaults, "dailyGoalHours", 4)
        weekStartsOnMonday = Self.bool(defaults, "weekStartsOnMonday", true)
        iCloudSyncEnabled = Self.bool(defaults, "iCloudSyncEnabled", true)
        takeawayNextSessionOnly = Self.bool(defaults, "takeawayNextSessionOnly", true)
        hideDockIconWhenClosed = Self.bool(defaults, "hideDockIconWhenClosed", false)
        dismissedLocalOnlyBannerReason = defaults.string(forKey: Self.key("dismissedLocalOnlyBannerReason")) ?? ""

        overlayEnabled = Self.bool(defaults, "overlayEnabled", false)
        overlayLayout = Self.loadOverlayLayout(defaults)
        overlayCompact = Self.bool(defaults, "overlayCompact", false)
        storedOverlayOpacity = Self.clampOpacity(Self.double(defaults, "overlayOpacity", 0.95))
        overlayAlwaysOnTop = Self.bool(defaults, "overlayAlwaysOnTop", true)
        overlayShowOnAllSpaces = Self.bool(defaults, "overlayShowOnAllSpaces", true)
        overlayHideWhenIdle = Self.bool(defaults, "overlayHideWhenIdle", false)

        backupInterval = defaults.string(forKey: Self.key("backupInterval")).flatMap(BackupInterval.init(rawValue:)) ?? .hourly
        storedBackupRetentionCount = Self.clampRetention(Self.int(defaults, "backupRetentionCount", 10))
        backupIncludesAttachments = Self.bool(defaults, "backupIncludesAttachments", true)
        // Has an initial value, so it is assigned last (after every other stored property is initialized).
        defaultLabelID = defaults.string(forKey: Self.key("defaultLabelID")).flatMap(UUID.init(uuidString:))
        // Persist the (possibly migrated) layout right away so the legacy booleans are read only once.
        write(overlayLayout.map(\.rawValue), "overlayLayout")
    }

    /// overlayLayout.contains(element)
    func overlayShows(_ element: OverlayElement) -> Bool {
        overlayLayout.contains(element)
    }

    /// overlayLayout = OverlayElement.defaultLayout
    func resetOverlayLayout() {
        overlayLayout = OverlayElement.defaultLayout
    }

    /// Restores every overlay content/appearance option to its default. Visibility (`overlayEnabled`) is unchanged.
    func resetOverlayDefaults() {
        overlayLayout = OverlayElement.defaultLayout
        overlayCompact = false
        overlayOpacity = 0.95
        overlayAlwaysOnTop = true
        overlayShowOnAllSpaces = true
        overlayHideWhenIdle = false
    }

    // MARK: - Private helpers

    private static func key(_ property: String) -> String { "settings." + property }

    /// "settings.overlayLayout" when present (sanitized); otherwise built once from the round-1 booleans, in
    /// `OverlayElement.migrationOrder`, keeping each element whose legacy key is true (absent = its old default:
    /// on, except Today’s total). With untouched legacy defaults this is exactly `OverlayElement.defaultLayout`.
    private static func loadOverlayLayout(_ defaults: UserDefaults) -> [OverlayElement] {
        if let stored = defaults.array(forKey: key("overlayLayout")) as? [String] {
            return OverlayElement.sanitized(stored)
        }
        return OverlayElement.migrationOrder.filter { element in
            let legacy = legacyOverlayKey(element)
            return bool(defaults, legacy.property, legacy.fallback)
        }
    }

    /// The round-1 `overlayShow…` property name for an element and its default value.
    private static func legacyOverlayKey(_ element: OverlayElement) -> (property: String, fallback: Bool) {
        switch element {
        case .label: return ("overlayShowLabel", true)
        case .timer: return ("overlayShowTimer", true)
        case .segmentFocus: return ("overlayShowSegmentFocus", true)
        case .controls: return ("overlayShowControls", true)
        case .split: return ("overlayShowSplitButton", true)
        case .todayTotal: return ("overlayShowTodayTotal", false)
        case .note: return ("overlayShowNoteField", true)
        case .takeaway: return ("overlayShowLastTakeaway", true)
        }
    }

    private func write(_ value: Any, _ property: String) {
        defaults.set(value, forKey: Self.key(property))
    }

    private static func bool(_ defaults: UserDefaults, _ property: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key(property)) == nil ? fallback : defaults.bool(forKey: key(property))
    }

    private static func double(_ defaults: UserDefaults, _ property: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key(property)) == nil ? fallback : defaults.double(forKey: key(property))
    }

    private static func int(_ defaults: UserDefaults, _ property: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key(property)) == nil ? fallback : defaults.integer(forKey: key(property))
    }

    private static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.95 }
        return min(max(value, 0.4), 1.0)
    }

    private static func clampRetention(_ value: Int) -> Int { min(max(value, 1), 100) }
}
