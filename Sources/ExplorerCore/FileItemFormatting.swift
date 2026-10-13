import Foundation
import UniformTypeIdentifiers

extension FileItem {
    /// The Details view's "Type" column, e.g. "Folder", "JPEG Image", "TXT File".
    public var typeDescription: String {
        if let volume { return volume.typeDescription }
        if isFolder { return "Folder" }
        if let typeIdentifier, let type = UTType(typeIdentifier), let description = type.localizedDescription {
            // Some system descriptions are lowercase ("text", "folder"); Windows capitalises.
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        guard !pathExtension.isEmpty else { return "Document" }
        return "\(pathExtension.uppercased()) File"
    }
}
