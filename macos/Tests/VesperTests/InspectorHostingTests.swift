import AppKit
import Foundation
import SwiftUI
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("Native inspector hosting")
struct InspectorHostingTests {
    private func makeApp() -> (AppModel, URL) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-inspector-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let conn = Connection(baseURL: URL(string: "http://127.0.0.1:19999")!, sessionToken: "test-token")
        let app = AppModel(dataDirectory: dir, stack: nil, devConnection: conn)
        return (app, dir)
    }

    private func pumpLayout(_ seconds: TimeInterval = 0.35, window: NSWindow?) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window?.layoutIfNeeded()
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func seedChat(in store: QueryStore, chatId: String) {
        let session = API.ChatSession(
            agent: API.AgentRef(colorIndex: 0, handle: "judy", id: "p1", name: "Judy"),
            archived: false,
            createdAt: "2026-11-26T20:00:00Z",
            harness: API.Harness(rawValue: "claude-code"),
            id: chatId,
            messageCount: 2,
            model: "claude-sonnet",
            revision: 1,
            state: .idle,
            title: "Inspector chat",
            unread: 0,
            updatedAt: "2026-11-26T20:01:00Z"
        )
        let messages = API.ListChatMessagesResponse(
            hasMore: false,
            messages: [
                API.ChatMessage(bodyMd: "Hello from user", createdAt: "2026-11-26T20:00:00Z", id: "m1", role: .user, seq: 1),
                API.ChatMessage(bodyMd: "Hello from assistant with `code` and **bold**.", createdAt: "2026-11-26T20:00:10Z", id: "m2", role: .assistant, seq: 2),
            ]
        )
        store.setData(session, for: API.getChat(id: chatId))
        store.setData(messages, for: API.listChatMessages(id: chatId, limit: 200))
    }

    private func findViews<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var result: [T] = []
        if let match = root as? T {
            result.append(match)
        }
        for sub in root.subviews {
            result.append(contentsOf: findViews(of: type, in: sub))
        }
        return result
    }

    @Test("opening the Knowledge Chat inspector with messages lays out without constraint loops")
    func knowledgeChatInspectorWithMessagesLaysOutCleanly() throws {
        let generalChatKey = "VesperNativeKnowledgeGeneralChatId"
        let inspectorOpenKey = "VesperNativeKnowledgeInspectorOpen"
        let prevGeneralChat = UserDefaults.standard.object(forKey: generalChatKey)
        let prevInspectorOpen = UserDefaults.standard.object(forKey: inspectorOpenKey)
        defer {
            if let prevGeneralChat { UserDefaults.standard.set(prevGeneralChat, forKey: generalChatKey) }
            else { UserDefaults.standard.removeObject(forKey: generalChatKey) }
            if let prevInspectorOpen { UserDefaults.standard.set(prevInspectorOpen, forKey: inspectorOpenKey) }
            else { UserDefaults.standard.removeObject(forKey: inspectorOpenKey) }
        }

        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = "chat-knowledge-inspector"
        seedChat(in: app.system.store, chatId: chatId)
        UserDefaults.standard.set(chatId, forKey: generalChatKey)
        UserDefaults.standard.set(false, forKey: inspectorOpenKey)

        let tab = app.makeTab(kind: .vesper, path: "/knowledge")
        let win = app.makeWindow(tabs: [tab])
        defer { win.close() }
        win.showWindow(nil)
        win.window?.makeKeyAndOrderFront(nil)
        pumpLayout(0.3, window: win.window)

        win.send(.inspectorSelectTab(tabId: KnowledgeInspectorLogic.chatTabId))
        win.send(.inspectorVisibility(open: true))
        win.split.splitViewItems.last?.isCollapsed = false
        pumpLayout(0.5, window: win.window)

        let inspectorVC = try #require(win.split.splitViewItems.last?.viewController as? InspectorViewController)
        let nativeHost = try #require(inspectorVC.children.first { $0 is NSHostingController<InspectorBodyHost> })
        let nativeHidden = nativeHost.view.isHidden
        #expect(!nativeHidden)
        let markdownViews = findViews(of: MarkdownTextView.self, in: nativeHost.view)
        let composerViews = findViews(of: ComposerNSTextView.self, in: nativeHost.view)
        #expect(markdownViews.count >= 2)
        #expect(composerViews.count == 1)
    }
}
