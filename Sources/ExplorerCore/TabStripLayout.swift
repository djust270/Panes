import Foundation

/// Geometry and selection rules for the title-bar tab strip. Tabs share the available width
/// equally, between a minimum and a maximum, as in Windows 11 Explorer.
public enum TabStripLayout {
    public static let minimumTabWidth = 72.0
    public static let maximumTabWidth = 240.0

    /// Width of each tab when `count` tabs share `available` points.
    public static func tabWidth(count: Int, available: Double) -> Double {
        guard count > 0 else { return maximumTabWidth }
        let share = (available / Double(count)).rounded(.down)
        return min(maximumTabWidth, max(minimumTabWidth, share))
    }

    /// Where a tab dragged to `x` (measured from the strip's first tab) lands, given equal
    /// widths. `count` includes the dragged tab if it comes from this strip.
    public static func insertionIndex(forX x: Double, tabWidth: Double, count: Int) -> Int {
        guard tabWidth > 0, count > 0 else { return 0 }
        let slot = Int((x / tabWidth).rounded(.down))
        return min(max(slot, 0), count - 1)
    }

    /// The tab to select after closing the tab at `closed` while `selected` was selected,
    /// out of `count` tabs before closing. `nil` if no tabs remain. Closing the selected tab
    /// selects its right neighbour, or the left one if it was last.
    public static func selectionAfterClosing(_ closed: Int, selected: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        if closed < selected { return selected - 1 }
        if closed > selected { return selected }
        return min(closed, count - 2)
    }

    /// The tab index after moving a tab from `from` to `to` (both in the original order),
    /// for an index `index` that was not moved.
    public static func indexAfterMove(_ index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < index, index <= to { return index - 1 }
        if to <= index, index < from { return index + 1 }
        return index
    }
}
