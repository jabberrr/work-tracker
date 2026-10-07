import AppKit
import CoreData
import Foundation
import Observation
import SwiftData

enum BackupReason: String { case scheduled, onQuit, manual, beforeRestore }

struct BackupFile: Identifiable, Hashable {
    let url: URL; let date: Date; let sizeBytes: Int64; let reason: String
    /// Sessions in the backup (from the file name, "-n42"); nil for older backups.
    var sessionCount: Int? = nil
    /// Pinned backups ("-pinned" in the file name) are never pruned automatically.
    var isPinned: Bool = false
    var id: URL { url }
    /// Scheduled and on-quit backups rotate; manual and before-restore backups are kept longer.
    var isAutomatic: Bool { reason == BackupReason.scheduled.rawValue || reason == BackupReason.onQuit.rawValue }
}

/// One image file to store in `Backups/Attachments/`.
struct BackupImagePayload: Sendable {
    let fileName: String
    let data: Data
}

/// Rolling local JSON snapshots in Application Support/Worklog/Backups, plus restore.
///
/// - File names use UTC: "Worklog-Backup-2026-10-07T14-03-22Z-scheduled-n42.json" (older local-time names still parse).
/// - Images are stored once in `Backups/Attachments/<id>.<ext>`; the JSON references them (`attachmentStore`) instead
///   of embedding base64. Unreferenced image files are garbage-collected after pruning. Older backups with embedded
///   images restore as before. User-facing "Export JSON with images" still embeds them.
/// - Retention: automatic backups keep the newest `backupRetentionCount`, plus the newest per day for 14 days and per
///   week for 8 weeks; manual and before-restore backups keep the newest 20; pinned backups and the newest backup that
///   contains sessions are never pruned; the backup being restored is never pruned.
/// - Shrinkage guard: when a new backup has under half the sessions of the previous one (which had > 10), or none
///   while the previous had some, the previous backup is pinned. Automatic backups of an empty store are skipped when
///   the previous backup had sessions.
@MainActor @Observable
final class BackupService {
    private(set) var lastBackupDate: Date? = nil
    private(set) var backups: [BackupFile] = []      // newest first
    private(set) var isWorking = false
    var lastError: String? = nil
    var backupsDirectory: URL { AppConstants.backupsURL }

    /// Set by AppServices when the store failed to open (in-memory fallback): on quit, changed data is written to
    /// `Recovered/Unsaved-<stamp>.json` (never pruned) instead of being lost.
    @ObservationIgnored var writesUnsavedSnapshotOnQuit = false

    nonisolated static let filePrefix = "Worklog-Backup-"
    nonisolated static let pinnedToken = "pinned"
    nonisolated static let manualKeepCount = 20
    nonisolated static let dailyKeepDays = 14
    nonisolated static let weeklyKeepWeeks = 8
    private nonisolated static let dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    /// Image files younger than this are never garbage-collected (a backup referencing them may be in flight).
    private nonisolated static let imageGCGrace: TimeInterval = 3600

    private let exporter: ExportService
    private let settings: AppSettings
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isDirty = true
    @ObservationIgnored private var isScheduling = false

    init(exporter: ExportService, settings: AppSettings) {
        self.exporter = exporter
        self.settings = settings
        refreshList()
        // Dirty at launch only when there is no recent backup (data may also have changed via iCloud meanwhile).
        isDirty = lastBackupDate.map { Date.now.timeIntervalSince($0) > 24 * 3600 } ?? true
    }

    /// Observes ModelContext.didSave and persistent-store remote changes (CloudKit imports) to mark dirty, and
    /// settings.backupInterval (withObservationTracking); schedules a repeating Timer; each fire: if dirty → backup.
    func startScheduling() {
        guard !isScheduling else { return }
        isScheduling = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.isDirty = true }
        })
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.isDirty = true }
        })
        if exporter.isEphemeralStore && writesUnsavedSnapshotOnQuit {
            isDirty = false     // only changes made in this session matter
        }
        observeInterval()
    }

    /// Synchronous: archive (images per settings, stored as separate files) → write
    /// "Worklog-Backup-<UTC stamp>Z-<reason>-n<sessions>.json" atomically → prune → refresh list.
    ///
    /// - Scheduled backups are skipped while the store is in memory only; on-quit ones too, except that in the
    ///   failed-store fallback (`writesUnsavedSnapshotOnQuit`) changed data goes to `Recovered/Unsaved-<stamp>.json`.
    /// - On-quit backups are skipped when nothing changed since the last backup.
    /// - Automatic backups are skipped when the store is empty but the previous backup had sessions.
    /// Returns nil when skipped or failed (`lastError` is set on failure).
    @discardableResult func backupNow(reason: BackupReason) -> URL? {
        performBackup(reason: reason, protecting: nil)
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
            return BackupFile(url: url, date: date, sizeBytes: Int64(values?.fileSize ?? 0), reason: parsed.reason,
                              sessionCount: parsed.sessionCount, isPinned: parsed.isPinned)
        }
        backups = files.sorted { $0.date > $1.date }
        lastBackupDate = backups.first?.date
    }

    /// Makes a .beforeRestore safety backup first (skipped while the store is in memory only — there is nothing on
    /// disk to protect), then imports. The backup being restored is never pruned by that safety backup.
    func restore(from backup: BackupFile, mode: ImportMode) throws -> ImportSummary {
        if mode == .replace && exporter.hasActiveSession() {
            throw DataTransferError.sessionActive
        }
        // Validate the file before touching anything.
        let archive = try exporter.decodeArchive(from: backup.url)
        try makeSafetyBackup(protecting: backup.url)
        let summary = try exporter.importArchive(archive, mode: mode)
        refreshList()
        return summary
    }

    /// Imports an already-decoded archive (e.g. a file the user picked) with the same safety backup as `restore`,
    /// for both merge and replace.
    func importArchive(_ archive: ExportArchive, mode: ImportMode) throws -> ImportSummary {
        if mode == .replace && exporter.hasActiveSession() {
            throw DataTransferError.sessionActive
        }
        try makeSafetyBackup(protecting: nil)
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

    /// Pins (never pruned) or unpins a backup by renaming it. Returns the new file, or nil on failure.
    @discardableResult func setPinned(_ pinned: Bool, for backup: BackupFile) -> BackupFile? {
        guard backup.isPinned != pinned else { return backup }
        do {
            let url = try Self.renamePinned(backup.url, pinned: pinned)
            refreshList()
            return backups.first { $0.url == url }
        } catch {
            lastError = "Couldn't change the backup: \(error.localizedDescription)"
            Log.backup.error("Pin change failed: \(error.localizedDescription, privacy: .public)")
            refreshList()
            return nil
        }
    }

    // MARK: - Backup pipeline

    /// Everything a backup writes; built on the main actor, written anywhere.
    struct Capture: Sendable {
        var archive: ExportArchive
        var images: [BackupImagePayload]
        var imageFolder: URL?
        var sessionCount: Int { archive.sessions.count }
    }

    private func makeSafetyBackup(protecting: URL?) throws {
        guard !exporter.isEphemeralStore else { return }
        guard performBackup(reason: .beforeRestore, protecting: protecting) != nil else {
            throw DataTransferError.writeFailed("Couldn't create a safety backup first. " + (lastError ?? ""))
        }
    }

    private func performBackup(reason: BackupReason, protecting: URL?) -> URL? {
        let ephemeral = exporter.isEphemeralStore
        if ephemeral && (reason == .scheduled || reason == .onQuit) {
            if reason == .onQuit && writesUnsavedSnapshotOnQuit && isDirty {
                return writeUnsavedSnapshot()
            }
            Log.backup.info("Skipping \(reason.rawValue, privacy: .public) backup: store is in memory only")
            return nil
        }
        // A scheduled write still in flight would be killed at quit (atomic, so it leaves no file): back up again.
        if reason == .onQuit && !isDirty && !isWorking {
            Log.backup.info("Skipping on-quit backup: nothing changed")
            return nil
        }
        let previous = backups.first
        let previousCount = previous.flatMap(Self.knownSessionCount)
        if reason == .scheduled || reason == .onQuit, exporter.sessionCount() == 0, (previousCount ?? 0) > 0 {
            Log.backup.warning("Skipping \(reason.rawValue, privacy: .public) backup: store is empty but the last backup has sessions")
            return nil
        }

        do {
            let capture = try makeCapture()
            let url = uniqueURL(for: reason, date: .now, sessionCount: capture.sessionCount)
            try Self.write(capture, to: url)
            isDirty = false
            lastError = nil
            finishBackup(newCount: capture.sessionCount, previous: previous, previousCount: previousCount,
                         ephemeral: ephemeral, protecting: protecting)
            Log.backup.info("Backup written: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
            Log.backup.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Timer path: the archive is captured on the main actor, encoding and writing happen off the main actor.
    private func scheduledBackup() {
        guard isDirty, !isWorking else { return }
        guard !exporter.isEphemeralStore else { return }
        let previous = backups.first
        let previousCount = previous.flatMap(Self.knownSessionCount)
        if exporter.sessionCount() == 0, (previousCount ?? 0) > 0 {
            Log.backup.warning("Skipping scheduled backup: store is empty but the last backup has sessions")
            return
        }
        let capture: Capture
        do {
            capture = try makeCapture()
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
            Log.backup.error("Backup capture failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = uniqueURL(for: .scheduled, date: .now, sessionCount: capture.sessionCount)
        isWorking = true
        isDirty = false     // changes made while writing mark it dirty again
        Task { @MainActor [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result<Void, Error> { try BackupService.write(capture, to: url) }
            }.value
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success:
                self.lastError = nil
                self.finishBackup(newCount: capture.sessionCount, previous: previous, previousCount: previousCount,
                                  ephemeral: false, protecting: nil)
                Log.backup.info("Backup written: \(url.lastPathComponent, privacy: .public)")
            case .failure(let error):
                self.isDirty = true
                self.lastError = "Backup failed: \(error.localizedDescription)"
                Log.backup.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeCapture() throws -> Capture {
        var archive = try exporter.makeArchive(includeAttachments: false)
        guard settings.backupIncludesAttachments else {
            return Capture(archive: archive, images: [], imageFolder: nil)
        }
        let folder = backupsDirectory.appending(path: ExportArchive.backupAttachmentFolder, directoryHint: .isDirectory)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
        let images = try exporter.backupImagePayloads(skipping: existing)
        archive.includesAttachments = true
        archive.attachmentStore = ExportArchive.backupAttachmentFolder
        return Capture(archive: archive, images: images, imageFolder: folder)
    }

    /// Writes missing image files, then the JSON (compact, sorted keys) atomically.
    nonisolated static func write(_ capture: Capture, to url: URL) throws {
        let fileManager = FileManager.default
        if let folder = capture.imageFolder {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for image in capture.images {
                let destination = folder.appending(path: image.fileName, directoryHint: .notDirectory)
                guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
                try image.data.write(to: destination, options: .atomic)
            }
        }
        let data = try ExportArchive.makeEncoder(pretty: false).encode(capture.archive)
        try data.write(to: url, options: .atomic)
    }

    /// Shrinkage guard, prune, refresh, then image GC off the main actor.
    private func finishBackup(newCount: Int, previous: BackupFile?, previousCount: Int?, ephemeral: Bool, protecting: URL?) {
        if !ephemeral, let previous, let previousCount, !previous.isPinned,
           Self.shouldPinPrevious(previousCount: previousCount, newCount: newCount) {
            Log.backup.warning("Backup shrank from \(previousCount) to \(newCount) sessions; pinning \(previous.url.lastPathComponent, privacy: .public)")
            _ = try? Self.renamePinned(previous.url, pinned: true)
        }
        refreshList()
        guard !ephemeral else { return }
        prune(protecting: protecting)
        refreshList()
        let directory = backupsDirectory
        Task.detached(priority: .background) {
            BackupService.collectUnreferencedImages(in: directory)
        }
    }

    /// In-memory fallback: write the session's data (images embedded) to Recovered/Unsaved-<stamp>.json.
    private func writeUnsavedSnapshot() -> URL? {
        do {
            let data = try exporter.jsonData(includeAttachments: true)
            let folder = AppConstants.recoveredURL
            AppConstants.makeDirectory(folder)
            let url = folder.appending(path: "Unsaved-\(AppConstants.fileTimestamp()).json", directoryHint: .notDirectory)
            try data.write(to: url, options: .atomic)
            isDirty = false
            Log.backup.info("Wrote unsaved in-memory data to \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            Log.backup.error("Unsaved snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Scheduling

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
            MainActor.assumeIsolated { () -> Void in self?.scheduledBackup() }
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Retention

    private func prune(protecting: URL?) {
        let doomed = Self.filesToPrune(backups, keepAutomatic: settings.backupRetentionCount, now: .now,
                                       calendar: .current, protecting: protecting)
        for file in doomed {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                Log.backup.error("Prune failed for \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pure retention policy (unit-tested). Returns the files to delete.
    nonisolated static func filesToPrune(_ files: [BackupFile], keepAutomatic: Int, now: Date, calendar: Calendar,
                                         protecting: URL?) -> [BackupFile] {
        let sorted = files.sorted { $0.date > $1.date }
        var keep = Set<URL>()
        if let protecting { keep.insert(protecting) }
        for file in sorted where file.isPinned { keep.insert(file.url) }

        let manual = sorted.filter { !$0.isAutomatic }
        for file in manual.prefix(manualKeepCount) { keep.insert(file.url) }

        let automatic = sorted.filter(\.isAutomatic)
        for file in automatic.prefix(max(1, keepAutomatic)) { keep.insert(file.url) }

        let dayLimit = calendar.date(byAdding: .day, value: -dailyKeepDays, to: now) ?? now
        let weekLimit = calendar.date(byAdding: .weekOfYear, value: -weeklyKeepWeeks, to: now) ?? now
        var days = Set<Date>()
        var weeks = Set<Date>()
        for file in automatic {
            if file.date >= dayLimit, days.insert(calendar.startOfDay(for: file.date)).inserted {
                keep.insert(file.url)
            }
            if file.date >= weekLimit,
               let week = calendar.dateInterval(of: .weekOfYear, for: file.date)?.start,
               weeks.insert(week).inserted {
                keep.insert(file.url)
            }
        }

        // Never lose the newest backup that has data (unknown counts are treated as having data).
        if let newestWithData = sorted.first(where: { ($0.sessionCount ?? 1) > 0 }) {
            keep.insert(newestWithData.url)
        }
        return sorted.filter { !keep.contains($0.url) }
    }

    /// Pin the previous backup when the new one lost most of its sessions (or all of them).
    nonisolated static func shouldPinPrevious(previousCount: Int, newCount: Int) -> Bool {
        if previousCount > 0 && newCount == 0 { return true }
        return previousCount > 10 && newCount * 2 < previousCount
    }

    /// Deletes image files no backup references any more (older than the grace period). Gives up if any backup
    /// can't be read, so nothing referenced is ever removed.
    nonisolated static func collectUnreferencedImages(in directory: URL) {
        struct Probe: Decodable {
            struct Session: Decodable {
                struct Attachment: Decodable { let id: UUID; let uti: String }
                let attachments: [Attachment]
            }
            let sessions: [Session]
            let attachmentStore: String?
        }
        let fileManager = FileManager.default
        let folderName = ExportArchive.backupAttachmentFolder
        let folder = directory.appending(path: folderName, directoryHint: .isDirectory)
        guard let imageFiles = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                    options: [.skipsHiddenFiles]),
              !imageFiles.isEmpty else { return }
        let backupFiles = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension.lowercased() == "json" }
        var referenced = Set<String>()
        let decoder = JSONDecoder()
        for file in backupFiles {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let probe = try? decoder.decode(Probe.self, from: data) else {
                Log.backup.error("Image cleanup skipped: \(file.lastPathComponent, privacy: .public) couldn't be read")
                return
            }
            guard probe.attachmentStore == folderName else { continue }
            for session in probe.sessions {
                for attachment in session.attachments {
                    referenced.insert(ExportArchive.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: false))
                    referenced.insert(ExportArchive.attachmentFileName(id: attachment.id, uti: attachment.uti, thumbnail: true))
                }
            }
        }
        let cutoff = Date.now.addingTimeInterval(-imageGCGrace)
        var removed = 0
        for file in imageFiles where !referenced.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            guard modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            Log.backup.info("Removed \(removed) unreferenced backup images")
        }
    }

    // MARK: - File names

    private func uniqueURL(for reason: BackupReason, date: Date, sessionCount: Int) -> URL {
        let stamp = Self.makeFormatter(utc: true).string(from: date)
        let base = "\(Self.filePrefix)\(stamp)Z-\(reason.rawValue)-n\(sessionCount)"
        var url = backupsDirectory.appending(path: base + ".json", directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = backupsDirectory.appending(path: "\(base)-\(counter).json", directoryHint: .notDirectory)
            counter += 1
        }
        return url
    }

    /// Session count from the file name, else (older backups < 20 MB) by reading the file.
    private nonisolated static func knownSessionCount(_ file: BackupFile) -> Int? {
        if let count = file.sessionCount { return count }
        guard file.sizeBytes < 20 * 1024 * 1024 else { return nil }
        struct Probe: Decodable {
            struct Session: Decodable { let id: UUID }
            let sessions: [Session]
        }
        guard let data = try? Data(contentsOf: file.url),
              let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return nil }
        return probe.sessions.count
    }

    /// Adds or removes the "-pinned" token before ".json".
    private nonisolated static func renamePinned(_ url: URL, pinned: Bool) throws -> URL {
        var stem = url.deletingPathExtension().lastPathComponent
        let suffix = "-\(pinnedToken)"
        if pinned {
            guard !stem.hasSuffix(suffix) else { return url }
            stem += suffix
        } else {
            guard stem.hasSuffix(suffix) else { return url }
            stem.removeLast(suffix.count)
        }
        let destination = url.deletingLastPathComponent().appending(path: stem + ".json", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private nonisolated static func makeFormatter(utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// "Worklog-Backup-2026-10-07T14-03-22Z-scheduled-n42(-2)(-pinned).json" → (UTC date, "scheduled", 42, pinned).
    /// Older names without "Z" were written in local time: "Worklog-Backup-2026-10-07T14-03-22-scheduled(-2).json".
    nonisolated static func parse(filename: String) -> (date: Date?, reason: String, sessionCount: Int?, isPinned: Bool) {
        var stem = filename
        if stem.hasPrefix(filePrefix) { stem.removeFirst(filePrefix.count) }
        if stem.lowercased().hasSuffix(".json") { stem.removeLast(5) }
        let stampLength = 19 // yyyy-MM-ddTHH-mm-ss
        guard stem.count >= stampLength else { return (nil, "unknown", nil, false) }
        let stamp = String(stem.prefix(stampLength))
        var rest = String(stem.dropFirst(stampLength))
        var isUTC = false
        if rest.hasPrefix("Z") {
            isUTC = true
            rest.removeFirst()
        }
        if rest.hasPrefix("-") { rest.removeFirst() }
        let tokens = rest.split(separator: "-").map(String.init)
        let reason = tokens.first ?? "unknown"
        let count = tokens.dropFirst()
            .first { $0.hasPrefix("n") && $0.count > 1 && Int($0.dropFirst()) != nil }
            .flatMap { Int($0.dropFirst()) }
        let pinned = tokens.dropFirst().contains(pinnedToken)
        return (makeFormatter(utc: isUTC).date(from: stamp), reason.isEmpty ? "unknown" : reason, count, pinned)
    }
}
