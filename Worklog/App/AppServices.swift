import Foundation
import SwiftData
import SwiftUI

/// The app's service graph. One shared instance backs every scene, the menu bar extra and the overlay.
@MainActor
final class AppServices {
    /// The real app. Under XCTest the shared instance is in-memory so tests never touch the user's store.
    static let shared = AppServices(inMemory: AppServices.isRunningUnitTests)
    static let preview = AppServices(inMemory: true)   // populated by PreviewData

    let settings: AppSettings
    let persistence: PersistenceController
    let sync: SyncMonitor
    let themeManager: ThemeManager
    let auth: AuthService
    let router: WindowRouter
    let engine: SessionEngine
    let exporter: ExportService
    let backups: BackupService
    let overlay: OverlayPanelController
    var container: ModelContainer { persistence.container }

    /// Order: settings → persistence(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory:) → sync → themeManager →
    /// auth → router → engine(context: mainContext) → exporter → backups → overlay(settings:); then data setup:
    /// - previews/tests (`inMemory`): PreviewData.populate;
    /// - store failed to open (in-memory fallback): default labels so the session is usable; on quit, changed data is
    ///   written to Recovered/Unsaved-<stamp>.json;
    /// - normal: a pending recovery (pending-restore.json) is processed first (import the chosen backup — merge when
    ///   CloudKit is on, replace otherwise — and skip seeding), else SeedData.seedIfNeeded (deferred in CloudKit mode
    ///   until the first iCloud import, max 60 s, so a new Mac doesn't resurrect deleted defaults); deduplicate.
    /// Then engine.restoreActiveSession(); sync.start(); overlay.install(services: self).
    ///
    /// In-memory instances (previews/tests) use a separate UserDefaults suite (emptied at creation) so they never read or change
    /// the user's preferences, and they don't install the overlay panel.
    init(inMemory: Bool = false) {
        let defaults: UserDefaults = inMemory ? Self.makeEphemeralDefaults() : .standard
        settings = AppSettings(defaults: defaults)
        persistence = PersistenceController(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory: inMemory)
        sync = SyncMonitor(enabled: !inMemory && persistence.isSyncingWithICloud,
                           containerIdentifier: persistence.cloudKitContainerIdentifier)
        themeManager = ThemeManager(defaults: defaults)
        auth = AuthService()
        router = WindowRouter()
        engine = SessionEngine(context: persistence.mainContext, settings: settings)
        exporter = ExportService(container: persistence.container)
        backups = BackupService(exporter: exporter, settings: settings)
        overlay = OverlayPanelController(settings: settings)
        backups.writesUnsavedSnapshotOnQuit = !inMemory && persistence.isRecoveryMode

        let context = persistence.mainContext
        if inMemory {
            PreviewData.populate(context)
        } else if persistence.isRecoveryMode {
            // The store couldn't be opened; give this (unsaved) session the default labels regardless of the seed flag.
            SeedData.insertDefaults(into: context)
            do {
                try context.save()
            } catch {
                Log.persistence.error("Seeding the in-memory store failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            let restoredBackup = processPendingRestore()
            if !restoredBackup {
                seedDefaults(in: context)
            }
            SeedData.deduplicate(in: context)
        }
        engine.restoreActiveSession()
        if !inMemory {
            sync.start()
            overlay.install(services: self)
        }
    }

    /// True when hosted by XCTest.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Private

    private static func makeEphemeralDefaults() -> UserDefaults {
        let suiteName = "\(AppConstants.bundleID).ephemeral"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return .standard }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Handles `pending-restore.json` written by the Recover… flow. Returns true when a backup was imported (then the
    /// defaults must not be seeded on top of it). The marker is removed on success, or when the backup can't be read
    /// at all (retrying would fail forever); other failures keep it so the next launch retries.
    private func processPendingRestore() -> Bool {
        guard let marker = PersistenceController.pendingRecovery() else {
            if FileManager.default.fileExists(atPath: AppConstants.pendingRestoreURL.path(percentEncoded: false)) {
                Log.persistence.error("Unreadable recovery marker removed")
                PersistenceController.clearPendingRecovery()
            }
            return false
        }
        let recoveredHint = "The damaged data was moved to the Recovered folder (Settings ▸ Data)."
        guard let path = marker.backupPath else {
            PersistenceController.clearPendingRecovery()
            // The fresh store has no labels: allow seeding again (deferred until the first iCloud import when syncing,
            // and skipped if labels arrive from iCloud).
            UserDefaults.standard.set(false, forKey: SeedData.didSeedDefaultsKey)
            persistence.launchNotice = persistence.isSyncingWithICloud
                ? "Worklog started with a fresh data store and is downloading your data from iCloud. \(recoveredHint)"
                : "Worklog started with a fresh, empty data store. \(recoveredHint)"
            Log.persistence.info("Recovery: started with a fresh store")
            return false
        }
        let url = URL(filePath: path)
        let mode: ImportMode = persistence.isSyncingWithICloud ? .merge : .replace
        do {
            let summary = try exporter.importArchive(from: url, mode: mode)
            PersistenceController.clearPendingRecovery()
            persistence.launchNotice = "Restored from the backup “\(url.lastPathComponent)”. \(summary.description) \(recoveredHint)"
            Log.persistence.info("Recovery: restored backup \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            let unreadable: Bool
            switch error {
            case DataTransferError.decodingFailed, DataTransferError.unsupportedVersion: unreadable = true
            default: unreadable = false
            }
            if unreadable { PersistenceController.clearPendingRecovery() }
            persistence.launchNotice = "The backup “\(url.lastPathComponent)” couldn't be restored: \(error.localizedDescription) "
                + (unreadable ? "Choose another backup in Settings ▸ Data." : "Worklog will try again at the next launch.")
            Log.persistence.error("Recovery restore failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Seeds the default labels/tags. With CloudKit on and nothing seeded yet (a new Mac, or a fresh store) it waits for
    /// the first iCloud import (max 60 s) so labels deleted on another Mac aren't recreated; `seedIfNeeded` then only
    /// seeds when there are still no labels.
    private func seedDefaults(in context: ModelContext) {
        let alreadySeeded = UserDefaults.standard.bool(forKey: SeedData.didSeedDefaultsKey)
        guard persistence.isSyncingWithICloud, !alreadySeeded else {
            SeedData.seedIfNeeded(in: context)
            return
        }
        let sync = sync
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(60)
            while !sync.hasCompletedFirstImport && Date.now < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            SeedData.seedIfNeeded(in: context)
            SeedData.deduplicate(in: context)
        }
    }
}

extension View {
    /// Injects every service + modelContainer + theme. Apply to EVERY scene root and to the overlay hosting view.
    @MainActor
    func withAppServices(_ services: AppServices) -> some View {
        self.environment(services.settings)
            .environment(services.persistence)
            .environment(services.sync)
            .environment(services.themeManager)
            .environment(services.auth)
            .environment(services.router)
            .environment(services.engine)
            .environment(services.exporter)
            .environment(services.backups)
            .environment(services.overlay)
            .modelContainer(services.container)
            .worklogThemed(services.themeManager)
    }
}
