import Foundation
import SwiftData
import AppKit

@Model
final class Attachment {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var filename: String = ""
    var caption: String = ""
    /// UTI of `data`: "public.jpeg" or "public.png".
    var uti: String = "public.jpeg"
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    @Attribute(.externalStorage) var data: Data? = nil
    @Attribute(.externalStorage) var thumbnailData: Data? = nil
    var session: WorkSession?

    init(filename: String = "", data: Data? = nil, thumbnailData: Data? = nil,
         uti: String = "public.jpeg", pixelWidth: Int = 0, pixelHeight: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.filename = filename
        self.data = data
        self.thumbnailData = thumbnailData
        self.uti = uti
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

extension Attachment {
    var image: NSImage? { data.flatMap { NSImage(data: $0) } }
    var thumbnailImage: NSImage? { (thumbnailData ?? data).flatMap { NSImage(data: $0) } }
    var fileExtension: String { uti == "public.png" ? "png" : "jpg" }
}
