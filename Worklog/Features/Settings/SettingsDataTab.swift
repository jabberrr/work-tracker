import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Data: export (JSON with/without images, sessions CSV, segments CSV), import (merge / replace), rolling backups
/// (back up now, schedule, retention, restore, reveal, delete) and delete-all.
///
/// When the store couldn't be opened (in-memory fallback) the tab leads with "Recover…" and every restore goes
/// through `SettingsRecoverySheet` (move the damaged store aside, relaunch, restore) — never into the temporary store.
/// A store made by a newer Worklog is never moved aside: the tab only says so.
///
/// When the store synced with another CloudKit environment than this build (`persistence.environmentMismatch`), the
/// tab leads with "Move to iCloud <env>…" (verified pinned backup incl. images → marker → relaunch; the next launch
/// moves the old store to Recovered/Env-…, opens a fresh CloudKit store and restores), "Use iCloud <env> Data…"
/// (same, but nothing is restored: the fresh store downloads what that environment already holds — for a second Mac
/// whose data the first Mac already moved) or "Keep Local Only".
@MainActor
struct SettingsDataTab: View {
    @Environment(ExportService.self) private var exporter
    @Environment(BackupService.self) private var backups
    @Environment(AppSettings.self) private var settings
    @Environment(PersistenceController.self) private var persistence
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme

    @AppStorage("settingsWindow.exportIncludesImages") private var exportIncludesImages = true
    @State private var lastExportURL: URL?
    @State private var pendingImport: SettingsPendingImport?
    @State private var message: SettingsDataMessage?
    @State private var backupToDelete: BackupFile?
    @State private var confirmsDeleteAll = false
    @State private var confirmsDeleteAllAgain = false
    @State private var recoveryRequest: SettingsRecoveryRequest?
    @State private var confirmsMove = false
    @State private var confirmsAdopt = false
    @State private var isMoving = false

    /// Recover… is offered (the store failed to open and isn't from a newer Worklog).
    private var needsRecovery: Bool { SettingsRecovery.isNeeded(persistence) }
    /// Running on the in-memory fallback: nothing can be imported or deleted for real.
    private var storeUnavailable: Bool { persistence.isRecoveryMode }

    var body: some View {
        @Bindable var settings = settings

        Form {
            if needsRecovery {
                recoverySection
            } else if persistence.isStoreFromNewerVersion {
                newerVersionSection
            }
            if let mismatch = persistence.environmentMismatch, !storeUnavailable {
                environmentSection(mismatch)
            }

            exportSection
            if !storeUnavailable {
                importSection
            }
            backupsSection(settings: $settings)
            if !storeUnavailable {
                dangerSection
            }
        }
        .formStyle(.grouped)
        .onAppear { backups.refreshList() }
        .sheet(item: $recoveryRequest) { request in
            SettingsRecoverySheet(request: request)
        }
        .sheet(item: $pendingImport) { pending in
            SettingsImportSheet(pending: pending) { result in
                pendingImport = nil
                message = result
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
               presenting: message) { _ in
            Button("OK", role: .cancel) { message = nil }
        } message: { item in
            Text(item.text)
        }
        .confirmationDialog("Delete this backup?",
                            isPresented: Binding(get: { backupToDelete != nil }, set: { if !$0 { backupToDelete = nil } }),
                            titleVisibility: .visible, presenting: backupToDelete) { backup in
            Button("Delete Backup", role: .destructive) {
                backups.delete(backup)
                backupToDelete = nil
            }
            Button("Cancel", role: .cancel) { backupToDelete = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) { confirmsDeleteAllAgain = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything is deleted here, and in iCloud if sync is on.")
        }
        .alert("Delete everything permanently?", isPresented: $confirmsDeleteAllAgain) {
            Button("Delete Everything", role: .destructive, action: deleteAllData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is saved first.")
        }
        .confirmationDialog(moveTitle, isPresented: $confirmsMove, titleVisibility: .visible) {
            Button("Back Up and Relaunch") { moveToBuildEnvironment() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Worklog backs up everything, images included, relaunches and uploads your data. "
                 + "The current copy stays in the Recovered folder.")
        }
        .confirmationDialog(adoptTitle, isPresented: $confirmsAdopt, titleVisibility: .visible) {
            Button("Back Up and Relaunch") { moveToBuildEnvironment(adoptingCloudData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Worklog backs up this Mac\u{2019}s data, relaunches and downloads what\u{2019}s already in iCloud. "
                 + "Nothing from this Mac is uploaded; its copy stays in the Recovered folder.")
        }
    }

    // MARK: - iCloud environment (C1b)

    private var targetEnvironmentName: String {
        (persistence.environmentMismatch?.build ?? persistence.buildEnvironment).rawValue
    }

    private var moveTitle: String {
        "Move your data to iCloud \(targetEnvironmentName)?"
    }

    private var adoptTitle: String {
        "Use the data in iCloud \(targetEnvironmentName)?"
    }

    private func environmentSection(_ mismatch: EnvironmentMismatch) -> some View {
        Section("iCloud") {
            InlineBanner("This data syncs with iCloud \(mismatch.store.rawValue), but this build uses "
                         + "\(mismatch.build.rawValue). It\u{2019}s saved on this Mac only for now.",
                         systemImage: "icloud.slash", style: .warning)
            // Two rows when the three buttons don't fit side by side.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.spacingS) {
                    environmentButtons(mismatch)
                    Spacer(minLength: 0)
                    movingIndicator
                }
                VStack(alignment: .leading, spacing: theme.spacingS) {
                    HStack(spacing: theme.spacingS) {
                        moveButton(mismatch)
                        adoptButton(mismatch)
                    }
                    HStack(spacing: theme.spacingS) {
                        keepLocalButton
                        Spacer(minLength: 0)
                        movingIndicator
                    }
                }
            }
            SettingsFootnote(environmentFootnote(mismatch))
        }
    }

    private func environmentFootnote(_ mismatch: EnvironmentMismatch) -> String {
        guard settings.iCloudSyncEnabled else { return "Kept on this Mac. You can still move it later." }
        return "First Mac: Move uploads this Mac\u{2019}s data. Other Macs: Use iCloud \(mismatch.build.rawValue) "
            + "Data downloads what\u{2019}s there. Both back up first; nothing is deleted."
    }

    @ViewBuilder
    private func environmentButtons(_ mismatch: EnvironmentMismatch) -> some View {
        moveButton(mismatch)
        adoptButton(mismatch)
        keepLocalButton
    }

    private func moveButton(_ mismatch: EnvironmentMismatch) -> some View {
        Button("Move to iCloud \(mismatch.build.rawValue)\u{2026}") { confirmsMove = true }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isMoving || backups.isWorking)
            .fixedSize()
    }

    private func adoptButton(_ mismatch: EnvironmentMismatch) -> some View {
        Button("Use iCloud \(mismatch.build.rawValue) Data\u{2026}") { confirmsAdopt = true }
            .buttonStyle(QuietButtonStyle())
            .disabled(isMoving || backups.isWorking)
            .fixedSize()
    }

    private var keepLocalButton: some View {
        Button("Keep Local Only", action: keepLocalOnly)
            .buttonStyle(QuietButtonStyle())
            .disabled(isMoving || !settings.iCloudSyncEnabled)
            .fixedSize()
    }

    @ViewBuilder
    private var movingIndicator: some View {
        if isMoving {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Backing up")
        }
    }

    /// Verified, pinned full backup → marker (`environmentMove`) → relaunch. Nothing changes if any step fails.
    /// `adoptingCloudData` ("Use iCloud <env> Data"): the marker has no backup, so the next launch moves the store
    /// aside and opens a fresh CloudKit store that downloads the environment's data; the backup is only the way back.
    private func moveToBuildEnvironment(adoptingCloudData: Bool = false) {
        guard let mismatch = persistence.environmentMismatch else { return }
        if exporter.hasActiveSession() {
            message = SettingsDataMessage(title: "Session running",
                                          text: DataTransferError.sessionActive.localizedDescription)
            return
        }
        isMoving = true
        defer { isMoving = false }
        let backup: BackupFile
        do {
            backup = try backups.makeVerifiedFullBackup()
        } catch {
            Log.ui.error("Move: backup failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Nothing was moved", text: error.localizedDescription)
            return
        }
        do {
            try PersistenceController.scheduleRecovery(backupURL: adoptingCloudData ? nil : backup.url,
                                                       environmentMove: mismatch.build)
        } catch {
            Log.ui.error("Move: scheduling failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Nothing was moved", text: error.localizedDescription)
            return
        }
        // The move needs sync at the next launch (it is skipped otherwise).
        settings.iCloudSyncEnabled = true
        let action = adoptingCloudData ? "Use iCloud data" : "Move"
        Log.ui.info("\(action, privacy: .public) (\(mismatch.build.rawValue, privacy: .public)) scheduled; relaunching")
        PersistenceController.relaunchApp()
    }

    /// Stays local-only on purpose: sync off (so nothing is switched later by accident) and the banner dismissed.
    private func keepLocalOnly() {
        settings.iCloudSyncEnabled = false
        if case .localOnly(let reason) = persistence.storeMode {
            settings.dismissedLocalOnlyBannerReason = reason
        }
    }

    // MARK: - Newer data (M5)

    private var newerVersionSection: some View {
        Section {
            InlineBanner("This data was made by a newer version of Worklog. Changes here won\u{2019}t be saved.",
                         systemImage: "exclamationmark.triangle.fill", style: .error)
            SettingsFootnote("Install the latest Worklog to open it. Nothing was changed.")
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        Section {
            InlineBanner("Your data couldn’t be opened. Changes won’t be saved.",
                         systemImage: "exclamationmark.triangle.fill", style: .error,
                         actionTitle: "Recover…", action: { recoveryRequest = SettingsRecoveryRequest(preselected: nil) })
            SettingsFootnote("Moves the damaged data aside, never deletes it, and relaunches.")
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section("Export") {
            Toggle("Include images in JSON", isOn: $exportIncludesImages)
            if !exportIncludesImages {
                SettingsFootnote("Replacing from this file can’t bring images back.")
            }
            HStack(spacing: theme.spacingS) {
                Button {
                    export(kind: .json)
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(QuietButtonStyle())
                Button("Export Sessions CSV…") { export(kind: .sessionsCSV) }
                    .buttonStyle(QuietButtonStyle())
                Button("Export Segments CSV…") { export(kind: .segmentsCSV) }
                    .buttonStyle(QuietButtonStyle())
            }
            if profileStore.showsProfileScope {
                SettingsFootnote("Includes all profiles.")
            }
            if let url = lastExportURL {
                InlineBanner("Exported “\(url.lastPathComponent)”.", style: .success,
                             actionTitle: "Show in Finder",
                             action: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                             onDismiss: { lastExportURL = nil })
            }
        }
    }

    private enum ExportKind {
        case json, sessionsCSV, segmentsCSV
    }

    private func export(kind: ExportKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        switch kind {
        case .json:
            panel.title = "Export Worklog Data"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = ExportService.defaultFilename(ext: "json")
        case .sessionsCSV:
            panel.title = "Export Sessions as CSV"
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = ExportService.defaultFilename(ext: "csv")
                .replacingOccurrences(of: "Worklog-Export-", with: "Worklog-Sessions-")
        case .segmentsCSV:
            panel.title = "Export Segments as CSV"
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = ExportService.defaultFilename(ext: "csv")
                .replacingOccurrences(of: "Worklog-Export-", with: "Worklog-Segments-")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .json: try exporter.exportJSON(to: url, includeAttachments: exportIncludesImages)
            case .sessionsCSV: try exporter.exportSessionsCSV(to: url)
            case .segmentsCSV: try exporter.exportSegmentsCSV(to: url)
            }
            lastExportURL = url
        } catch {
            Log.ui.error("Export failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Export failed", text: error.localizedDescription)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section("Import") {
            HStack {
                Button {
                    chooseImportFile()
                } label: {
                    Label("Import JSON…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
            }
            SettingsFootnote("Replace erases current data; a backup is made first.")
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Worklog Data"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try SettingsRecovery.decodeRequestingImageFolder(url, exporter: exporter)
            pendingImport = SettingsPendingImport(source: .file(url), archive: archive)
        } catch {
            Log.ui.error("Import decode failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Couldn’t read the file", text: error.localizedDescription)
        }
    }

    // MARK: - Backups

    private func backupsSection(settings: Bindable<AppSettings>) -> some View {
        Section("Backups") {
            HStack(spacing: theme.spacingS) {
                Text(backups.lastBackupDate.map { "Last backup \($0.shortDateTime)" } ?? "No backups yet")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if backups.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Backing up")
                }
                Button {
                    backUpNow()
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(backups.isWorking || storeUnavailable)
                .help(storeUnavailable ? "Paused while data can’t open" : "Back up now")
                Button {
                    backups.revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Show in Finder")
                .accessibilityLabel("Show backups in Finder")
            }

            if let error = backups.lastError {
                InlineBanner(error, style: .error, onDismiss: { backups.lastError = nil })
            }

            // "Back up **hourly**", but "Automatic backups **Off**" (not "Back up off").
            ValuePicker(self.settings.backupInterval == .off ? "Automatic backups" : "Back up",
                        selection: settings.backupInterval, options: BackupInterval.allCases,
                        title: { $0 == .off ? $0.displayName : $0.displayName.lowercased() })
            SettingsFootnote("Runs after changes and when Worklog quits.")
            ValueStepper("Keep the latest", value: settings.backupRetentionCount, in: 1...100,
                         format: { "\($0) \($0 == 1 ? "backup" : "backups")" })
            Toggle("Include images", isOn: settings.backupIncludesAttachments)
            if !self.settings.backupIncludesAttachments {
                SettingsFootnote("Replace then keeps only images still in Worklog.")
            }

            ForEach(backups.backups) { backup in
                backupRow(backup)
            }
        }
    }

    private func backupRow(_ backup: BackupFile) -> some View {
        HStack(spacing: theme.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.spacingXS) {
                    Text(backup.date.shortDateTime)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textPrimary)
                    if backup.isPinned {
                        Image(systemName: "pin.fill")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.accent)
                            .help("Pinned")
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(Self.backupDetail(backup))
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file))
                .font(theme.monoFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
            Button("Restore…") { prepareRestore(backup) }
                .buttonStyle(QuietButtonStyle())
                .controlSize(.small)
                .disabled(backups.isWorking)
                .help("Restore backup")
            Menu {
                pinButton(backup)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                Divider()
                Button("Delete…", role: .destructive) { backupToDelete = backup }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions for this backup")
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Restore…") { prepareRestore(backup) }
            pinButton(backup)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
            Divider()
            Button("Delete…", role: .destructive) { backupToDelete = backup }
        }
    }

    private func pinButton(_ backup: BackupFile) -> some View {
        Button(backup.isPinned ? "Unpin" : "Pin") {
            backups.setPinned(!backup.isPinned, for: backup)
        }
    }

    /// "Automatic · 42 sessions" (the count is unknown for older backups).
    static func backupDetail(_ backup: BackupFile) -> String {
        var parts = [reasonName(backup.reason)]
        if let count = backup.sessionCount {
            parts.append("\(count) \(count == 1 ? "session" : "sessions")")
        }
        if backup.isPinned { parts.append("pinned") }
        return parts.joined(separator: " · ")
    }

    static func reasonName(_ reason: String) -> String {
        switch reason {
        case BackupReason.scheduled.rawValue: "Automatic"
        case BackupReason.onQuit.rawValue: "On quit"
        case BackupReason.manual.rawValue: "Manual"
        case BackupReason.beforeRestore.rawValue: "Before restore"
        case BackupReason.beforeChange.rawValue: "Before change"
        default: reason.capitalized
        }
    }

    private func backUpNow() {
        if backups.backupNow(reason: .manual) == nil, backups.lastError == nil {
            message = SettingsDataMessage(title: "Couldn’t back up", text: "Try again in a moment.")
        }
    }

    private func prepareRestore(_ backup: BackupFile) {
        if storeUnavailable {
            // Never restore into the temporary in-memory store: recover into a fresh on-disk store instead.
            if needsRecovery {
                recoveryRequest = SettingsRecoveryRequest(preselected: backup)
            } else {
                message = SettingsDataMessage(title: "Can\u{2019}t restore here",
                                              text: StoreRecoveryError.storeIsNewer.localizedDescription
                                                + " Install the latest Worklog first.")
            }
            return
        }
        do {
            let archive = try exporter.decodeArchive(from: backup.url)
            pendingImport = SettingsPendingImport(source: .backup(backup), archive: archive)
        } catch {
            Log.ui.error("Backup decode failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Couldn’t read the backup", text: error.localizedDescription)
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        Section("Danger zone") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete all data")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textPrimary)
                    Text("Removes every session, label and tag.")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Delete All Data…") { confirmsDeleteAll = true }
                    .buttonStyle(DestructiveButtonStyle())
            }
        }
    }

    private func deleteAllData() {
        if exporter.hasActiveSession() {
            message = SettingsDataMessage(title: "Session running",
                                          text: DataTransferError.sessionActive.localizedDescription)
            return
        }
        guard backups.backupNow(reason: .manual) != nil else {
            message = SettingsDataMessage(title: "Nothing was deleted",
                                          text: backups.lastError ?? "The safety backup failed.")
            return
        }
        do {
            try exporter.deleteAllData()
            message = SettingsDataMessage(title: "All data deleted",
                                          text: "A backup is in the list above.")
        } catch {
            Log.ui.error("Delete all failed: \(error.localizedDescription, privacy: .public)")
            message = SettingsDataMessage(title: "Couldn’t delete data", text: error.localizedDescription)
        }
    }
}

// MARK: - Supporting types

struct SettingsDataMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct SettingsPendingImport: Identifiable {
    enum Source {
        case file(URL)
        case backup(BackupFile)
    }

    let id = UUID()
    let source: Source
    let archive: ExportArchive
}

// MARK: - Import / restore sheet

/// Shows what an archive contains, lets the user pick Merge or Replace, warns about images and a running session,
/// asks once more for Replace, then imports (file) or restores (backup). A safety backup of the current data is
/// always made first (`BackupService.restore` / `BackupService.importArchive`) unless the store is in memory only.
@MainActor
private struct SettingsImportSheet: View {
    @Environment(ExportService.self) private var exporter
    @Environment(BackupService.self) private var backups
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme

    let pending: SettingsPendingImport
    let onFinish: (SettingsDataMessage?) -> Void

    @State private var mode: ImportMode = .merge
    @State private var confirmsReplace = false
    @State private var errorText: String?
    /// Checked when the sheet appears (not in body); the service re-checks on import anyway.
    @State private var hasActiveSession = false

    private var archive: ExportArchive { pending.archive }

    private var isBackup: Bool {
        if case .backup = pending.source { return true }
        return false
    }

    private var sourceName: String {
        switch pending.source {
        case .file(let url): return url.lastPathComponent
        case .backup(let backup): return "Backup from \(backup.date.shortDateTime)"
        }
    }


    /// An older file (no profiles) puts its sessions in the home profile: its name, when there is a choice.
    private var legacyHomeProfileName: String? {
        guard archive.profiles == nil, profileStore.hasMultipleProfiles else { return nil }
        let active = ModelLiveness.live(profileStore.profiles)
        let home = active.first { $0.uuid == ProfileOps.defaultProfileUUID } ?? active.first
        return home?.displayName
    }

    private var archiveImageCount: Int {
        archive.sessions.reduce(0) { $0 + $1.attachments.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingL) {
            Text(isBackup ? "Restore backup" : "Import data")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: theme.spacingXS) {
                Text(sourceName)
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(contentsDescription)
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Mode", selection: $mode) {
                Text("Merge with current data").tag(ImportMode.merge)
                Text("Replace current data").tag(ImportMode.replace)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if archive.missingImageCount > 0 {
                InlineBanner("\(archive.missingImageCount) \(archive.missingImageCount == 1 ? "image is" : "images are") "
                             + "missing from this backup. Copies already in Worklog are kept.",
                             systemImage: "photo", style: .warning)
            }
            if mode == .replace {
                if hasActiveSession {
                    InlineBanner("Stop the running session first.", style: .error)
                }
                if !archive.includesAttachments {
                    InlineBanner("This file has no images. Only images still in Worklog are kept.",
                                 systemImage: "photo", style: .warning)
                }
                SettingsFootnote("Your current data is backed up first.")
            } else {
                SettingsFootnote("The more recently edited copy of a session wins.")
            }
            if mode == .merge, let home = legacyHomeProfileName {
                SettingsFootnote("This file has no profiles, so its sessions go to “\(home)”.")
            }

            if let errorText {
                InlineBanner(errorText, style: .error, onDismiss: { self.errorText = nil })
            }

            HStack(spacing: theme.spacingS) {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isBackup ? "Restore" : "Import") {
                    if mode == .replace {
                        confirmsReplace = true
                    } else {
                        perform()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(mode == .replace && hasActiveSession)
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 520)
        .onAppear { hasActiveSession = exporter.hasActiveSession() }
        .onChange(of: mode) { hasActiveSession = exporter.hasActiveSession() }
        .confirmationDialog("Replace all data?", isPresented: $confirmsReplace, titleVisibility: .visible) {
            Button("Replace All", role: .destructive) { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(archive.includesAttachments && archive.missingImageCount == 0
                 ? "Everything in Worklog is replaced with \(sourceName)."
                 : "Everything in Worklog is replaced with \(sourceName). Images it lacks are kept only if Worklog still has them.")
        }
    }

    private var contentsDescription: String {
        let sessions = archive.sessions.count
        var parts = [
            "\(sessions) \(sessions == 1 ? "session" : "sessions")",
            "\(archive.labels.count) \(archive.labels.count == 1 ? "label" : "labels")",
            "\(archive.tags.count) \(archive.tags.count == 1 ? "tag" : "tags")",
        ]
        let profiles = archive.profiles?.count ?? 0
        if profiles > 0 {
            parts.insert("\(profiles) \(profiles == 1 ? "profile" : "profiles")", at: 1)
        }
        let imageCount = archiveImageCount - archive.missingImageCount
        parts.append(archive.includesAttachments
                     ? "\(imageCount) \(imageCount == 1 ? "image" : "images")"
                     : "no images")
        return parts.joined(separator: " · ") + " — exported \(archive.exportedAt.shortDateTime)"
    }

    private func perform() {
        do {
            let summary: ImportSummary
            switch pending.source {
            case .backup(let backup):
                summary = try backups.restore(from: backup, mode: mode)
            case .file:
                // BackupService makes the safety backup first (merge and replace alike) and refreshes the list.
                summary = try backups.importArchive(archive, mode: mode)
            }
            onFinish(SettingsDataMessage(title: isBackup ? "Backup restored" : "Import complete",
                                         text: summary.description))
        } catch {
            Log.ui.error("Import failed: \(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
        }
    }
}
