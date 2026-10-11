import Foundation
import Testing
@testable import ExplorerCore

@Suite struct NavigationHistoryTests {
    let a = ExplorerLocation.folder(path: "/a")
    let b = ExplorerLocation.folder(path: "/b")
    let c = ExplorerLocation.folder(path: "/c")
    let d = ExplorerLocation.folder(path: "/d")

    @Test func startsWithEmptyStacks() {
        let history = NavigationHistory(start: a)
        #expect(history.current == a)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func navigateBackAndForward() {
        var history = NavigationHistory(start: a)
        history.navigate(to: b)
        history.navigate(to: c)

        #expect(history.backList == [b, a])
        #expect(history.goBack() == b)
        #expect(history.goBack() == a)
        #expect(history.goBack() == nil)
        #expect(history.current == a)

        #expect(history.forwardList == [b, c])
        #expect(history.goForward() == b)
        #expect(history.current == b)
    }

    @Test func navigatingClearsForwardStack() {
        var history = NavigationHistory(start: a)
        history.navigate(to: b)
        history.goBack()
        history.navigate(to: c)
        #expect(!history.canGoForward)
        #expect(history.backList == [a])
    }

    @Test func navigatingToCurrentIsNoOp() {
        var history = NavigationHistory(start: a)
        history.navigate(to: a)
        #expect(!history.canGoBack)
    }

    @Test func multiStepJumpsFromDropdown() {
        var history = NavigationHistory(start: a)
        history.navigate(to: b)
        history.navigate(to: c)
        history.navigate(to: d)

        #expect(history.goBack(steps: 3) == a)
        #expect(history.forwardList == [b, c, d])
        #expect(history.goForward(steps: 2) == c)
        #expect(history.backList == [b, a])
        #expect(history.forwardList == [d])
        #expect(history.goForward(steps: 5) == nil)
        #expect(history.current == c)
    }

    @Test func backStackRespectsLimit() {
        var history = NavigationHistory(start: a, limit: 2)
        history.navigate(to: b)
        history.navigate(to: c)
        history.navigate(to: d)
        #expect(history.backList == [c, b])
    }
}
