import AppKit
import CoreData
import Foundation
import Observation
import SwiftData

// System and store notifications. The sleep/wake handlers stay in SessionEngine.swift (they change
// `autoPauseReason` / `tick`).
extension SessionEngine {
    /// Installs NSWorkspace willSleep/didWake + NSApplication.didBecomeActive observers (called by AppServices /
    /// AppDelegate). Also observes `.worklogDataDidImport`, persistent-store remote changes (CloudKit imports) and
    /// `.worklogSaveFailed` (shown through `lastError`).
    func startObservingSystemEvents() {
        guard !isObservingSystemEvents else { return }
        isObservingSystemEvents = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleWillSleep() }
        })
        workspaceObserverTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleDidWake() }
        })

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.handleDidBecomeActive() }
        })
        observerTokens.append(center.addObserver(
            forName: .worklogDataDidImport, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.reconcile() }
        })
        observerTokens.append(center.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                self?.verifyTrackedSessions()
                self?.scheduleRemoteChangeReconcile()
            }
        })
        observerTokens.append(center.addObserver(
            forName: .worklogSaveFailed, object: nil, queue: .main
        ) { [weak self] notification in
            let text = notification.userInfo?[SafeSave.messageKey] as? String
            MainActor.assumeIsolated { () -> Void in
                self?.lastError = text ?? "Couldn\u{2019}t save your change."
            }
        })
        observerTokens.append(center.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.scheduleTakeawayRefresh() }
        })
    }

    /// CloudKit imports arrive in bursts; coalesce them.
    private func scheduleRemoteChangeReconcile() {
        remoteChangeTask?.cancel()
        remoteChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            SeedData.deduplicate(in: self.context)
            self.reconcile()
        }
    }

    /// Any save (History/Detail edits and deletions, imports) may change which takeaway applies; coalesce them.
    private func scheduleTakeawayRefresh() {
        didSaveTask?.cancel()
        didSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.refreshTakeaway()
        }
    }

    /// Re-evaluates the tick timer whenever `settings.menuBarShowsTimer` changes.
    func observeSettings() {
        withObservationTracking {
            _ = settings.menuBarShowsTimer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateTickTimer()
                self?.observeSettings()
            }
        }
    }
}
