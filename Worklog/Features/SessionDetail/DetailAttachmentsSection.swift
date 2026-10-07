import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Images attached to a session: adaptive grid of thumbnails (thumbnailData only), caption under each,
/// add via open panel / paste (⌘V while the section is focused, or the paste button) / drag & drop,
/// a Quick Look–style viewer (full image), save to disk and delete. Import goes through `AttachmentImporter`
/// (downscaled, compressed, inserted, linked, saved); delete through `SessionEditor.deleteAttachment`.
@MainActor
struct DetailAttachmentsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var environmentContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let session: WorkSession

    @State private var isDropTargeted = false
    @State private var isImporting = false
    @State private var viewerSelection: DetailImageSelection?
    @State private var deleteCandidate: Attachment?
    @State private var importMessage: String?
    @FocusState private var gridFocused: Bool

    init(session: WorkSession) {
        self.session = session
    }

    var body: some View {
        let attachments = session.sortedAttachments.filter { !$0.isDeleted }
        VStack(alignment: .leading, spacing: theme.spacingS) {
            SectionHeader("Images", systemImage: "photo") {
                HStack(spacing: theme.spacingS) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Adding images")
                    }
                    if !attachments.isEmpty {
                        Text("\(attachments.count)")
                            .monospacedDigit()
                            .accessibilityLabel("\(attachments.count) images")
                    }
                    Button(action: pasteImages) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .accessibilityLabel("Paste image")
                    .help("Paste image from the clipboard")
                    Button(action: chooseImages) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .accessibilityLabel("Attach images")
                    .help("Attach images…")
                }
            }

            if let importMessage {
                InlineBanner(importMessage, style: .warning, onDismiss: { self.importMessage = nil })
            }

            dropZone(attachments)
        }
        .sheet(item: $viewerSelection) { selection in
            // The viewer confirms deletion itself (a dialog on this view would be dropped while the sheet
            // is dismissing) and moves to a neighbouring image before asking us to delete.
            DetailImageViewer(attachments: attachments,
                              initialID: selection.attachmentID,
                              onDelete: { attachment in
                                  Task { @MainActor in
                                      await Task.yield()
                                      delete(attachment)
                                  }
                              })
                .environment(\.theme, theme)
                .tint(theme.accent)
        }
        .confirmationDialog("Delete this image?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteCandidate) { attachment in
            Button("Delete Image", role: .destructive) { delete(attachment) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    // MARK: - Grid / drop zone

    private func dropZone(_ attachments: [Attachment]) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        return Group {
            if attachments.isEmpty {
                VStack(spacing: theme.spacingS) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(theme.titleFont)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                    Text("Drop images here, paste, or use ＋.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: theme.spacingM)],
                          alignment: .leading,
                          spacing: theme.spacingM) {
                    ForEach(attachments, id: \.uuid) { attachment in
                        DetailAttachmentCell(
                            attachment: attachment,
                            onOpen: { viewerSelection = DetailImageSelection(attachmentID: attachment.uuid) },
                            onDelete: { deleteCandidate = attachment }
                        )
                    }
                }
                .padding(theme.spacingXS)
            }
        }
        .background {
            if isDropTargeted {
                shape.fill(theme.accent.opacity(0.06))
            }
        }
        .overlay {
            if isDropTargeted {
                shape.strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else if attachments.isEmpty {
                shape.strokeBorder(theme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            } else if gridFocused {
                shape.strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .contentShape(shape)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onPasteCommand(of: [.image, .fileURL]) { _ in pasteImages() }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDropTargeted)
        .contextMenu {
            Button("Attach Images…", action: chooseImages)
            Button("Paste Image", action: pasteImages)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Images. Drop or paste images here.")
    }

    // MARK: - Import

    private var context: ModelContext { session.modelContext ?? environmentContext }

    private var isAlive: Bool { !session.isDeleted && session.modelContext != nil }

    private func chooseImages() {
        guard isAlive else { return }
        importMessage = nil
        AttachmentImporter.addFromOpenPanel(to: session, in: context)
    }

    private func pasteImages() {
        let images = AttachmentImporter.imagesFromPasteboard()
        guard !images.isEmpty else {
            importMessage = "The clipboard doesn’t contain an image."
            return
        }
        add(images)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        isImporting = true
        Task { @MainActor in
            let images = await AttachmentImporter.loadImages(from: providers)
            isImporting = false
            if images.isEmpty {
                importMessage = "Only images can be attached."
            } else {
                add(images)
            }
        }
        return true
    }

    private func add(_ images: [ImportedImage]) {
        guard isAlive else { return }
        let added = AttachmentImporter.add(images, to: session, in: context)
        let failed = images.count - added.count
        if failed > 0 {
            importMessage = failed == 1
                ? "One image couldn’t be read."
                : "\(failed) images couldn’t be read."
        } else {
            importMessage = nil
        }
    }

    private func delete(_ attachment: Attachment) {
        deleteCandidate = nil
        guard !attachment.isDeleted else { return }
        SessionEditor.deleteAttachment(attachment, in: context)
    }
}

/// Identifies the image open in the viewer sheet.
struct DetailImageSelection: Identifiable {
    let attachmentID: UUID
    var id: UUID { attachmentID }
}

// MARK: - Cell

@MainActor
private struct DetailAttachmentCell: View {
    @Environment(\.theme) private var theme
    @Bindable private var attachment: Attachment
    private let onOpen: () -> Void
    private let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @FocusState private var captionFocused: Bool

    init(attachment: Attachment, onOpen: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self._attachment = Bindable(wrappedValue: attachment)
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    var body: some View {
        if attachment.isDeleted || attachment.modelContext == nil {
            EmptyView()
        } else {
            cell
        }
    }

    private var cell: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        let name = attachment.caption.nilIfBlank ?? attachment.filename.nilIfBlank ?? "Image"
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            Button(action: onOpen) {
                shape
                    .fill(theme.insetSurface)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(theme.titleFont)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(isHovering ? theme.accent.opacity(0.6) : theme.separator, lineWidth: 1)
                    }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("View larger")
            .accessibilityLabel("Image: \(name)")
            .accessibilityHint("Opens the image viewer")

            TextField("Caption", text: $attachment.caption, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1...3)
                .focused($captionFocused)
                .onSubmit { commitCaption() }
                .accessibilityLabel("Caption for \(attachment.filename)")
        }
        .contextMenu {
            Button("View", action: onOpen)
            Button("Save to Disk…") { AttachmentImporter.saveToDisk(attachment) }
            Divider()
            Button("Delete Image…", role: .destructive, action: onDelete)
        }
        .accessibilityAction(named: "Save to disk") { AttachmentImporter.saveToDisk(attachment) }
        .accessibilityAction(named: "Delete") { onDelete() }
        .task(id: attachment.uuid) {
            thumbnail = attachment.thumbnailImage
        }
        .onChange(of: attachment.caption) { _, _ in
            guard !attachment.isDeleted else { return }
            attachment.session?.touch()
        }
        .onChange(of: captionFocused) { _, focused in
            if !focused { commitCaption() }
        }
    }

    private func commitCaption() {
        guard !attachment.isDeleted, let context = attachment.modelContext else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("Caption save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Viewer

/// Quick Look–style sheet: the full image (loaded from `data` only here), caption, file info,
/// previous/next (← / →), Save to Disk…, Delete…, Done (Esc / Return).
@MainActor
private struct DetailImageViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let attachments: [Attachment]
    private let onDelete: (Attachment) -> Void

    @State private var currentID: UUID
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var deleteCandidate: Attachment?

    init(attachments: [Attachment], initialID: UUID, onDelete: @escaping (Attachment) -> Void) {
        self.attachments = attachments
        self.onDelete = onDelete
        self._currentID = State(initialValue: initialID)
    }

    private var live: [Attachment] { attachments.filter { !$0.isDeleted } }

    var body: some View {
        let items = live
        let index = items.firstIndex { $0.uuid == currentID }
        let current = index.map { items[$0] }

        VStack(alignment: .leading, spacing: theme.spacingM) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.caption.nilIfBlank ?? current?.filename.nilIfBlank ?? "Image")
                        .font(theme.headlineFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    if let current {
                        Text(info(for: current))
                            .font(theme.captionFont.monospacedDigit())
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: theme.spacingM)
                if items.count > 1, let index {
                    Text("\(index + 1) of \(items.count)")
                        .font(theme.captionFont.monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                    Button {
                        step(-1, in: items)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                    .accessibilityLabel("Previous image")
                    .help("Previous image (←)")
                    Button {
                        step(1, in: items)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index == items.count - 1)
                    .accessibilityLabel("Next image")
                    .help("Next image (→)")
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
                    .fill(theme.insetSurface)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(current?.caption.nilIfBlank ?? "Image")
                } else if isLoading {
                    ProgressView()
                } else {
                    Text("This image isn’t available on this Mac yet.")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)

            HStack(spacing: theme.spacingS) {
                if let current {
                    Button("Delete…") { deleteCandidate = current }
                        .buttonStyle(DestructiveButtonStyle())
                    Button("Save to Disk…") { AttachmentImporter.saveToDisk(current) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(current.data == nil)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.spacingL)
        .frame(minWidth: 560, idealWidth: 820, minHeight: 440, idealHeight: 640)
        .onExitCommand { dismiss() }
        .task(id: currentID) {
            await loadImage(for: current)
        }
        .onChange(of: items.isEmpty) { _, empty in
            if empty { dismiss() }
        }
        .confirmationDialog("Delete this image?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteCandidate) { attachment in
            Button("Delete Image", role: .destructive) { confirmDelete(attachment) }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    /// Shows the next image (or the previous one at the end) first, then deletes; closes when none is left.
    private func confirmDelete(_ attachment: Attachment) {
        deleteCandidate = nil
        guard !attachment.isDeleted else { return }
        let items = live
        let remaining = items.filter { $0.uuid != attachment.uuid }
        if let index = items.firstIndex(where: { $0.uuid == attachment.uuid }), !remaining.isEmpty {
            currentID = remaining[min(index, remaining.count - 1)].uuid
        }
        onDelete(attachment)
        if remaining.isEmpty { dismiss() }
    }

    private func step(_ offset: Int, in items: [Attachment]) {
        guard let index = items.firstIndex(where: { $0.uuid == currentID }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        currentID = items[target].uuid
    }

    private func info(for attachment: Attachment) -> String {
        var parts: [String] = []
        if attachment.pixelWidth > 0 && attachment.pixelHeight > 0 {
            parts.append("\(attachment.pixelWidth) × \(attachment.pixelHeight)")
        }
        parts.append(attachment.fileExtension.uppercased())
        parts.append(attachment.createdAt.shortDateTime)
        return parts.joined(separator: " · ")
    }

    /// Loads the full-size image (only the viewer reads `data`; grids use thumbnails).
    @MainActor
    private func loadImage(for attachment: Attachment?) async {
        image = nil
        guard let attachment, !attachment.isDeleted else {
            isLoading = false
            return
        }
        isLoading = true
        // Let the sheet appear before decoding a large image.
        await Task.yield()
        if Task.isCancelled { return }
        image = attachment.image ?? attachment.thumbnailImage
        isLoading = false
    }
}
