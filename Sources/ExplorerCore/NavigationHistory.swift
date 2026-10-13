import Foundation

/// Back/forward history for one Explorer tab.
///
/// Behaves like a browser: navigating somewhere new clears the forward stack, and
/// navigating to the current location is a no-op.
public struct NavigationHistory: Sendable, Equatable {
    public private(set) var current: ExplorerLocation
    /// Most recent last.
    public private(set) var backStack: [ExplorerLocation] = []
    /// Next location last.
    public private(set) var forwardStack: [ExplorerLocation] = []
    public let limit: Int

    public init(start: ExplorerLocation, limit: Int = 100) {
        precondition(limit > 0, "History limit must be positive")
        self.current = start
        self.limit = limit
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Entries for the Back button's dropdown, most recent first.
    public var backList: [ExplorerLocation] { backStack.reversed() }
    /// Entries for the Forward button's dropdown, nearest first.
    public var forwardList: [ExplorerLocation] { forwardStack.reversed() }

    public mutating func navigate(to location: ExplorerLocation) {
        guard location != current else { return }
        backStack.append(current)
        if backStack.count > limit {
            backStack.removeFirst(backStack.count - limit)
        }
        forwardStack.removeAll()
        current = location
    }

    /// Swaps the current entry for `location` without adding to the history, e.g. as a
    /// search is refined while typing.
    public mutating func replaceCurrent(with location: ExplorerLocation) {
        current = location
    }

    /// Goes back `steps` entries (1 = the Back button; >1 = picking from the dropdown).
    @discardableResult
    public mutating func goBack(steps: Int = 1) -> ExplorerLocation? {
        guard steps > 0, steps <= backStack.count else { return nil }
        for _ in 0..<steps {
            forwardStack.append(current)
            current = backStack.removeLast()
        }
        return current
    }

    /// Goes forward `steps` entries.
    @discardableResult
    public mutating func goForward(steps: Int = 1) -> ExplorerLocation? {
        guard steps > 0, steps <= forwardStack.count else { return nil }
        for _ in 0..<steps {
            backStack.append(current)
            current = forwardStack.removeLast()
        }
        return current
    }
}
