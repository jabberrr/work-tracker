import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Helpers for the "store couldn't be opened" recovery flow (Settings ▸ Data ▸ Recover…).
enum SettingsRecovery {
    /// True when Worklog runs on the in-memory fallback because the on-disk store failed to open
    /// (not for previews/tests, which are in memory on purpose) and Recover may move it aside — never for a store a
    /// newer Worklog made (`isStoreFromNewerVersion`).
    @MainActor
    static func isNeeded(_ persistence: PersistenceController) -> Bool {
        persistence.isRecoveryMode && !persistence.isStoreFromNewerVersion
    }

    /// Decodes a user-picked archive. When it is a backup whose images live in a sibling folder the sandbox can't
    /// read yet (`attachmentStore`), asks once for access to the backup's folder and decodes again. The result's
    /// `missingImageCount` says how many images are still missing.
    @MainActor
    static func decodeRequestingImageFolder(_ url: URL, exporter: ExportService) throws -> ExportArchive {
        let archive = try exporter.decodeArchive(from: url)
        guard archive.missingImageCount > 0, archive.attachmentStore != nil else { return archive }
        let panel = NSOpenPanel()
        panel.title = "Allow Access to the Backup\u{2019}s Images"
        panel.message = "Choose the folder that contains \u{201C}\(url.lastPathComponent)\u{201D} so Worklog can read its images."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return archive }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return (try? exporter.decodeArchive(from: url)) ?? archive
    }

    /// The reason text of the in-memory fallback, if any.
    @MainActor
    static func failureReason(_ persistence: PersistenceController) -> String? {
        if case .inMemory(let reason) = persistence.storeMode, reason != "Preview" { return reason }
        return nil
    }
}

/// Opens `SettingsRecoverySheet`, optionally with a backup already chosen (a backup row's "Restore…").
struct SettingsRecoveryRequest: Identifiable {
    let id = UUID()
    let preselected: BackupFile?
}

/// Recovery for a store that couldn't be opened. Never restores into the temporary in-memory store; instead:
/// 1. moves the damaged store files aside (`persistence.quarantineStore()`, never deletes),
/// 2. records what to load on the next launch (`PersistenceController.scheduleRecovery(backupURL:)`: a backup, or
///    nil = start fresh and download again from iCloud when sync is on),
/// 3. relaunches (`PersistenceController.relaunchApp()`); AppServices then opens a new store and restores.
@MainActor
struct SettingsRecoverySheet: View {
    private enum Choice: Hashable {
        case backup, fresh
    }

    @Environment(PersistenceController.self) private var persistence
    @Environment(BackupService.self) private var backups
    @Environment(ExportService.self) private var exporter
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let request: SettingsRecoveryRequest

    @State private var choice: Choice = .backup
    /// A backup from the list (by URL), or a file the user picked (`chosenFile`).
    @State private var selectedBackupURL: URL?
    @State private var chosenFile: URL?
    /// `chosenFile` decoded (images rehydrated where they could be read).
    @State private var chosenArchive: ExportArchive?
    @State private var confirms = false
    @State private var errorText: String?
    @State private var didAppear = false

    /// Whether the next launch will use CloudKit (the toggle is read at launch).
    private var nextLaunchSyncs: Bool {
        settings.iCloudSyncEnabled && Entitlements.hasCloudKit
    }

    /// Backups made before this launch: anything written since then holds only this session's in-memory data.
    private var backupsBeforeLaunch: [BackupFile] {
        guard let launch = NSRunningApplication.current.launchDate else { return backups.backups }
        return backups.backups.filter { $0.date < launch }
    }

    private var sourceURL: URL? {
        chosenFile ?? selectedBackupURL
    }

    private var canConfirm: Bool {
        choice == .fresh || sourceURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingL) {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                Text("Recover data")
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Your data couldn’t be opened. Changes won’t be saved.")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = SettingsRecovery.failureReason(persistence) {
                    Text(reason)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Worklog moves the damaged data aside, relaunches and then:")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("After relaunching", selection: $choice) {
                Text("Restores a backup").tag(Choice.backup)
                Text(nextLaunchSyncs ? "Starts fresh and downloads from iCloud" : "Starts with empty data")
                    .tag(Choice.fresh)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Group {
                switch choice {
                case .backup: backupChooser
                case .fresh: freshExplanation
                }
            }
            .padding(.leading, theme.spacingL)

            SettingsFootnote("Changes since launch are lost, so export JSON first to keep them.")

            if let errorText {
                InlineBanner(errorText, style: .error, onDismiss: { self.errorText = nil })
            }

            HStack(spacing: theme.spacingS) {
                Menu("Show in Finder") {
                    Button("Damaged Data Store") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppConstants.storeURL])
                    }
                    Button("Recovered Folder") { revealRecoveredFolder() }
                    Button("Backups Folder") { backups.revealInFinder() }
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()

                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Relaunch…") { confirms = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 540)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            backups.refreshList()
            if let preselected = request.preselected {
                selectedBackupURL = preselected.url
            } else {
                selectedBackupURL = (backupsBeforeLaunch.first ?? backups.backups.first)?.url
            }
            if selectedBackupURL == nil { choice = .fresh }
        }
        .confirmationDialog("Move damaged data aside and relaunch?", isPresented: $confirms,
                            titleVisibility: .visible) {
            Button("Relaunch") { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var backupChooser: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            if let chosenFile {
                if let missing = chosenArchive?.missingImageCount, missing > 0 {
                    SettingsFootnote("\(missing) \(missing == 1 ? "image is" : "images are") missing from this backup.")
                }
                HStack(spacing: theme.spacingS) {
                    Image(systemName: "doc")
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(chosenFile.lastPathComponent)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Use Backup") {
                        self.chosenFile = nil
                        self.chosenArchive = nil
                    }
                        .buttonStyle(QuietButtonStyle())
                        .controlSize(.small)
                }
            } else if backups.backups.isEmpty {
                Text("No backups found.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Picker("Backup", selection: $selectedBackupURL) {
                    ForEach(backups.backups) { backup in
                        Text(Self.backupTitle(backup)).tag(Optional(backup.url))
                    }
                }
                .frame(maxWidth: 420)
            }
            HStack(spacing: theme.spacingS) {
                Button("Choose File…", action: chooseFile)
                    .buttonStyle(QuietButtonStyle())
                    .controlSize(.small)
                Spacer()
            }
            SettingsFootnote(nextLaunchSyncs
                             ? "The backup is merged with what’s already in iCloud."
                             : "The backup becomes your data on this Mac.")
        }
    }

    private var freshExplanation: some View {
        SettingsFootnote(nextLaunchSyncs
                         ? "Worklog starts empty and downloads your sessions from iCloud again."
                         : "Worklog starts empty, and you can restore a backup later.")
    }

    private var confirmationText: String {
        let restore: String
        switch choice {
        case .backup:
            restore = "restores “\(sourceURL?.lastPathComponent ?? "the backup")”"
        case .fresh:
            restore = nextLaunchSyncs ? "downloads your data from iCloud again" : "starts with empty data"
        }
        return "Worklog relaunches and \(restore), and unsaved changes are lost."
    }

    static func backupTitle(_ backup: BackupFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file)
        return "\(backup.date.shortDateTime) · \(SettingsDataTab.backupDetail(backup)) · \(size)"
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Worklog Backup or Export"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            chosenArchive = try SettingsRecovery.decodeRequestingImageFolder(url, exporter: exporter)
        } catch {
            Log.ui.error("Recovery: the chosen file can't be read: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn\u{2019}t read \u{201C}\(url.lastPathComponent)\u{201D}."
            return
        }
        chosenFile = url
        choice = .backup
    }

    private func revealRecoveredFolder() {
        let folder = persistence.recoveredFolderURL
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            errorText = "The Recovered folder is empty."
        }
    }

    /// Order matters: copy an outside file in first (the sandbox can't read it after relaunching), then move the
    /// damaged store aside, then record the restore, then relaunch. Nothing is deleted at any step.
    private func perform() {
        var restoreURL: URL?
        if choice == .backup {
            guard let source = sourceURL else {
                errorText = "Choose a backup first."
                return
            }
            // Make sure the file can be read before anything is copied or moved.
            let archive: ExportArchive
            do {
                if chosenFile != nil, let chosenArchive {
                    archive = chosenArchive
                } else {
                    archive = try exporter.decodeArchive(from: source)
                }
            } catch {
                Log.ui.error("Recovery: the backup can't be read: \(error.localizedDescription, privacy: .public)")
                errorText = "Couldn’t read “\(source.lastPathComponent)”, so nothing changed."
                return
            }
            if chosenFile != nil, !Self.isInsideAppSupport(source) {
                do {
                    restoreURL = try copyIntoContainer(archive, named: source.lastPathComponent)
                } catch {
                    Log.ui.error("Recovery: copying the chosen file failed: \(error.localizedDescription, privacy: .public)")
                    errorText = "Couldn’t copy “\(source.lastPathComponent)”, so nothing changed."
                    return
                }
            } else {
                restoreURL = source
            }
        }

        let movedTo: URL?
        do {
            movedTo = try persistence.quarantineStore()
        } catch StoreRecoveryError.nothingToMove {
            // No store file on disk (it was never created or is already gone): just schedule and relaunch.
            movedTo = nil
        } catch {
            Log.ui.error("Recovery: moving the store aside failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn’t move the damaged data aside, so nothing changed."
            return
        }

        do {
            try PersistenceController.scheduleRecovery(backupURL: restoreURL)
        } catch {
            Log.ui.error("Recovery: scheduling the restore failed: \(error.localizedDescription, privacy: .public)")
            if let movedTo {
                Log.ui.error("Recovery: the damaged store is in \(movedTo.lastPathComponent, privacy: .public)")
            }
            errorText = "Couldn’t schedule the restore. Relaunch, then restore from Data."
            return
        }

        PersistenceController.relaunchApp()
    }

    /// A file already in Worklog's own folder (e.g. a backup picked by hand) is restored in place, so backups whose
    /// images live in `Backups/Attachments` keep them.
    private static func isInsideAppSupport(_ url: URL) -> Bool {
        let base = AppConstants.applicationSupportURL.standardizedFileURL.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Writes a user-chosen archive into Application Support/Worklog/Recovered so the next launch can read it. The
    /// decoded archive is written with its images embedded (L2): a backup's images live in a sibling `Attachments`
    /// folder that a plain file copy would leave behind (and the sandbox can't read after relaunching).
    private func copyIntoContainer(_ archive: ExportArchive, named sourceName: String) throws -> URL {
        let folder = persistence.recoveredFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8)
        let destination = folder.appending(path: "Import-\(AppConstants.fileTimestamp())-\(suffix).json",
                                           directoryHint: .notDirectory)
        var embedded = archive
        embedded.attachmentStore = nil
        let data = try ExportArchive.makeEncoder(pretty: false).encode(embedded)
        try data.write(to: destination, options: .atomic)
        Log.ui.info("Recovery: wrote \(sourceName, privacy: .private) as \(destination.lastPathComponent, privacy: .public)")
        return destination
    }
}
