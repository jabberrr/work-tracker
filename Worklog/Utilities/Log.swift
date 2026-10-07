import os

/// Unified logging categories. Use e.g. `Log.engine.error("…")`.
enum Log {
    static let persistence = Logger(subsystem: AppConstants.bundleID, category: "persistence")
    static let engine = Logger(subsystem: AppConstants.bundleID, category: "engine")
    static let backup = Logger(subsystem: AppConstants.bundleID, category: "backup")
    static let auth = Logger(subsystem: AppConstants.bundleID, category: "auth")
    static let ui = Logger(subsystem: AppConstants.bundleID, category: "ui")
}
