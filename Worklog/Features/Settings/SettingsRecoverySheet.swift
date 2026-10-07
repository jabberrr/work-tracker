import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Helpers for the "store couldn't be opened" recovery flow (Settings ▸ Data ▸ Recover…).
enum SettingsRecovery {
    /// True when Worklog runs on the in-memory fallback because the on-disk store failed to open
    /// (not for previews/tests, which are in memory on purpose).
    @MainActor
    static func isNeeded(_ persistence: PersistenceController) -> Bool {
        persistence.isRecoveryMode
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
                Text("Recover Worklog’s data")
                    .font(theme.titleFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Worklog couldn’t open its data store, so it’s running on a temporary store and nothing you change now is saved.")
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

            Text("Worklog moves the damaged store into a “Recovered” folder (nothing is deleted), relaunches, and then:")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("After relaunching", selection: $choice) {
                Text("Restores a backup").tag(Choice.backup)
                Text(nextLaunchSyncs ? "Starts fresh and downloads your data from iCloud" : "Starts with empty data")
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

            SettingsFootnote("Changes made since Worklog opened this time aren’t kept. Export them as JSON first if you need them.")

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
                .help("The damaged store stays where it is until you continue. Moved stores are kept in the Recovered folder.")

                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Move Aside and Relaunch…") { confirms = true }
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
        .confirmationDialog("Move the damaged store aside and relaunch?", isPresented: $confirms,
                            titleVisibility: .visible) {
            Button("Move Aside and Relaunch") { perform() }
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
                    Button("Use a Backup Instead") { self.chosenFile = nil }
                        .buttonStyle(QuietButtonStyle())
                        .controlSize(.small)
                }
            } else if backups.backups.isEmpty {
                Text("There are no backups in Worklog’s Backups folder.")
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
                Button("Choose a File…", action: chooseFile)
                    .buttonStyle(QuietButtonStyle())
                    .controlSize(.small)
                    .help("Use a Worklog JSON export or a backup from another folder")
                Spacer()
            }
            SettingsFootnote(nextLaunchSyncs
                             ? "The backup is merged with what’s already in iCloud."
                             : "The backup becomes your data on this Mac.")
        }
    }

    private var freshExplanation: some View {
        SettingsFootnote(nextLaunchSyncs
                         ? "Worklog opens a new, empty store and downloads your sessions from iCloud again. This can take a few minutes."
                         : "Worklog opens a new, empty store. You can still restore a backup later in Settings ▸ Data.")
    }

    private var confirmationText: String {
        let restore: String
        switch choice {
        case .backup:
            restore = "restores “\(sourceURL?.lastPathComponent ?? "the backup")”"
        case .fresh:
            restore = nextLaunchSyncs ? "downloads your data from iCloud again" : "starts with empty data"
        }
        return "Worklog moves the damaged store into the Recovered folder, quits, opens again and \(restore). Unsaved changes from this session are lost."
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
        chosenFile = url
        choice = .backup
    }

    private func revealRecoveredFolder() {
        let folder = persistence.recoveredFolderURL
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            errorText = "Nothing has been moved to the Recovered folder yet."
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
            do {
                _ = try exporter.decodeArchive(from: source)
            } catch {
                Log.ui.error("Recovery: the backup can't be read: \(error.localizedDescription, privacy: .public)")
                errorText = "“\(source.lastPathComponent)” can’t be restored: \(error.localizedDescription) Nothing was changed."
                return
            }
            if chosenFile != nil, !Self.isInsideAppSupport(source) {
                do {
                    restoreURL = try copyIntoContainer(source)
                } catch {
                    Log.ui.error("Recovery: copying the chosen file failed: \(error.localizedDescription, privacy: .public)")
                    errorText = "Couldn’t copy “\(source.lastPathComponent)” into Worklog’s folder: \(error.localizedDescription) Nothing was changed."
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
            errorText = "The damaged store couldn’t be moved aside, so nothing was changed. \(error.localizedDescription)"
            return
        }

        do {
            try PersistenceController.scheduleRecovery(backupURL: restoreURL)
        } catch {
            Log.ui.error("Recovery: scheduling the restore failed: \(error.localizedDescription, privacy: .public)")
            let moved = movedTo.map { "The damaged store was moved to “\($0.lastPathComponent)” in the Recovered folder, but the" }
                ?? "The"
            errorText = "\(moved) restore couldn’t be scheduled (\(error.localizedDescription)). Relaunch Worklog and restore the backup from Settings ▸ Data."
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

    /// Copies a user-chosen file into Application Support/Worklog/Recovered so the next launch can read it.
    private func copyIntoContainer(_ source: URL) throws -> URL {
        let folder = persistence.recoveredFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        let suffix = UUID().uuidString.prefix(8)
        let destination = folder.appending(path: "Import-\(formatter.string(from: .now))-\(suffix).json",
                                           directoryHint: .notDirectory)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
