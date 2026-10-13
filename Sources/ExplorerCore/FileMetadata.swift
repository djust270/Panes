import CoreServices
import Foundation

/// One heading of a Properties dialog's Details tab, e.g. "Image", with its rows.
public struct MetadataSection: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let title: String
    public let rows: [Row]

    public init(title: String, rows: [Row]) {
        self.title = title
        self.rows = rows
    }
}

/// The Details tab: Spotlight metadata grouped as Windows does (Description, Origin, Image,
/// Camera, GPS, Media, Audio, Content), with empty values left out.
public enum FileMetadata {
    private enum Format {
        case text
        /// "1920 pixels"
        case suffix(String)
        case date
        case rating
        case duration
        case fNumber
        case exposure
        case bitRate
        case sampleRate
        case yesNo
    }

    private struct Field {
        let key: String
        let name: String
        let format: Format

        init(_ key: String, _ name: String, _ format: Format = .text) {
            self.key = key
            self.name = name
            self.format = format
        }
    }

    private static let layout: [(String, [Field])] = [
        ("Description", [
            Field("kMDItemTitle", "Title"),
            Field("kMDItemDescription", "Subject"),
            Field("kMDItemStarRating", "Rating", .rating),
            Field("kMDItemUserTags", "Tags"),
            Field("kMDItemFinderComment", "Comments"),
        ]),
        ("Origin", [
            Field("kMDItemAuthors", "Authors"),
            Field("kMDItemWhereFroms", "Where from"),
            Field("kMDItemContentCreationDate", "Content created", .date),
            Field("kMDItemDateAdded", "Date acquired", .date),
            Field("kMDItemCreator", "Program name"),
            Field("kMDItemCopyright", "Copyright"),
        ]),
        ("Image", [
            Field("kMDItemPixelWidth", "Width", .suffix(" pixels")),
            Field("kMDItemPixelHeight", "Height", .suffix(" pixels")),
            Field("kMDItemResolutionWidthDPI", "Horizontal resolution", .suffix(" dpi")),
            Field("kMDItemResolutionHeightDPI", "Vertical resolution", .suffix(" dpi")),
            Field("kMDItemBitsPerSample", "Bit depth"),
            Field("kMDItemColorSpace", "Color representation"),
            Field("kMDItemProfileName", "Color profile"),
        ]),
        ("Camera", [
            Field("kMDItemAcquisitionMake", "Camera maker"),
            Field("kMDItemAcquisitionModel", "Camera model"),
            Field("kMDItemLensModel", "Lens model"),
            Field("kMDItemFNumber", "F-stop", .fNumber),
            Field("kMDItemExposureTimeSeconds", "Exposure time", .exposure),
            Field("kMDItemISOSpeed", "ISO speed"),
            Field("kMDItemFocalLength", "Focal length", .suffix(" mm")),
            Field("kMDItemFlashOnOff", "Flash", .yesNo),
        ]),
        ("GPS", [
            Field("kMDItemLatitude", "Latitude"),
            Field("kMDItemLongitude", "Longitude"),
            Field("kMDItemAltitude", "Altitude", .suffix(" m")),
        ]),
        ("Media", [
            Field("kMDItemDurationSeconds", "Length", .duration),
            Field("kMDItemAlbum", "Album"),
            Field("kMDItemComposer", "Composers"),
            Field("kMDItemMusicalGenre", "Genre"),
            Field("kMDItemRecordingYear", "Year"),
            Field("kMDItemAudioTrackNumber", "#"),
            Field("kMDItemCodecs", "Codecs"),
            Field("kMDItemTotalBitRate", "Total bitrate", .bitRate),
        ]),
        ("Audio", [
            Field("kMDItemAudioBitRate", "Bit rate", .bitRate),
            Field("kMDItemAudioSampleRate", "Sample rate", .sampleRate),
            Field("kMDItemAudioChannelCount", "Channels"),
        ]),
        ("Content", [
            Field("kMDItemNumberOfPages", "Pages"),
            Field("kMDItemLanguages", "Language"),
            Field("kMDItemVersion", "Version"),
            Field("kMDItemEncodingApplications", "Encoded by"),
        ]),
    ]

    /// Every key the Details tab reads.
    static var keys: [String] { layout.flatMap { $0.1.map(\.key) } }

    /// Reads `url`'s Spotlight metadata; empty for files Spotlight knows nothing about.
    public static func sections(for url: URL) -> [MetadataSection] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let values = MDItemCopyAttributes(item, keys as CFArray) as? [String: Any] else { return [] }
        return sections(from: values)
    }

    /// The sections for `values` (Spotlight attributes by key name).
    public static func sections(from values: [String: Any], dateFormatter: DateFormatter? = nil) -> [MetadataSection] {
        let formatter = dateFormatter ?? defaultDateFormatter()
        return layout.compactMap { title, fields in
            let rows = fields.compactMap { field -> MetadataSection.Row? in
                guard let value = values[field.key], let text = format(value, as: field.format, dates: formatter),
                      !text.isEmpty else { return nil }
                return MetadataSection.Row(name: field.name, value: text)
            }
            return rows.isEmpty ? nil : MetadataSection(title: title, rows: rows)
        }
    }

    private static func defaultDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func format(_ value: Any, as format: Format, dates: DateFormatter) -> String? {
        if let list = value as? [Any] {
            let parts = list.compactMap { self.format($0, as: format, dates: dates) }.filter { !$0.isEmpty }
            return parts.joined(separator: "; ")
        }
        if let date = value as? Date { return dates.string(from: date) }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        switch format {
        case .text, .date:
            return number.stringValue
        case .suffix(let unit):
            return trimmed(double) + unit
        case .rating:
            let stars = max(0, min(5, number.intValue))
            return String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
        case .duration:
            return FileProperties(duration: double).durationText
        case .fNumber:
            return "f/" + trimmed(double)
        case .exposure:
            guard double > 0 else { return nil }
            return double < 1 ? "1/\(Int((1 / double).rounded())) sec." : trimmed(double) + " sec."
        case .bitRate:
            // Spotlight reports bits per second.
            return "\(Int((double / 1000).rounded()))kbps"
        case .sampleRate:
            return trimmed(double / 1000) + " kHz"
        case .yesNo:
            return number.boolValue ? "Flash" : "No flash"
        }
    }

    /// "72", "2.8", "0.25": no trailing zeros.
    private static func trimmed(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}
