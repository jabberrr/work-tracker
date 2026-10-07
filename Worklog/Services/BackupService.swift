import AppKit
import Foundation
import Observation
import SwiftData

enum BackupReason: String { case scheduled, onQuit, manual, beforeRestore }

struct BackupFile: Identifiable, Hashable {
    let url: URL; let date: Date; let sizeBytes: Int64; let reason: String
    var id: URL { url }
}

/// Rolling local JSON snapshots in Application Support/Worklog/Backups, plus restore.
@MainActor @Observable
final class BackupService {
    private(set) var lastBackupDate: Date? = nil
    private(set) var backups: [BackupFile] = []      // newest first
    private(set) var isWorking = false
    var lastError: String? = nil
    var backupsDirectory: URL { AppConstants.backupsURL }

    private static let filePrefix = "Worklog-Backup-"
    private static let dateFormat = "yyyy-MM-dd'T'HH-mm-ss"

    private let exporter: ExportService
    private let settings: AppSettings
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var isDirty = true
    @ObservationIgnored private var isScheduling = false

    init(exporter: ExportService, settings: AppSettings) {
        self.exporter = exporter
        self.settings = settings
        refreshList()
    }

    /// Observes ModelContext.didSave (marks dirty; starts dirty) and settings.backupInterval (withObservationTracking);
    /// schedules a repeating Timer; each fire: if dirty → backupNow(.scheduled).
    func startScheduling() {
        guard !isScheduling else { return }
        isScheduling = true
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.isDirty = true }
        }
        observeInterval()
    }

    /// Synchronous: archive (attachments per settings) → write
    /// "Worklog-Backup-yyyy-MM-dd'T'HH-mm-ss-<reason>.json" atomically → prune to backupRetentionCount → refresh list.
    ///
    /// Automatic backups (scheduled / on quit) are skipped while the store is in memory only (previews, tests, or a
    /// store that failed to open), so a broken launch can never rotate good backups out.
    @discardableResult func backupNow(reason: BackupReason) -> URL? {
        let ephemeral = exporter.isEphemeralStore
        if ephemeral && (reason == .scheduled || reason == .onQuit) {
            Log.backup.info("Skipping \(reason.rawValue, privacy: .public) backup: store is in memory only")
            return nil
        }
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }

        do {
            let data = try exporter.jsonData(includeAttachments: settings.backupIncludesAttachments)
            let url = uniqueURL(for: reason, date: .now)
            try data.write(to: url, options: .atomic)
            isDirty = false
            lastError = nil
            if !ephemeral { prune() }
            refreshList()
            Log.backup.info("Backup written: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
            Log.backup.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func refreshList() {
        let directory = backupsDirectory
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let files: [BackupFile] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.filePrefix), url.pathExtension.lowercased() == "json" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let parsed = Self.parse(filename: name)
            let date = parsed.date ?? values?.contentModificationDate ?? .distantPast
            return BackupFile(url: url, date: date, sizeBytes: Int64(values?.fileSize ?? 0), reason: parsed.reason)
        }
        backups = files.sorted { $0.date > $1.date }
        lastBackupDate = backups.first?.date
    }

    /// Makes a .beforeRestore backup first, then exporter.importArchive(from:mode:).
    func restore(from backup: BackupFile, mode: ImportMode) throws -> ImportSummary {
        if mode == .replace && exporter.hasActiveSession() {
            throw DataTransferError.sessionActive
        }
        // Validate the file before touching anything.
        let archive = try exporter.decodeArchive(from: backup.url)
        guard backupNow(reason: .beforeRestore) != nil else {
            throw DataTransferError.writeFailed("Couldn't create a safety backup before restoring. "
                                                + (lastError ?? ""))
        }
        let summary = try exporter.importArchive(archive, mode: mode)
        refreshList()
        return summary
    }

    /// NSWorkspace.shared.activateFileViewerSelecting
    func revealInFinder() {
        let target = backups.first?.url ?? backupsDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func delete(_ backup: BackupFile) {
        do {
            try FileManager.default.removeItem(at: backup.url)
        } catch {
            lastError = "Couldn't delete backup: \(error.localizedDescription)"
            Log.backup.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshList()
    }

    // MARK: - Private

    private func observeInterval() {
        let interval = withObservationTracking {
            settings.backupInterval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeInterval() }
        }
        reschedule(interval)
    }

    private func reschedule(_ interval: BackupInterval) {
        timer?.invalidate()
        timer = nil
        guard let seconds = interval.seconds else { return }
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.timerFired() }
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        guard isDirty else { return }
        backupNow(reason: .scheduled)
    }

    private func prune() {
        refreshList()
        let keep = settings.backupRetentionCount
        guard backups.count > keep else { return }
        for file in backups.dropFirst(keep) {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                Log.backup.error("Prune failed for \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func uniqueURL(for reason: BackupReason, date: Date) -> URL {
        let stamp = Self.makeFormatter().string(from: date)
        let base = "\(Self.filePrefix)\(stamp)-\(reason.rawValue)"
        var url = backupsDirectory.appending(path: base + ".json", directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = backupsDirectory.appending(path: "\(base)-\(counter).json", directoryHint: .notDirectory)
            counter += 1
        }
        return url
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// "Worklog-Backup-2026-10-07T14-03-22-scheduled(-2).json" → (date, "scheduled")
    private static func parse(filename: String) -> (date: Date?, reason: String) {
        var stem = filename
        if stem.hasPrefix(filePrefix) { stem.removeFirst(filePrefix.count) }
        if stem.lowercased().hasSuffix(".json") { stem.removeLast(5) }
        let stampLength = 19 // yyyy-MM-ddTHH-mm-ss
        guard stem.count >= stampLength else { return (nil, "unknown") }
        let stamp = String(stem.prefix(stampLength))
        var rest = String(stem.dropFirst(stampLength))
        if rest.hasPrefix("-") { rest.removeFirst() }
        let reason = rest.split(separator: "-").first.map(String.init) ?? "unknown"
        return (makeFormatter().date(from: stamp), reason.isEmpty ? "unknown" : reason)
    }
}
