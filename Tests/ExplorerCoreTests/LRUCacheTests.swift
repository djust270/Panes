import Testing
@testable import ExplorerCore

@Suite struct LRUCacheTests {
    @Test func evictsLeastRecentlyUsedBeyondCountLimit() {
        let cache = LRUCache<String, Int>(countLimit: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        #expect(cache.value(forKey: "a") == 1)  // "a" is now newest
        cache.setValue(3, forKey: "c")
        #expect(!cache.contains("b"))
        #expect(cache.keys == ["a", "c"])
    }

    @Test func evictsByCost() {
        let cache = LRUCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.setValue(1, forKey: "a", cost: 60)
        cache.setValue(2, forKey: "b", cost: 30)
        cache.setValue(3, forKey: "c", cost: 30)
        #expect(cache.keys == ["b", "c"])
        #expect(cache.totalCost == 60)
    }

    @Test func keepsASingleOversizedEntry() {
        let cache = LRUCache<String, Int>(countLimit: 10, costLimit: 10)
        cache.setValue(1, forKey: "big", cost: 50)
        #expect(cache.value(forKey: "big") == 1)
    }

    @Test func replacingUpdatesCostAndRecency() {
        let cache = LRUCache<String, Int>(countLimit: 3, costLimit: 100)
        cache.setValue(1, forKey: "a", cost: 10)
        cache.setValue(2, forKey: "b", cost: 10)
        cache.setValue(9, forKey: "a", cost: 40)
        #expect(cache.keys == ["b", "a"])
        #expect(cache.totalCost == 50)
        #expect(cache.value(forKey: "a") == 9)
    }

    @Test func removal() {
        let cache = LRUCache<String, Int>(countLimit: 3)
        cache.setValue(1, forKey: "a", cost: 5)
        cache.setValue(2, forKey: "b", cost: 5)
        #expect(cache.removeValue(forKey: "a") == 1)
        #expect(cache.keys == ["b"])
        #expect(cache.totalCost == 5)
        cache.removeAll()
        #expect(cache.keys.isEmpty)
        #expect(cache.totalCost == 0)
    }
}
