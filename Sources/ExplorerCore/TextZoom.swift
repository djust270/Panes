import Foundation

/// The zoom of the file list and navigation pane (View › Zoom In / Zoom Out / Actual Size):
/// text, rows and the space around them, in steps like a browser's.
public enum TextZoom {
    /// The steps, as a fraction of normal size.
    public static let levels: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public static let actualSize: Double = 1

    /// The next step up from `zoom`, or `nil` at the largest.
    public static func zoomedIn(from zoom: Double) -> Double? {
        levels.first { $0 > zoom + 0.001 }
    }

    /// The next step down from `zoom`, or `nil` at the smallest.
    public static func zoomedOut(from zoom: Double) -> Double? {
        levels.last { $0 < zoom - 0.001 }
    }

    /// `zoom` within the smallest and largest steps (a stored value may be anything).
    public static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return actualSize }
        return min(max(zoom, levels[0]), levels[levels.count - 1])
    }

    /// "125%".
    public static func title(for zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}
