import AppKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

struct ImportedImage: Sendable { let data: Data; let filename: String }

enum AttachmentImportError: LocalizedError {
    case unreadableImage, encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "The image couldn't be read."
        case .encodingFailed: "The image couldn't be converted for storage."
        }
    }
}

/// Turns image files / pasteboard / drops into downscaled, compressed `Attachment`s.
@MainActor enum AttachmentImporter {
    static let maxPixelDimension: Int = 2048
    static let thumbnailPixelDimension: Int = 400
    static let jpegQuality: Double = 0.8

    /// Uses ImageIO: CGImageSourceCreateThumbnailAtIndex(kCGImageSourceThumbnailMaxPixelSize, CreateThumbnailWithTransform,
    /// CreateThumbnailFromImageAlways). Output: PNG if source has alpha, else JPEG(0.8). Fills pixel size, thumbnail, uti.
    /// Returned Attachment is NOT inserted. Metadata (EXIF/GPS) is not carried over.
    static func makeAttachment(fromImageData data: Data, filename: String) throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw AttachmentImportError.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
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
        let attachment = Attachment(filename: normalizedFilename(filename, png: hasAlpha), data: fullData,
                                    thumbnailData: thumbData, uti: uti,
                                    pixelWidth: image.width, pixelHeight: image.height)
        return attachment
    }

    static func makeAttachment(fromFileAt url: URL) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AttachmentImportError.unreadableImage
        }
        return try makeAttachment(fromImageData: data, filename: url.lastPathComponent)
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
                guard let data = try? Data(contentsOf: url) else { return nil }
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
                if isImage, let data = try? Data(contentsOf: url) {
                    results.append(ImportedImage(data: data, filename: url.lastPathComponent))
                    continue
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await loadData(from: provider, typeIdentifier: UTType.image.identifier) {
                let name = provider.suggestedName?.nilIfBlank ?? "Dropped Image"
                results.append(ImportedImage(data: data, filename: name))
            }
        }
        return results
    }

    /// make + insert + link to session + touch + save. Skips failures, sets no error UI (returns successes).
    @discardableResult
    static func add(_ images: [ImportedImage], to session: WorkSession, in context: ModelContext) -> [Attachment] {
        var created: [Attachment] = []
        for image in images {
            do {
                let attachment = try makeAttachment(fromImageData: image.data, filename: image.filename)
                insert(attachment, into: session, context: context)
                created.append(attachment)
            } catch {
                Log.ui.error("Skipping image \(image.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        finish(session, created: created, context: context)
        return created
    }

    @discardableResult
    static func addFromOpenPanel(to session: WorkSession, in context: ModelContext) -> [Attachment] {
        var created: [Attachment] = []
        for url in chooseImageFiles() {
            do {
                let attachment = try makeAttachment(fromFileAt: url)
                insert(attachment, into: session, context: context)
                created.append(attachment)
            } catch {
                Log.ui.error("Skipping file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        finish(session, created: created, context: context)
        return created
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

    private static func insert(_ attachment: Attachment, into session: WorkSession, context: ModelContext) {
        context.insert(attachment)
        attachment.createdAt = .now
        attachment.session = session
    }

    private static func finish(_ session: WorkSession, created: [Attachment], context: ModelContext) {
        guard !created.isEmpty else { return }
        session.touch()
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving attachments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func encode(_ image: CGImage, asPNG: Bool) throws -> Data {
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

    private static func normalizedFilename(_ filename: String, png: Bool) -> String {
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
