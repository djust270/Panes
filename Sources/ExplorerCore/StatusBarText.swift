import Foundation

/// Builds the status bar's "N items | M items selected 1.2 MB" text.
public enum StatusBarText {
    /// - Parameter selectedSizeBytes: the summed size of selected files, or `nil` when every
    ///   selected item is a directory (sizes aren't meaningful to add together in that case).
    public static func make(totalCount: Int, selectedCount: Int, selectedSizeBytes: Int64?) -> String {
        let itemsText = totalCount == 1 ? "1 item" : "\(totalCount) items"
        guard selectedCount > 0 else { return itemsText }

        let selectedText = selectedCount == 1 ? "1 item selected" : "\(selectedCount) items selected"
        guard let selectedSizeBytes else { return "\(itemsText) | \(selectedText)" }
        return "\(itemsText) | \(selectedText) \(FileSizeFormat.string(for: selectedSizeBytes))"
    }
}
