import CloudKit
import CoreData
import Foundation
import Observation

/// Observes CloudKit sync for the SwiftData store: iCloud account status (`CKContainer.accountStatus()`, refreshed on
/// `.CKAccountChanged`) and the mirroring events SwiftData's underlying `NSPersistentCloudKitContainer` posts
/// (`eventChangedNotification`). Purely informational — it never changes the store.
///
/// When created with `enabled: false` (local-only or in-memory store) it stays idle and never touches CloudKit
/// (creating a `CKContainer` the build isn't entitled to would crash).
@MainActor @Observable
final class SyncMonitor {
    enum AccountStatus { case unknown, available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine }

    private(set) var accountStatus: AccountStatus = .unknown
    /// A setup/import/export event is in flight.
    private(set) var isSyncing = false
    private(set) var lastImport: Date? = nil
    private(set) var lastExport: Date? = nil
    /// The last failed event's error, user-presentable; cleared by the next successful import/export.
    private(set) var lastErrorDescription: String? = nil
    /// True after the first successful import of this launch (used to defer seeding on a new Mac).
    private(set) var hasCompletedFirstImport = false

    /// Latest of `lastImport` / `lastExport`.
    var lastSyncDate: Date? {
        switch (lastImport, lastExport) {
        case let (i?, e?): max(i, e)
        case let (i?, nil): i
        case let (nil, e?): e
        case (nil, nil): nil
        }
    }

    let isEnabled: Bool
    let containerIdentifier: String

    /// Called on `.CKAccountChanged` (before the status refresh). AppServices pins the newest backup with sessions
    /// there, because CloudKit may empty the local store after a sign-out or account switch (M4).
    @ObservationIgnored var onAccountChanged: (() -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var isStarted = false

    init(enabled: Bool, containerIdentifier: String) {
        self.isEnabled = enabled
        self.containerIdentifier = containerIdentifier
    }

    /// Starts observing (idempotent). Does nothing when not enabled.
    func start() {
        guard isEnabled, !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let event = notification.userInfo?[key] as? NSPersistentCloudKitContainer.Event else { return }
            let snapshot = EventSnapshot(event)
            MainActor.assumeIsolated { () -> Void in self?.handle(snapshot) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                Log.sync.info("iCloud account changed")
                self?.onAccountChanged?()
                self?.refreshAccountStatus()
            }
        })
        refreshAccountStatus()
        Log.sync.info("Sync monitor started")
    }

    func refreshAccountStatus() {
        guard isEnabled else { return }
        let container = CKContainer(identifier: containerIdentifier)
        Task { @MainActor [weak self] in
            let status: AccountStatus
            do {
                status = SyncMonitor.map(try await container.accountStatus())
            } catch {
                Log.sync.error("Account status failed: \(error.localizedDescription, privacy: .public)")
                status = .couldNotDetermine
            }
            self?.accountStatus = status
        }
    }

    // MARK: - Private

    /// Value copy of the parts of an event we use (the event object itself isn't Sendable).
    private struct EventSnapshot {
        enum Kind { case setup, `import`, export, other }
        let identifier: UUID
        let kind: Kind
        let endDate: Date?
        let succeeded: Bool
        let errorDescription: String?

        init(_ event: NSPersistentCloudKitContainer.Event) {
            identifier = event.identifier
            switch event.type {
            case .setup: kind = .setup
            case .import: kind = .import
            case .export: kind = .export
            @unknown default: kind = .other
            }
            endDate = event.endDate
            succeeded = event.succeeded
            errorDescription = event.error.map(SyncMonitor.describe)
        }
    }

    private func handle(_ event: EventSnapshot) {
        guard let endDate = event.endDate else {
            inFlight.insert(event.identifier)
            if !isSyncing { isSyncing = true }
            return
        }
        inFlight.remove(event.identifier)
        if event.succeeded {
            switch event.kind {
            case .import:
                lastImport = endDate
                if !hasCompletedFirstImport { hasCompletedFirstImport = true }
                lastErrorDescription = nil
            case .export:
                lastExport = endDate
                lastErrorDescription = nil
            case .setup, .other:
                break
            }
        } else {
            let text = event.errorDescription ?? "iCloud sync failed."
            lastErrorDescription = text
            Log.sync.error("Sync event failed: \(text, privacy: .public)")
        }
        let syncing = !inFlight.isEmpty
        if isSyncing != syncing { isSyncing = syncing }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .quotaExceeded:
                return "Your iCloud storage is full."
            case .notAuthenticated:
                return "Sign in to iCloud in System Settings to sync."
            case .networkUnavailable, .networkFailure:
                return "iCloud can\u{2019}t be reached; syncing resumes when you\u{2019}re online."
            case .accountTemporarilyUnavailable:
                return "Your iCloud account is temporarily unavailable."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud is busy; Worklog will retry shortly."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func map(_ status: CKAccountStatus) -> AccountStatus {
        switch status {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .couldNotDetermine
        @unknown default: .couldNotDetermine
        }
    }
}
