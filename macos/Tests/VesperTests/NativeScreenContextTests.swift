import SwiftUI
import Testing
import VesperCore
@testable import Vesper

/// A tab swaps screens by building a new context; the old screen keeps running until SwiftUI tears it
/// down. These pin that a detached context can no longer reach the tab it left.
@MainActor
@Suite("NativeScreenContext detach")
struct NativeScreenContextTests {
    private final class TabSpy {
        var opened: [(path: String, newTab: Bool)] = []
        var replaced: [String] = []
        var chromeChanges = 0
        var sidebarChanges = 0
        var inspectorChanges = 0
    }

    private func makeContext(_ spy: TabSpy) -> NativeScreenContext {
        let context = NativeScreenContext(
            match: NativeRouteMatch(screen: .knowledge, path: "/knowledge"),
            store: QueryStore(client: nil)
        ) { path, newTab in spy.opened.append((path, newTab)) }
        context.replaceRoute = { spy.replaced.append($0) }
        context.onChromeChange = { _ in spy.chromeChanges += 1 }
        context.onSidebarViewChange = { _ in spy.sidebarChanges += 1 }
        context.onInspectorViewChange = { _ in spy.inspectorChanges += 1 }
        return context
    }

    /// Simulates what a screen does over its life: navigate, redirect, publish chrome, and its
    /// `onDisappear` clearing the sidebar and inspector.
    private func exercise(_ context: NativeScreenContext) {
        context.navigate("/chat")
        context.navigate("/knowledge/page", replace: true)
        context.openInNewTab("/library")
        context.chrome = NativeChrome(title: "Changed")
        context.sidebarView = AnyView(EmptyView())
        context.sidebarView = nil
        context.inspectorView = nil
    }

    @Test("an attached context reaches its tab")
    func attachedForwards() {
        let spy = TabSpy()
        let context = makeContext(spy)
        exercise(context)
        #expect(spy.opened.map(\.path) == ["/chat", "/library"])
        #expect(spy.opened.map(\.newTab) == [false, true])
        #expect(spy.replaced == ["/knowledge/page"])
        #expect(spy.chromeChanges == 1)
        #expect(spy.sidebarChanges == 2)
        #expect(spy.inspectorChanges == 1)
    }

    @Test("a detached context can't navigate the tab or overwrite its shell state")
    func detachedIsInert() {
        let spy = TabSpy()
        let context = makeContext(spy)
        context.detach()
        #expect(!context.isAttached)
        exercise(context)
        #expect(spy.opened.isEmpty)
        #expect(spy.replaced.isEmpty)
        #expect(spy.chromeChanges == 0)
        #expect(spy.sidebarChanges == 0)
        #expect(spy.inspectorChanges == 0)
    }
}
