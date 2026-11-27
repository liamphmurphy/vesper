import AppKit
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
        #expect(!context.isActiveTab)
        exercise(context)
        #expect(spy.opened.isEmpty)
        #expect(spy.replaced.isEmpty)
        #expect(spy.chromeChanges == 0)
        #expect(spy.sidebarChanges == 0)
        #expect(spy.inspectorChanges == 0)
    }

    @Test("isActiveTab reflects host visibility and turns false on detach")
    func activeTabCheckTracksHost() {
        let spy = TabSpy()
        let context = makeContext(spy)
        #expect(context.isActiveTab)

        var active = false
        context.isActiveTabCheck = { active }
        #expect(!context.isActiveTab)

        active = true
        #expect(context.isActiveTab)

        context.detach()
        #expect(!context.isActiveTab)
    }
}

/// The window's sidebar and inspector draw a screen's custom bodies in their own hosting views, outside
/// the screen's view tree. These pin that those bodies still find the screen's context: without it the
/// Doc, Slides and Design editors' docked chat trapped as soon as their inspector showed Chat.
@MainActor
@Suite("NativeScreenContext hosted bodies", .serialized)
struct NativeScreenContextHostedBodyTests {
    private final class Seen {
        var renders = 0
        var context: NativeScreenContext?
    }

    /// Reads the context the way `DockedChatView` does, but as an optional, so a missing context
    /// fails the test instead of trapping the test process.
    private struct ContextProbe: View {
        let seen: Seen
        @Environment(NativeScreenContext.self) private var context: NativeScreenContext?

        var body: some View {
            seen.renders += 1
            seen.context = context
            return Color.clear
        }
    }

    private func makeContext() -> NativeScreenContext {
        NativeScreenContext(match: NativeRouteMatch(screen: .knowledge, path: "/knowledge"), store: QueryStore(client: nil)) { _, _ in }
    }

    /// Renders `body` the way `InspectorBodyHost` and `SidebarView` do: in a hosting view of its own,
    /// with the theme but nothing from the screen.
    private func renderInShellHost(_ body: AnyView?) {
        let host = NSHostingController(rootView: (body ?? AnyView(EmptyView())).environment(\.vesperTheme, ThemeTokens(mode: .dark)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFrontRegardless()
        host.view.layoutSubtreeIfNeeded()
        window.close()
    }

    @Test("inspector bodies handed to the tab carry the screen's context")
    func inspectorBodiesCarryContext() {
        let context = makeContext()
        var published: ((String) -> AnyView?)?
        context.onInspectorViewChange = { published = $0 }
        let seen = Seen()
        context.inspectorView = { _ in AnyView(ContextProbe(seen: seen)) }

        renderInShellHost(published?("chat"))
        #expect(seen.renders > 0)
        #expect(seen.context === context)

        // The tab reads `hostedInspectorView` directly when it first installs a screen.
        let installed = Seen()
        context.inspectorView = { _ in AnyView(ContextProbe(seen: installed)) }
        renderInShellHost(context.hostedInspectorView?("chat"))
        #expect(installed.renders > 0)
        #expect(installed.context === context)
    }

    @Test("sidebar bodies handed to the tab carry the screen's context")
    func sidebarBodiesCarryContext() {
        let context = makeContext()
        var published: AnyView?
        context.onSidebarViewChange = { published = $0 }
        let seen = Seen()
        context.sidebarView = AnyView(ContextProbe(seen: seen))

        renderInShellHost(published)
        #expect(seen.renders > 0)
        #expect(seen.context === context)

        let installed = Seen()
        context.sidebarView = AnyView(ContextProbe(seen: installed))
        renderInShellHost(context.hostedSidebarView)
        #expect(installed.renders > 0)
        #expect(installed.context === context)
    }

    @Test("no body stays no body, so the inspector still falls back to declarative sections")
    func absentBodiesStayAbsent() {
        let context = makeContext()
        #expect(context.hostedInspectorView == nil)
        #expect(context.hostedSidebarView == nil)
        context.inspectorView = { _ in nil }
        #expect(context.hostedInspectorView?("details") == nil)
    }
}
