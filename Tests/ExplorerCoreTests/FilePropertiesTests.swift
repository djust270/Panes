import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ExplorerCore

@Suite struct FilePropertiesTests {
    @Test func formatting() {
        let properties = FileProperties(tags: ["Red", "Work"], pixelWidth: 1920, pixelHeight: 1080, duration: 3725.4)
        #expect(properties.tagsText == "Red; Work")
        #expect(properties.dimensionsText == "1920 x 1080")
        #expect(properties.durationText == "01:02:05")
        #expect(FileProperties().dimensionsText.isEmpty)
        #expect(FileProperties().durationText.isEmpty)
    }

    @Test func readsTagsAndImageDimensions() throws {
        let dir = try TemporaryDirectory()
        let url = dir.path("picture.png")
        try writePNG(to: url, width: 7, height: 3)
        try (url as NSURL).setResourceValue(["Work"], forKey: .tagNamesKey)

        let items = try DirectoryLoader.loadSync(dir.url, options: .init())
        let item = try #require(items.first)
        let properties = FilePropertiesReader.read(item)
        #expect(properties.tags == ["Work"])
        #expect(properties.pixelWidth == 7)
        #expect(properties.pixelHeight == 3)
        #expect(properties.duration == nil)
    }

    @Test func sortsByPropertiesWithMissingValuesLast() {
        func file(_ name: String, _ properties: FileProperties?) -> FileItem {
            var item = FileItem(url: URL(fileURLWithPath: "/\(name)"), name: name, kind: .file)
            item.properties = properties
            return item
        }
        let items = [
            file("none", nil),
            file("big", FileProperties(tags: ["B"], pixelWidth: 100, pixelHeight: 100, duration: 5)),
            file("small", FileProperties(tags: ["A"], pixelWidth: 10, pixelHeight: 10, duration: 50)),
        ]
        #expect(FileItemSort(key: .dimensions).sorted(items).map(\.name) == ["small", "big", "none"])
        #expect(FileItemSort(key: .dimensions, ascending: false).sorted(items).map(\.name) == ["big", "small", "none"])
        #expect(FileItemSort(key: .duration).sorted(items).map(\.name) == ["big", "small", "none"])
        #expect(FileItemSort(key: .tags, ascending: false).sorted(items).map(\.name) == ["big", "small", "none"])
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
