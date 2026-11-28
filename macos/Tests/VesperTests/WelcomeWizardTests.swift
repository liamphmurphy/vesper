import AppKit
import SwiftUI
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("WelcomeWizard integration", .serialized)
struct WelcomeWizardTests {
    private func makeBootstrap(onboardedAt: String?, harnessConnected: Bool?) -> API.Bootstrap {
        let user = API.User(
            email: "me@localhost",
            emails: ["me@localhost"],
            harnessConnected: harnessConnected,
            id: "u1",
            initials: "LU",
            name: "Local user",
            onboardedAt: onboardedAt,
            roleTitle: ""
        )
        return API.Bootstrap(
            agents: [],
            counts: API.Bootstrap.Counts(inbox: 0, liveAgents: 0, needsYou: 0, wikiSuggestions: 0),
            epics: [],
            labels: [],
            me: user,
            projects: [],
            users: [user],
            workspace: API.Workspace(id: "ws1", name: "Vesper", slug: "vesper")
        )
    }

    private func mountChatScreen(
        path: String = "/chat",
        query: [String: String] = ["new": ""],
        onboardedAt: String?,
        harnessConnected: Bool?
    ) -> NativeScreenContext {
        let store = QueryStore(client: nil)
        store.setData(makeBootstrap(onboardedAt: onboardedAt, harnessConnected: harnessConnected), for: API.getBootstrap())
        let context = NativeScreenContext(
            match: NativeRouteMatch(screen: .chat, path: path, query: query),
            store: store
        ) { _, _ in }

        let host = NSHostingController(
            rootView: ChatScreen()
                .environment(context)
                .environment(\.vesperTheme, ThemeTokens(mode: .dark))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFrontRegardless()
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.close()
        return context
    }

    @Test("first-run user sees the full Welcome Wizard and setup sidebar")
    func firstRunShowsFullWizard() {
        let context = mountChatScreen(onboardedAt: nil, harnessConnected: false)
        #expect(context.chrome.title == "Welcome to Vesper")
        #expect(context.chrome.navigator?.id == OnboardingLogic.navId)
        #expect(context.chrome.navigator?.sections.first?.items.count == 4)
    }

    @Test("onboarded user without a connected harness sees harness-only wizard")
    func missingHarnessShowsHarnessOnlyWizard() {
        let context = mountChatScreen(onboardedAt: "2026-11-20T00:00:00Z", harnessConnected: false)
        #expect(context.chrome.title == "Connect a harness")
        #expect(context.chrome.navigator?.id == OnboardingLogic.navId)
        #expect(context.chrome.navigator?.sections.first?.items.count == 1)
        #expect(context.chrome.navigator?.selectedId == "step:2")
    }

    @Test("onboarded user with connected harness lands in normal Chat")
    func onboardedUserLandsInChat() {
        let context = mountChatScreen(onboardedAt: "2026-11-20T00:00:00Z", harnessConnected: true)
        #expect(context.chrome.title == "Chat")
        #expect(context.chrome.navigator?.id == ChatNav.id)
    }

    @Test("?setup forces the full Welcome Wizard even after onboarding")
    func setupQueryForcesFullWizard() {
        let context = mountChatScreen(
            query: ["new": "", "setup": ""],
            onboardedAt: "2026-11-20T00:00:00Z",
            harnessConnected: true
        )
        #expect(context.chrome.title == "Welcome to Vesper")
        #expect(context.chrome.navigator?.id == OnboardingLogic.navId)
        #expect(context.chrome.navigator?.sections.first?.items.count == 4)
    }
}
