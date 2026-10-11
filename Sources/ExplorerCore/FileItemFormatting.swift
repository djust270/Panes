import Foundation
import UniformTypeIdentifiers

extension FileItem {
    /// The Details view's "Type" column, e.g. "Folder", "JPEG Image", "TXT File".
    public var typeDescription: String {
        if isFolder { return "Folder" }
        if let typeIdentifier, let type = UTType(typeIdentifier), let description = type.localizedDescription {
            return description
        }
        guard !pathExtension.isEmpty else { return "Document" }
        return "\(pathExtension.uppercased()) File"
    }
}
