import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Details beyond what a directory listing returns, read per file on demand: only when a
/// column, sort or group needs them, or for the Details pane.
public struct FileProperties: Sendable, Hashable {
    /// Finder tags, e.g. "Red", "Work".
    public var tags: [String]
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Audio/video length in seconds.
    public var duration: TimeInterval?

    public init(tags: [String] = [], pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: TimeInterval? = nil) {
        self.tags = tags
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }

    /// The Dimensions column, e.g. "1920 x 1080", as Windows writes it.
    public var dimensionsText: String {
        guard let pixelWidth, let pixelHeight else { return "" }
        return "\(pixelWidth) x \(pixelHeight)"
    }

    /// Pixel count, for sorting by Dimensions.
    public var pixelCount: Int? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return pixelWidth * pixelHeight
    }

    /// The Duration column, e.g. "00:03:25" (hours:minutes:seconds, as on Windows).
    public var durationText: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "" }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// The Tags column, e.g. "Red; Work".
    public var tagsText: String { tags.joined(separator: "; ") }
}

public enum FilePropertiesReader {
    /// Reads tags from the file system and dimensions/duration from Spotlight, falling back to
    /// the image header for pictures on volumes Spotlight doesn't index — unless the picture is
    /// online-only, as reading it would download it.
    public static func read(_ item: FileItem) -> FileProperties {
        var properties = FileProperties()
        let values = try? item.url.resourceValues(forKeys: [.tagNamesKey])
        properties.tags = values?.tagNames ?? []
        guard item.kind == .file else { return properties }

        if let metadata = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL) {
            properties.pixelWidth = intValue(metadata, kMDItemPixelWidth)
            properties.pixelHeight = intValue(metadata, kMDItemPixelHeight)
            properties.duration = (MDItemCopyAttribute(metadata, kMDItemDurationSeconds) as? NSNumber)?.doubleValue
        }
        if properties.pixelWidth == nil, !item.isOnlineOnly, isImage(item) {
            readImageHeader(item.url, into: &properties)
        }
        return properties
    }

    private static func intValue(_ item: MDItem, _ key: CFString) -> Int? {
        (MDItemCopyAttribute(item, key) as? NSNumber)?.intValue
    }

    private static func isImage(_ item: FileItem) -> Bool {
        guard let identifier = item.typeIdentifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    private static func readImageHeader(_ url: URL, into properties: inout FileProperties) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let header = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return }
        properties.pixelWidth = (header[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        properties.pixelHeight = (header[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    }
}
