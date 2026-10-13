import Foundation
import UniformTypeIdentifiers

/// The command bar's Filter menu: show only items of some kinds. An empty set shows everything;
/// several kinds show items matching any of them.
public enum FileKind: String, Sendable, CaseIterable, Codable {
    case folders
    case documents
    case pictures
    case music
    case videos
    case archives
    case applications

    public var title: String {
        switch self {
        case .folders: return "Folders"
        case .documents: return "Documents"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .videos: return "Videos"
        case .archives: return "Compressed files"
        case .applications: return "Applications"
        }
    }

    public func matches(_ item: FileItem) -> Bool {
        if self == .folders { return item.kind == .directory }
        guard item.kind != .directory else { return false }
        guard let type = item.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: item.pathExtension)
        else { return false }
        // Source code is text, but not what Windows calls a document.
        if self == .documents, type.conforms(to: .sourceCode) || type.conforms(to: .script) { return false }
        return Self.types[self, default: []].contains { type.conforms(to: $0) }
    }

    /// Uniform Type Identifiers for a Spotlight `kMDItemContentTypeTree` query.
    public var contentTypeIdentifiers: [String] {
        self == .folders ? [UTType.folder.identifier] : Self.types[self, default: []].map(\.identifier)
    }

    private static let types: [FileKind: [UTType]] = [
        .documents: [
            .text, .pdf, .rtf, .rtfd, .presentation, .spreadsheet, .epub,
            UTType("org.openxmlformats.wordprocessingml.document"),
            UTType("com.microsoft.word.doc"),
            UTType("com.apple.iwork.pages.sffpages"),
            UTType("com.apple.iwork.pages.pages"),
        ].compactMap { $0 },
        .pictures: [.image],
        .music: [.audio],
        .videos: [.movie, .video],
        .archives: [.archive, .diskImage],
        .applications: [.application, .applicationBundle],
    ]
}

public extension Set where Element == FileKind {
    /// Items matching any kind in the set; everything if the set is empty.
    func filter(_ items: [FileItem]) -> [FileItem] {
        isEmpty ? items : items.filter { item in contains { $0.matches(item) } }
    }
}
