import AppKit
import ExplorerCore
import QuickLookThumbnailing

/// Content thumbnails for the larger view modes, generated asynchronously by Quick Look and
/// kept in an LRU cache bounded by pixel memory. Files Quick Look can't thumbnail keep their
/// type icon, and are remembered so they aren't retried.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        /// Requested edge length in points, and the screen scale.
        let size: Int
        let scale: Int
    }

    private let cache = LRUCache<Key, NSImage>(countLimit: 3000, costLimit: 256 * 1024 * 1024)
    private let failures = LRUCache<Key, Bool>(countLimit: 5000)
    private var waiting: [Key: [(NSImage) -> Void]] = [:]

    private init() {}

    /// Whether `item` can have a content thumbnail (folders and packages use their icon).
    static func canThumbnail(_ item: FileItem) -> Bool {
        item.kind == .file
    }

    /// The thumbnail if it's cached; otherwise starts generating it and calls `completion` on
    /// the main actor once it's ready (never, if Quick Look has nothing better than an icon).
    func thumbnail(
        for item: FileItem,
        size: CGFloat,
        scale: CGFloat,
        completion: @escaping (NSImage) -> Void
    ) -> NSImage? {
        guard Self.canThumbnail(item) else { return nil }
        let key = Key(
            url: item.url.standardizedFileURL,
            modified: item.dateModified,
            size: Int(size),
            scale: max(1, Int(scale.rounded()))
        )
        if let image = cache.value(forKey: key) { return image }
        guard !failures.contains(key) else { return nil }

        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return nil
        }
        waiting[key] = [completion]

        let request = QLThumbnailGenerator.Request(
            fileAt: key.url,
            size: CGSize(width: key.size, height: key.size),
            scale: CGFloat(key.scale),
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.cgImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ThumbnailProvider.shared.finish(key, image: image)
                }
            }
        }
        return nil
    }

    private func finish(_ key: Key, image: CGImage?) {
        let callbacks = waiting.removeValue(forKey: key) ?? []
        guard let image else {
            failures.setValue(true, forKey: key)
            return
        }
        let scale = CGFloat(key.scale)
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let nsImage = NSImage(cgImage: image, size: pointSize)
        cache.setValue(nsImage, forKey: key, cost: image.bytesPerRow * image.height)
        callbacks.forEach { $0(nsImage) }
    }
}
