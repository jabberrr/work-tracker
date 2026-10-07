import os

/// Unified logging categories. Use e.g. `Log.engine.error("…")`.
/// Privacy: interpolate user content (names, titles, notes, filenames, paths) with `privacy: .private`; only counts,
/// enum values, error descriptions and app-generated file names may be `.public`.
enum Log {
    static let persistence = Logger(subsystem: AppConstants.bundleID, category: "persistence")
    static let engine = Logger(subsystem: AppConstants.bundleID, category: "engine")
    static let backup = Logger(subsystem: AppConstants.bundleID, category: "backup")
    static let auth = Logger(subsystem: AppConstants.bundleID, category: "auth")
    static let ui = Logger(subsystem: AppConstants.bundleID, category: "ui")
    static let sync = Logger(subsystem: AppConstants.bundleID, category: "sync")
}
