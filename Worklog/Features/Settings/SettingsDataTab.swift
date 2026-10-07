import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Data: export (JSON with/without images, sessions CSV, segments CSV), import (merge / replace), rolling backups
/// (back up now, schedule, retention, restore, reveal, delete) and delete-all.
///
/// When the store couldn't be opened (in-memory fallback) the tab leads with "Recover…" and every restore goes
/// through `SettingsRecoverySheet` (move the damaged store aside, relaunch, restore) — never into the temporary store.
@MainActor
struct SettingsDataTab: View {
    @Environment(ExportService.self) private var exporter
    @Environment(BackupService.self) private var backups
    @Environment(AppSettings.self) private var settings
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.theme) private var theme

    @AppStorage("settingsWindow.exportIncludesImages") private var exportIncludesImages = true
    @State private var lastExportURL: URL?
    @State private var pendingImport: SettingsPendingImport?
    @State private var message: SettingsDataMessage?
    @State private var backupToDelete: BackupFile?
    @State private var confirmsDeleteAll = false
    @State private var confirmsDeleteAllAgain = false
    @State private var recoveryRequest: SettingsRecoveryRequest?

    private var needsRecovery: Bool { SettingsRecovery.isNeeded(persistence) }

    var body: some View {
        @Bindable var settings = settings

        Form {
            if needsRecovery {
                recoverySection
            }

            exportSection
            if !needsRecovery {
                importSection
            }
            backupsSection(settings: $settings)
            if !needsRecovery {
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
        } message: { backup in
            Text("“\(backup.url.lastPathComponent)” is deleted permanently. This can’t be undone.")
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) { confirmsDeleteAllAgain = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every session, note, image, learning, label and tag is deleted from this Mac — and from iCloud if sync is on.")
        }
        .alert("Delete everything permanently?", isPresented: $confirmsDeleteAllAgain) {
            Button("Delete Everything", role: .destructive, action: deleteAllData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup of your current data is saved first. This can’t be undone from within Worklog except by restoring that backup.")
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        Section {
            InlineBanner("Worklog couldn’t open its data store, so nothing you change now is saved.",
                         systemImage: "exclamationmark.triangle.fill", style: .error,
                         actionTitle: "Recover…", action: { recoveryRequest = SettingsRecoveryRequest(preselected: nil) })
            SettingsFootnote("Recover moves the damaged store into a “Recovered” folder (it’s never deleted), relaunches Worklog and restores a backup — or starts fresh and downloads your data from iCloud when sync is on.")
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section("Export") {
            Toggle("Include images in JSON exports", isOn: $exportIncludesImages)
            SettingsFootnote("JSON is a complete archive you can import again. Without images the file is much smaller, but importing it with “Replace” can’t bring images back.")
            HStack(spacing: theme.spacingS) {
                Button {
                    export(kind: .json)
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(QuietButtonStyle())
                Button("Sessions CSV…") { export(kind: .sessionsCSV) }
                    .buttonStyle(QuietButtonStyle())
                    .help("One row per session: title, label, tags, times, active and paused minutes, learnings")
                Button("Segments CSV…") { export(kind: .segmentsCSV) }
                    .buttonStyle(QuietButtonStyle())
                    .help("One row per segment: times, active minutes, label, tags, focus")
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
            SettingsFootnote("Import a Worklog JSON export or backup. “Merge” adds sessions from the file and keeps everything else — where a session exists in both, the more recently edited version wins. “Replace” deletes all current data first. Either way, a backup of your current data is made first.")
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
            let archive = try exporter.decodeArchive(from: url)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(backups.lastBackupDate.map { "Last backup \($0.shortDateTime)" } ?? "No backups yet")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textPrimary)
                    Text("Saved in Application Support ▸ Worklog ▸ Backups")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
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
                .disabled(backups.isWorking || needsRecovery)
                .help(needsRecovery
                      ? "Backups are paused while the data store can’t be opened, so good backups aren’t replaced. Export JSON to keep this session’s changes."
                      : "Back up all data now")
                Button {
                    backups.revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Show backups in Finder")
                .accessibilityLabel("Show backups in Finder")
            }

            if let error = backups.lastError {
                InlineBanner(error, style: .error, onDismiss: { backups.lastError = nil })
            }

            Picker("Back up automatically", selection: settings.backupInterval) {
                ForEach(BackupInterval.allCases) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            SettingsFootnote("Automatic backups run only when something changed. A backup is also made when Worklog quits and before every restore.")
            Stepper(value: settings.backupRetentionCount, in: 1...100) {
                LabeledContent("Keep the latest") {
                    Text("\(self.settings.backupRetentionCount) backups")
                        .monospacedDigit()
                }
            }
            Toggle("Include images in backups", isOn: settings.backupIncludesAttachments)
            if !self.settings.backupIncludesAttachments {
                SettingsFootnote("Backups without images are small, but restoring one with “Replace” removes all images.")
            }

            if backups.backups.isEmpty {
                Text("No backups yet.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(backups.backups) { backup in
                    backupRow(backup)
                }
            }
        }
    }

    private func backupRow(_ backup: BackupFile) -> some View {
        HStack(spacing: theme.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.date.shortDateTime)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                Text(Self.reasonName(backup.reason))
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
                .help(needsRecovery ? "Move the damaged store aside, relaunch and restore this backup" : "Restore this backup")
            Menu {
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
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
            Divider()
            Button("Delete…", role: .destructive) { backupToDelete = backup }
        }
    }

    static func reasonName(_ reason: String) -> String {
        switch reason {
        case BackupReason.scheduled.rawValue: "Automatic"
        case BackupReason.onQuit.rawValue: "When Worklog quit"
        case BackupReason.manual.rawValue: "Manual"
        case BackupReason.beforeRestore.rawValue: "Before a restore or import"
        default: reason.capitalized
        }
    }

    private func backUpNow() {
        if backups.backupNow(reason: .manual) == nil, backups.lastError == nil {
            message = SettingsDataMessage(title: "Backup not made",
                                          text: "Worklog is busy or its data is in memory only. Try again in a moment.")
        }
    }

    private func prepareRestore(_ backup: BackupFile) {
        if needsRecovery {
            // Never restore into the temporary in-memory store: recover into a fresh on-disk store instead.
            recoveryRequest = SettingsRecoveryRequest(preselected: backup)
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
                    Text("Removes every session, label and tag. Stop a running session first.")
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
                                          text: "A safety backup couldn’t be made first. \(backups.lastError ?? "")")
            return
        }
        do {
            try exporter.deleteAllData()
            message = SettingsDataMessage(title: "All data deleted",
                                          text: "A backup of the deleted data is in the list above.")
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
/// always made first (BackupService.restore for backups, here for files) unless the store is in memory only.
@MainActor
private struct SettingsImportSheet: View {
    @Environment(ExportService.self) private var exporter
    @Environment(BackupService.self) private var backups
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
                Text("Merge — add sessions from the file, keep everything else").tag(ImportMode.merge)
                Text("Replace — delete all current data first").tag(ImportMode.replace)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if mode == .replace {
                if hasActiveSession {
                    InlineBanner("Stop the running session first. Replacing all data isn’t possible while a session is active.",
                                 style: .error)
                }
                if !archive.includesAttachments {
                    InlineBanner("This file was saved without images. Replacing deletes every image currently in Worklog, and they can’t be restored from this file.",
                                 systemImage: "photo", style: .warning)
                }
                SettingsFootnote(isBackup
                                 ? "Your current data is backed up automatically before restoring."
                                 : "Your current data is backed up automatically before replacing.")
            } else {
                SettingsFootnote("Sessions that exist in both keep the more recently edited version, and a running session is never changed. Your current data is backed up automatically first.")
                if !archive.includesAttachments {
                    SettingsFootnote("This file has no images. Merging keeps the images you already have.")
                }
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
            Button("Replace All Data", role: .destructive) { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(archive.includesAttachments
                 ? "Everything currently in Worklog is deleted and replaced with \(sourceName)."
                 : "Everything currently in Worklog — including all images — is deleted and replaced with \(sourceName), which has no images.")
        }
    }

    private var contentsDescription: String {
        let sessions = archive.sessions.count
        var parts = [
            "\(sessions) \(sessions == 1 ? "session" : "sessions")",
            "\(archive.labels.count) \(archive.labels.count == 1 ? "label" : "labels")",
            "\(archive.tags.count) \(archive.tags.count == 1 ? "tag" : "tags")",
        ]
        parts.append(archive.includesAttachments
                     ? "\(archiveImageCount) \(archiveImageCount == 1 ? "image" : "images")"
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
                // Safety backup before merging or replacing (pointless for a store that lives in memory only).
                if !exporter.isEphemeralStore {
                    guard backups.backupNow(reason: .beforeRestore) != nil else {
                        errorText = "A safety backup of your current data couldn’t be made, so nothing was imported. \(backups.lastError ?? "")"
                        return
                    }
                }
                summary = try exporter.importArchive(archive, mode: mode)
            }
            onFinish(SettingsDataMessage(title: isBackup ? "Backup restored" : "Import complete",
                                         text: summary.description))
        } catch {
            Log.ui.error("Import failed: \(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
        }
    }
}
