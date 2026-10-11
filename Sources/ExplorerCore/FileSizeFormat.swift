import Foundation

/// Formats byte counts the way Explorer does, e.g. "1.2 MB". Shared by the Details view's
/// Size column and the status bar's selected-size clause.
public enum FileSizeFormat {
    public static func string(for bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
