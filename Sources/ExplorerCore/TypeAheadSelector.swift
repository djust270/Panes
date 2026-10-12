import Foundation

/// Windows' type-ahead selection: typing the start of a name selects the first matching item.
/// Keys typed within `timeout` of each other build up a prefix; typing the same letter
/// repeatedly cycles through the items that start with it.
public struct TypeAheadSelector: Sendable {
    public var timeout: TimeInterval

    private var buffer = ""
    private var lastKeyTime: Date?

    public init(timeout: TimeInterval = 1.0) {
        self.timeout = timeout
    }

    /// The prefix typed so far, if still within the timeout of `now`.
    public func currentPrefix(at now: Date) -> String? {
        guard let lastKeyTime, now.timeIntervalSince(lastKeyTime) <= timeout else { return nil }
        return buffer
    }

    /// Adds `text` to the prefix and returns the index in `names` to select, or `nil` for no
    /// match. `current` is the selected index (the focused item), if any.
    public mutating func type(_ text: String, at now: Date, names: [String], current: Int?) -> Int? {
        guard !text.isEmpty else { return nil }
        buffer = (currentPrefix(at: now) ?? "") + text
        lastKeyTime = now
        guard !names.isEmpty else { return nil }

        let start = current.map { min(max($0, 0), names.count - 1) }
        // "a", "aa", "aaa"…: step to the next name starting with "a".
        if let first = buffer.first, buffer.allSatisfy({ $0 == first }) {
            let from = start.map { $0 + 1 } ?? 0
            return Self.firstMatch(prefix: String(first), in: names, from: from)
        }
        // A longer prefix keeps the current item while it still matches.
        return Self.firstMatch(prefix: buffer, in: names, from: start ?? 0)
    }

    public mutating func reset() {
        buffer = ""
        lastKeyTime = nil
    }

    /// The first name at or after `from` (wrapping around) that starts with `prefix`,
    /// ignoring case and diacritics.
    static func firstMatch(prefix: String, in names: [String], from: Int) -> Int? {
        let count = names.count
        for offset in 0..<count {
            let index = (from + offset) % count
            let range = names[index].range(
                of: prefix,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            )
            if range != nil { return index }
        }
        return nil
    }
}
