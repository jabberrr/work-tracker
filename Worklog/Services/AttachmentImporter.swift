import AppKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

struct ImportedImage: Sendable { let data: Data; let filename: String }

/// A downscaled, encoded image ready to become an `Attachment` (made off the main thread; the model object is
/// created on the main actor).
struct PreparedImage: Sendable {
    let filename: String
    let data: Data
    let thumbnailData: Data
    let uti: String
    let pixelWidth: Int
    let pixelHeight: Int
}

enum AttachmentImportError: LocalizedError {
    case unreadableImage, encodingFailed, fileTooLarge, imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "The image couldn't be read."
        case .encodingFailed: "The image couldn't be converted for storage."
        case .fileTooLarge: "The file is larger than 100 MB."
        case .imageTooLarge: "The image has more than 150 megapixels."
        }
    }
}

/// Turns image files / pasteboard / drops into downscaled, compressed `Attachment`s.
@MainActor enum AttachmentImporter {
    nonisolated static let maxPixelDimension: Int = 2048
    nonisolated static let thumbnailPixelDimension: Int = 400
    nonisolated static let jpegQuality: Double = 0.8
    /// Files/data larger than this are rejected before decoding.
    nonisolated static let maxSourceBytes: Int = 100 * 1024 * 1024
    /// Images with more pixels than this are rejected before thumbnailing (decompression-bomb guard).
    nonisolated static let maxSourcePixels: Int = 150_000_000
    /// Archive import: largest accepted stored image (stored images are ≤ 2048 px, so this is generous).
    nonisolated static let maxStoredImageBytes: Int = 40 * 1024 * 1024

    /// Uses ImageIO: CGImageSourceCreateThumbnailAtIndex(kCGImageSourceThumbnailMaxPixelSize, CreateThumbnailWithTransform,
    /// CreateThumbnailFromImageAlways). Output: PNG if source has alpha, else JPEG(0.8). Fills pixel size, thumbnail, uti.
    /// Returned Attachment is NOT inserted. Metadata (EXIF/GPS) is not carried over.
    static func makeAttachment(fromImageData data: Data, filename: String) throws -> Attachment {
        makeAttachment(try prepare(imageData: data, filename: filename))
    }

    static func makeAttachment(fromFileAt url: URL) throws -> Attachment {
        makeAttachment(try prepare(fileAt: url))
    }

    /// The (not inserted) Attachment for an image prepared by `prepare(…)`.
    static func makeAttachment(_ image: PreparedImage) -> Attachment {
        Attachment(filename: image.filename, data: image.data, thumbnailData: image.thumbnailData, uti: image.uti,
                   pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
    }

    /// Downscale + encode (see `makeAttachment(fromImageData:filename:)`); safe off the main thread.
    nonisolated static func prepare(imageData data: Data, filename: String) throws -> PreparedImage {
        guard data.count <= maxSourceBytes else { throw AttachmentImportError.fileTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AttachmentImportError.unreadableImage
        }
        return try prepare(from: source, filename: filename)
    }

    /// Same for a file (security-scoped access is started and stopped here); safe off the main thread.
    nonisolated static func prepare(fileAt url: URL) throws -> PreparedImage {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard isWithinSizeLimit(url) else { throw AttachmentImportError.fileTooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AttachmentImportError.unreadableImage
        }
        return try prepare(from: source, filename: url.lastPathComponent)
    }

    /// True when the file's size is known and ≤ `maxSourceBytes` (unknown sizes are rejected).
    nonisolated static func isWithinSizeLimit(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return size <= maxSourceBytes
    }

    /// Archive import guard: the stored bytes must be a JPEG, PNG or HEIC image of sane size. Returns false otherwise
    /// (the attachment is then dropped).
    nonisolated static func isAcceptableStoredImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxStoredImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { return false }
        let allowed = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier]
        guard allowed.contains(type) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return width > 0 && height > 0 && width.multipliedReportingOverflow(by: height).partialValue <= maxSourcePixels
    }

    nonisolated private static func prepare(from source: CGImageSource, filename: String) throws -> PreparedImage {
        guard CGImageSourceGetCount(source) > 0 else { throw AttachmentImportError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard sourceWidth > 0, sourceHeight > 0 else { throw AttachmentImportError.unreadableImage }
        let pixels = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        guard !pixels.overflow, pixels.partialValue <= maxSourcePixels else { throw AttachmentImportError.imageTooLarge }
        let longestSide = max(sourceWidth, sourceHeight)
        // Never upscale: cap at the source's own longest side when it is known.
        let targetMax = longestSide > 0 ? min(maxPixelDimension, longestSide) : maxPixelDimension

        guard let image = thumbnail(of: source, maxPixelSize: targetMax) else {
            throw AttachmentImportError.unreadableImage
        }
        let declaredAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue
        let hasAlpha = declaredAlpha ?? imageHasAlpha(image)

        let fullData = try encode(image, asPNG: hasAlpha)
        let thumbMax = min(thumbnailPixelDimension, max(image.width, image.height))
        let thumbImage = thumbnail(of: source, maxPixelSize: thumbMax) ?? image
        let thumbData = try encode(thumbImage, asPNG: hasAlpha)

        let uti = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
        return PreparedImage(filename: normalizedFilename(filename, png: hasAlpha), data: fullData,
                             thumbnailData: thumbData, uti: uti, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// NSOpenPanel (images, multiple selection).
    static func chooseImageFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach Images"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Reads image data/file URLs from the pasteboard (for ⌘V / .onPasteCommand).
    static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ImportedImage] {
        // 1. Image files copied in Finder.
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            let images = urls.compactMap { url -> ImportedImage? in
                guard isWithinSizeLimit(url) else {
                    Log.ui.error("Skipping pasted file \(url.lastPathComponent, privacy: .private): too large")
                    return nil
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return ImportedImage(data: data, filename: url.lastPathComponent)
            }
            if !images.isEmpty { return images }
        }

        // 2. Raw image data (screenshots, images copied from apps/browsers).
        let preferredTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier),
            .tiff,
        ]
        var results: [ImportedImage] = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in preferredTypes {
                if let data = item.data(forType: type) {
                    let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
                    results.append(ImportedImage(data: data, filename: "Pasted Image.\(ext)"))
                    break
                }
            }
        }
        if !results.isEmpty { return results }

        // 3. Anything NSImage can read.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            results = images.compactMap { image in
                image.tiffRepresentation.map { ImportedImage(data: $0, filename: "Pasted Image.tiff") }
            }
        }
        return results
    }

    /// For .onDrop(of: [.image, .fileURL]) providers; runs off-main, returns raw data.
    nonisolated static func loadImages(from providers: [NSItemProvider]) async -> [ImportedImage] {
        var results: [ImportedImage] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadFileURL(from: provider) {
                let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? true
                if isImage, isWithinSizeLimit(url), let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    results.append(ImportedImage(data: data, filename: url.lastPathComponent))
                    continue
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await loadData(from: provider, typeIdentifier: UTType.image.identifier),
               data.count <= maxSourceBytes {
                let name = provider.suggestedName?.nilIfBlank ?? "Dropped Image"
                results.append(ImportedImage(data: data, filename: name))
            }
        }
        return results
    }

    /// make + insert + link to session + touch + save, synchronously on the main thread. Skips failures, sets no
    /// error UI (returns successes). UI drops and pastes use `addInBackground(_:to:in:)` instead.
    @discardableResult
    static func add(_ images: [ImportedImage], to session: WorkSession, in context: ModelContext) -> [Attachment] {
        var created: [Attachment] = []
        for image in images {
            do {
                let attachment = try makeAttachment(fromImageData: image.data, filename: image.filename)
                insert(attachment, into: session, context: context)
                created.append(attachment)
            } catch {
                Log.ui.error("Skipping image \(image.filename, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        finish(session, created: created, context: context)
        return created
    }

    /// Drop / paste: the images are downscaled and encoded off the main thread; the attachments are inserted, linked
    /// and saved back on the main actor — only if `session` still exists by then (it may have been discarded or
    /// deleted meanwhile). Failures are skipped and logged. Returns the created attachments.
    /// (Named apart from the synchronous `add(_:to:in:)` so an `await` call can't resolve to the wrong one.)
    @discardableResult
    static func addInBackground(_ images: [ImportedImage], to session: WorkSession,
                                in context: ModelContext) async -> [Attachment] {
        guard !images.isEmpty else { return [] }
        let prepared = await Task.detached(priority: .userInitiated) {
            AttachmentImporter.prepareImages(images)
        }.value
        return insertPrepared(prepared, into: session, context: context)
    }

    /// Open panel (modal), then the images are downscaled and encoded off the main thread; the attachments are
    /// inserted, linked and saved back on the main actor — only if `session` still exists by then (it may have been
    /// discarded or deleted meanwhile). Failures are skipped and logged. Returns the created attachments.
    @discardableResult
    static func addFromOpenPanel(to session: WorkSession, in context: ModelContext) async -> [Attachment] {
        let urls = chooseImageFiles()
        guard !urls.isEmpty else { return [] }
        let prepared = await Task.detached(priority: .userInitiated) {
            AttachmentImporter.prepareFiles(urls)
        }.value
        return insertPrepared(prepared, into: session, context: context)
    }

    /// `prepare(imageData:filename:)` for each image, skipping (and logging) failures. Runs off the main thread.
    nonisolated static func prepareImages(_ images: [ImportedImage]) -> [PreparedImage] {
        var prepared: [PreparedImage] = []
        for image in images {
            do {
                prepared.append(try prepare(imageData: image.data, filename: image.filename))
            } catch {
                Log.ui.error("Skipping image \(image.filename, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        return prepared
    }

    /// `prepare(fileAt:)` for each URL, skipping (and logging) failures. Runs off the main thread.
    nonisolated static func prepareFiles(_ urls: [URL]) -> [PreparedImage] {
        var prepared: [PreparedImage] = []
        for url in urls {
            do {
                prepared.append(try prepare(fileAt: url))
            } catch {
                Log.ui.error("Skipping file \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        return prepared
    }

    /// NSSavePanel; writes `data`.
    static func saveToDisk(_ attachment: Attachment) {
        guard let data = attachment.data else { return }
        let panel = NSSavePanel()
        panel.title = "Save Image"
        let base = (attachment.filename as NSString).deletingPathExtension.nilIfBlank ?? "Image"
        panel.nameFieldStringValue = "\(base).\(attachment.fileExtension)"
        if let type = UTType(attachment.uti) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.ui.error("Saving image failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Private

    /// Back on the main actor after preparing: insert + link + save, unless the session is gone by now.
    private static func insertPrepared(_ prepared: [PreparedImage], into session: WorkSession,
                                       context: ModelContext) -> [Attachment] {
        guard !prepared.isEmpty, ModelLiveness.isLive(session) else { return [] }
        var created: [Attachment] = []
        for image in prepared {
            let attachment = makeAttachment(image)
            insert(attachment, into: session, context: context)
            created.append(attachment)
        }
        finish(session, created: created, context: context)
        return created
    }

    private static func insert(_ attachment: Attachment, into session: WorkSession, context: ModelContext) {
        context.insert(attachment)
        attachment.createdAt = .now
        attachment.session = session
    }

    private static func finish(_ session: WorkSession, created: [Attachment], context: ModelContext) {
        guard !created.isEmpty else { return }
        ProfileOps.assignProfileIfUnassigned(session, in: context)
        session.touch()
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving attachments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    nonisolated private static func encode(_ image: CGImage, asPNG: Bool) throws -> Data {
        let output = NSMutableData()
        let type = (asPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else {
            throw AttachmentImportError.encodingFailed
        }
        let properties: [CFString: Any] = asPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentImportError.encodingFailed }
        return output as Data
    }

    nonisolated private static func normalizedFilename(_ filename: String, png: Bool) -> String {
        let base = (filename as NSString).deletingPathExtension.trimmed
        let stem = base.isEmpty ? "Image" : base
        return "\(stem).\(png ? "png" : "jpg")"
    }

    nonisolated private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let string = item as? String {
                    continuation.resume(returning: URL(string: string))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
