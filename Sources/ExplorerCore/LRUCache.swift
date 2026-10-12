import Foundation

/// A least-recently-used cache bounded by entry count and total cost (e.g. bytes of pixel
/// data). A reference type (its nodes are shared); not thread-safe, so confine each instance
/// to one actor.
public final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var newer: Node?
        weak var older: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    public let countLimit: Int
    public let costLimit: Int
    public private(set) var totalCost = 0

    private var nodes: [Key: Node] = [:]
    /// Least recently used; strong references run oldest → newest.
    private var oldest: Node?
    private weak var newest: Node?

    public init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit)
        self.costLimit = costLimit
    }

    public var count: Int { nodes.count }

    /// Returns the value and marks it most recently used.
    public func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToNewest(node)
        return node.value
    }

    public func contains(_ key: Key) -> Bool {
        nodes[key] != nil
    }

    public func setValue(_ value: Value, forKey key: Key, cost: Int = 0) {
        if let node = nodes[key] {
            totalCost += cost - node.cost
            node.value = value
            node.cost = cost
            moveToNewest(node)
        } else {
            let node = Node(key: key, value: value, cost: cost)
            nodes[key] = node
            totalCost += cost
            append(node)
        }
        evict()
    }

    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        unlink(node)
        totalCost -= node.cost
        return node.value
    }

    public func removeAll() {
        nodes.removeAll()
        oldest = nil
        newest = nil
        totalCost = 0
    }

    /// Keys from least to most recently used.
    public var keys: [Key] {
        var result: [Key] = []
        var node = oldest
        while let current = node {
            result.append(current.key)
            node = current.newer
        }
        return result
    }

    private func evict() {
        // Keep at least the newest entry, even if it alone exceeds the cost limit.
        while let victim = oldest, nodes.count > 1, nodes.count > countLimit || totalCost > costLimit {
            removeValue(forKey: victim.key)
        }
    }

    private func moveToNewest(_ node: Node) {
        guard node !== newest else { return }
        unlink(node)
        append(node)
    }

    private func append(_ node: Node) {
        node.older = newest
        node.newer = nil
        if let newest {
            newest.newer = node
        } else {
            oldest = node
        }
        newest = node
    }

    private func unlink(_ node: Node) {
        let older = node.older
        let newer = node.newer
        if let older {
            older.newer = newer
        } else {
            oldest = newer
        }
        if let newer {
            newer.older = older
        } else {
            newest = older
        }
        node.older = nil
        node.newer = nil
    }
}
