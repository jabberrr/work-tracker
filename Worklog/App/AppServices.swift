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
    /// Customizable keyboard shortcuts (same UserDefaults as `settings`).
    let shortcuts: ShortcutStore
    let persistence: PersistenceController
    let sync: SyncMonitor
    let themeManager: ThemeManager
    let auth: AuthService
    let router: WindowRouter
    /// The current profile and the profile lists (ARCHITECTURE §12).
    let profiles: ProfileStore
    let engine: SessionEngine
    let exporter: ExportService
    let backups: BackupService
    let overlay: OverlayPanelController
    var container: ModelContainer { persistence.container }

    /// Order: settings → shortcuts(defaults:) → persistence(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory:) → sync → themeManager →
    /// auth → router → profiles(context:settings:) → engine(context:settings:profiles:) → exporter → backups →
    /// overlay(settings:); then data setup:
    /// - previews/tests (`inMemory`): PreviewData.populate;
    /// - store failed to open (in-memory fallback): default labels so the session is usable; on quit, changed data is
    ///   written to Recovered/Unsaved-<stamp>.json;
    /// - normal: a pending recovery (pending-restore.json) is processed first (import the chosen backup — merge when
    ///   CloudKit is on, replace otherwise — and skip seeding), else SeedData.seedIfNeeded (deferred in CloudKit mode
    ///   until the first iCloud import, max 60 s, so a new Mac doesn't resurrect deleted defaults).
    /// Every branch then runs SeedData.ensureProfiles (default profile + repair of unassigned sessions — local-only
    /// stores; with CloudKit `SeedData.isSessionProfileRepairDisplayOnly` makes it display-only; *provisional* when
    /// CloudKit is on and the first import hasn't completed) and deduplicate.
    /// Then profiles.reload(); router.profiles = profiles; engine.restoreActiveSession(); profiles.startObserving();
    /// the provisional-profile follow-up (see `resolveProvisionalProfile`); sync.start(); overlay.install(services: self).
    ///
    /// In-memory instances (previews/tests) use a separate UserDefaults suite (emptied at creation) so they never read or change
    /// the user's preferences, and they don't install the overlay panel.
    init(inMemory: Bool = false) {
        let defaults: UserDefaults = inMemory ? Self.makeEphemeralDefaults() : .standard
        settings = AppSettings(defaults: defaults)
        shortcuts = ShortcutStore(defaults: defaults)
        persistence = PersistenceController(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory: inMemory)
        // CloudKit: unassigned sessions are shown in their effective profile and only written on a user edit.
        SeedData.isSessionProfileRepairDisplayOnly = persistence.isSyncingWithICloud
        sync = SyncMonitor(enabled: !inMemory && persistence.isSyncingWithICloud,
                           containerIdentifier: persistence.cloudKitContainerIdentifier)
        themeManager = ThemeManager(defaults: defaults)
        auth = AuthService()
        router = WindowRouter()
        profiles = ProfileStore(context: persistence.mainContext, settings: settings)
        engine = SessionEngine(context: persistence.mainContext, settings: settings, profiles: profiles)
        exporter = ExportService(container: persistence.container)
        backups = BackupService(exporter: exporter, settings: settings)
        overlay = OverlayPanelController(settings: settings)
        backups.writesUnsavedSnapshotOnQuit = !inMemory && persistence.isRecoveryMode

        let context = persistence.mainContext
        if inMemory {
            PreviewData.populate(context)
            SeedData.ensureProfiles(in: context, settings: settings)
        } else if persistence.isRecoveryMode {
            // The store couldn't be opened; give this (unsaved) session the default labels regardless of the seed flag.
            SeedData.insertDefaults(into: context)
            do {
                try context.save()
            } catch {
                Log.persistence.error("Seeding the in-memory store failed: \(error.localizedDescription, privacy: .public)")
            }
            SeedData.ensureProfiles(in: context, settings: settings)
        } else {
            let restoredBackup = processPendingRestore()
            if !restoredBackup {
                seedDefaults(in: context)
            }
            // Only marks the profile provisional when ensureProfiles has to create it (no profile existed).
            let provisional = persistence.isSyncingWithICloud && !sync.hasCompletedFirstImport
            SeedData.ensureProfiles(in: context, settings: settings, provisional: provisional)
        }
        SeedData.deduplicate(in: context)
        profiles.reload()
        router.profiles = profiles
        engine.restoreActiveSession()
        profiles.startObserving()
        if !inMemory {
            resolveProvisionalProfile(in: context)
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
        guard let path = marker.backupPath else {
            PersistenceController.clearPendingRecovery()
            // The fresh store has no labels: allow seeding again (deferred until the first iCloud import when syncing,
            // and skipped if labels arrive from iCloud).
            UserDefaults.standard.set(false, forKey: SeedData.didSeedDefaultsKey)
            persistence.launchNotice = persistence.isSyncingWithICloud
                ? "Started fresh; downloading your data from iCloud."
                : "Started with an empty data store."
            Log.persistence.info("Recovery: started with a fresh store")
            return false
        }
        let url = URL(filePath: path)
        let mode: ImportMode = persistence.isSyncingWithICloud ? .merge : .replace
        do {
            let summary = try exporter.importArchive(from: url, mode: mode)
            PersistenceController.clearPendingRecovery()
            persistence.launchNotice = "Restored “\(url.lastPathComponent)”. \(summary.description)"
            Log.persistence.info("Recovery: restored backup \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            let unreadable: Bool
            switch error {
            case DataTransferError.decodingFailed, DataTransferError.unsupportedVersion: unreadable = true
            default: unreadable = false
            }
            if unreadable { PersistenceController.clearPendingRecovery() }
            persistence.launchNotice = unreadable
                ? "Couldn\u{2019}t restore “\(url.lastPathComponent)”. Choose another backup."
                : "Couldn\u{2019}t restore “\(url.lastPathComponent)”. Retrying at next launch."
            Log.persistence.error("Recovery restore failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A default profile created before the first iCloud import (now or at an earlier launch) is *provisional*: once the
    /// import finished, deduplicate merges it into a synced "Work" profile, and `discardProvisionalDefaultProfile`
    /// removes it when it is still empty and another profile exists (the user deleted "Work" on another Mac).
    /// Nothing is forced when the import doesn't finish: after 10 minutes the wait just stops and the key stays for the
    /// next launch. (Unassigned sessions are never repaired in the background in CloudKit mode, so none lands in the
    /// provisional profile while waiting.)
    private func resolveProvisionalProfile(in context: ModelContext) {
        let defaults = settings.defaults
        guard persistence.isSyncingWithICloud,
              defaults.string(forKey: SeedData.provisionalDefaultProfileKey) != nil else { return }
        let sync = sync
        let profiles = profiles
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(600)
            while !sync.hasCompletedFirstImport && Date.now < deadline {
                try? await Task.sleep(for: .seconds(2))
            }
            guard sync.hasCompletedFirstImport else {
                Log.persistence.info("First iCloud import not finished; the provisional profile is checked next launch")
                return
            }
            SeedData.deduplicate(in: context)
            SeedData.discardProvisionalDefaultProfile(in: context, defaults: defaults)
            profiles.reload()
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
        let profiles = profiles
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(60)
            while !sync.hasCompletedFirstImport && Date.now < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            SeedData.seedIfNeeded(in: context)
            SeedData.deduplicate(in: context)
            profiles.reload()
        }
    }
}

extension View {
    /// Injects every service (ProfileStore included) + modelContainer + theme. Apply to EVERY scene root and to the
    /// overlay hosting view. Sheets and popovers inherit the environment of the view that presents them.
    @MainActor
    func withAppServices(_ services: AppServices) -> some View {
        self.environment(services.settings)
            .environment(services.shortcuts)
            .environment(services.persistence)
            .environment(services.sync)
            .environment(services.themeManager)
            .environment(services.auth)
            .environment(services.router)
            .environment(services.profiles)
            .environment(services.engine)
            .environment(services.exporter)
            .environment(services.backups)
            .environment(services.overlay)
            .modelContainer(services.container)
            .worklogThemed(services.themeManager)
    }
}
