import Foundation
import os
import UniformTypeIdentifiers

extension FileItem {
    /// The Details view's "Type" column, e.g. "Folder", "JPEG Image", "TXT File".
    public var typeDescription: String {
        if let volume { return volume.typeDescription }
        if isFolder { return "Folder" }
        if let typeIdentifier, let description = Self.typeDescription(for: typeIdentifier) {
            return description
        }
        guard !pathExtension.isEmpty else { return "Document" }
        return "\(pathExtension.uppercased()) File"
    }

    /// Localized type names by identifier. Looking one up goes through LaunchServices (tens
    /// of microseconds), and a folder has few distinct types, so they're remembered.
    private static let typeDescriptions = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    private static func typeDescription(for identifier: String) -> String? {
        if let cached = typeDescriptions.withLock({ $0[identifier] }) { return cached }
        // Some system descriptions are lowercase ("text", "folder"); Windows capitalises.
        let description = UTType(identifier)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        typeDescriptions.withLock { $0[identifier] = description }
        return description
    }
}
