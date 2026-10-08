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
    /// - normal: a pending recovery (pending-restore.json, also written by "Move to iCloud <env>") is processed first,
    ///   before anything is seeded or created: the chosen backup is imported — Replace into an empty store, else Merge
    ///   after a safety backup — and seeding is skipped. The marker is removed before the attempt (one attempt only;
    ///   a failure leaves a notice and the backup in the list). Otherwise SeedData.seedIfNeeded (deferred in CloudKit
    ///   mode until the first iCloud import, max 60 s, so a new Mac doesn't resurrect deleted defaults).
    /// Every branch then runs SeedData.ensureProfiles (default profile + repair of unassigned sessions — local-only
    /// stores; with CloudKit `SeedData.isSessionProfileRepairDisplayOnly` makes it display-only; *provisional* when
    /// CloudKit is on and the first import hasn't completed) and deduplicate.
    /// Then profiles.reload(); router.profiles = profiles; router.auth = auth; engine.restoreActiveSession(); profiles.startObserving();
    /// the provisional-profile follow-up (see `resolveProvisionalProfile`); sync.start(); overlay.install(services: self).
    ///
    /// In-memory instances (previews/tests) use a separate UserDefaults suite (emptied at creation) so they never read or change
    /// the user's preferences, and they don't install the overlay panel.
    init(inMemory: Bool = false) {
        let defaults: UserDefaults = inMemory ? Self.makeEphemeralDefaults() : .standard
        settings = AppSettings(defaults: defaults)
        shortcuts = ShortcutStore(defaults: defaults)
        persistence = PersistenceController(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory: inMemory,
                                            defaults: defaults)
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
        exporter.localDeviceID = engine.deviceID
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
        router.auth = auth
        engine.restoreActiveSession()
        profiles.startObserving()
        if !inMemory {
            resolveProvisionalProfile(in: context)
            sync.onAccountChanged = { [weak self] in self?.handleICloudAccountChange() }
            sync.start()
            overlay.install(services: self)
            scheduleShrinkageCheckAfterFirstImport()
        }
    }

    // MARK: - Data shrinkage (M4)

    /// UserDefaults (`settings.defaults`): file name of the backup pinned at the last iCloud account change, when, and
    /// the "<file>#<count>" a shrink notice was last shown for.
    static let accountChangeBackupKey = "backup.accountChangeBackup"
    static let accountChangeDateKey = "backup.accountChangeDate"
    static let shrinkNoticeShownKey = "backup.shrinkNoticeShown"

    /// CloudKit can empty the local store after an iCloud sign-out or account switch: pin the newest backup with
    /// sessions and remember it, so `checkDataShrinkage()` can compare against it.
    func handleICloudAccountChange() {
        guard let pinned = backups.pinNewestBackupWithSessions() else { return }
        settings.defaults.set(pinned.url.lastPathComponent, forKey: Self.accountChangeBackupKey)
        settings.defaults.set(Date.now, forKey: Self.accountChangeDateKey)
    }

    /// At launch (after the first iCloud import) and on activation: when the store has under half the sessions of
    /// the backup pinned at the last account change (kept for 7 days), say so once per count, pointing at the
    /// pinned backup. Never changes data.
    func checkDataShrinkage() {
        guard !persistence.isInMemory else { return }
        if persistence.isSyncingWithICloud && !sync.hasCompletedFirstImport { return }
        let defaults = settings.defaults
        guard let name = defaults.string(forKey: Self.accountChangeBackupKey) else { return }
        let changedAt = defaults.object(forKey: Self.accountChangeDateKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(changedAt) < 7 * 86_400 else {
            defaults.removeObject(forKey: Self.accountChangeBackupKey)
            defaults.removeObject(forKey: Self.accountChangeDateKey)
            return
        }
        backups.refreshList()
        guard let backup = backups.backups.first(where: { $0.url.lastPathComponent == name }),
              let previous = backup.sessionCount else { return }
        let current = exporter.sessionCount()
        guard BackupService.shouldPinPrevious(previousCount: previous, newCount: current) else { return }
        let shownFor = "\(name)#\(current)"
        guard defaults.string(forKey: Self.shrinkNoticeShownKey) != shownFor else { return }
        defaults.set(shownFor, forKey: Self.shrinkNoticeShownKey)
        Log.backup.warning("Data shrank from \(previous) to \(current) sessions after an iCloud account change")
        persistence.launchNotice = "Your data shrank from \(previous) to \(current) sessions after an iCloud account "
            + "change. A pinned backup from \(backup.date.shortDateTime) is in Settings \u{25B8} Data."
        persistence.launchNoticeOffersRestore = true
    }

    /// With CloudKit the store is only comparable once the first import of this launch finished (max 10 min).
    private func scheduleShrinkageCheckAfterFirstImport() {
        guard persistence.isSyncingWithICloud else {
            checkDataShrinkage()
            return
        }
        let sync = sync
        Task { @MainActor [weak self] in
            let deadline = Date.now.addingTimeInterval(600)
            while !sync.hasCompletedFirstImport && Date.now < deadline {
                try? await Task.sleep(for: .seconds(5))
            }
            self?.checkDataShrinkage()
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

    /// Handles `pending-restore.json` written by the Recover… flow or "Move to iCloud <env>". Returns true when a
    /// backup was imported (then the defaults must not be seeded on top of it).
    ///
    /// M6: the marker is removed BEFORE the attempt, so a failing or crashing restore can't repeat at every launch
    /// (the notice says so and the backup stays in the list). Replace only into an empty store (nothing is deleted,
    /// and labels/profiles that CloudKit already brought are never wiped); otherwise Merge, after a safety backup.
    private func processPendingRestore() -> Bool {
        let move = persistence.environmentMove
        guard let marker = PersistenceController.pendingRecovery() else {
            if FileManager.default.fileExists(atPath: AppConstants.pendingRestoreURL.path(percentEncoded: false)) {
                Log.persistence.error("Unreadable recovery marker removed")
                PersistenceController.clearPendingRecovery()
            }
            if let move {
                persistence.launchNotice = "Moved to iCloud \(move.to.rawValue), but no backup was found to "
                    + "restore. Your previous data is in the Recovered folder."
            }
            return false
        }
        PersistenceController.clearPendingRecovery()
        guard let path = marker.backupPath else {
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
        do {
            let archive = try exporter.decodeArchive(from: url)
            let mode = Self.pendingRestoreMode(storeIsEmpty: exporter.isStoreEmpty())
            let summary = try backups.importArchive(archive, mode: mode)
            Log.persistence.info("Recovery: restored backup \(url.lastPathComponent, privacy: .public) (\(mode == .replace ? "replace" : "merge", privacy: .public))")
            if let move {
                let restored = exporter.sessionCount()
                let lead = persistence.isSyncingWithICloud
                    ? "Moved to iCloud \(move.to.rawValue)"
                    : "Restored on this Mac; iCloud \(move.to.rawValue) isn\u{2019}t available yet"
                let expected = archive.sessions.count
                let count = restored >= expected ? "\(expected)" : "\(restored) of \(expected)"
                var text = "\(lead): \(count) \(expected == 1 ? "session" : "sessions") restored."
                if restored < expected {
                    text += " Some are missing; the backup is pinned in Settings \u{25B8} Data."
                }
                text += " Your previous copy is in the Recovered folder."
                persistence.launchNotice = text
            } else {
                persistence.launchNotice = "Restored \u{201C}\(url.lastPathComponent)\u{201D}. \(summary.description)"
            }
            return true
        } catch {
            Log.persistence.error("Recovery restore failed: \(error.localizedDescription, privacy: .public)")
            var reason = error.localizedDescription
            if !reason.hasSuffix(".") { reason += "." }
            let failure = "\u{201C}\(url.lastPathComponent)\u{201D} couldn\u{2019}t be restored: \(reason) "
                + "Restore it from Settings \u{25B8} Data."
            persistence.launchNotice = move.map { "Moved to iCloud \($0.to.rawValue), but " + failure } ?? failure
            persistence.launchNoticeOffersRestore = true
            return false
        }
    }

    /// M6 (pure): a pending restore replaces only an empty store (nothing is deleted); otherwise it merges.
    nonisolated static func pendingRestoreMode(storeIsEmpty: Bool) -> ImportMode {
        storeIsEmpty ? .replace : .merge
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
