import AppKit
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("ChatCitationBubble")
struct ChatCitationBubbleTests {
    private func makeContext() -> NativeScreenContext {
        NativeScreenContext(
            match: NativeRouteMatch(screen: .chat, path: "/chat/test"),
            store: QueryStore(client: nil)
        ) { _, _ in }
    }

    @Test("MarkdownTextView reports citation target and non-empty screen anchor on link click")
    func markdownTextViewReportsCitationAnchor() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 520, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        window.contentView = contentView

        let textView = MarkdownTextView()
        textView.frame = NSRect(x: 16, y: 16, width: 480, height: 120)
        contentView.addSubview(textView)

        let doc = MarkdownParser.parse("Claim supported by [1].", chat: true, citations: [1])
        let rendering = MarkdownRenderer.render(doc, theme: ThemeTokens(mode: .dark), options: MarkdownRenderOptions(textStyle: .chat))
        textView.show(rendering)
        _ = textView.fittingHeight(width: 480)

        let citeRange = (textView.string as NSString).range(of: "\u{202F}1\u{202F}")
        #expect(citeRange.location != NSNotFound)

        var receivedTarget: MarkdownLinkTarget?
        var receivedAnchor: MarkdownLinkAnchor?
        textView.onLink = { target, _, anchor in
            receivedTarget = target
            receivedAnchor = anchor
        }

        let handled = textView.textView(textView, clickedOnLink: URL(string: "cite:1")!, at: citeRange.location)
        #expect(handled)
        #expect(receivedTarget == .citation(1))
        #expect(receivedAnchor != nil)
        #expect(receivedAnchor?.window === window)
        #expect(receivedAnchor?.screenRect.isEmpty == false)
    }

    @Test("presenter opens, switches between citations, toggles closed on second click, and dismisses")
    func presenterLifecycle() {
        let presenter = ChatCitationBubblePresenter()
        let context = makeContext()
        let theme = ThemeTokens(mode: .dark)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = MarkdownLinkAnchor(screenRect: CGRect(x: 320, y: 260, width: 18, height: 16), window: window)
        let source1 = ChatListedSource(title: "Swift Evolution", url: "https://swift.org", number: 1)
        let source2 = ChatListedSource(title: "Design Note", url: "", number: 2, ref: "Design/Citations")

        presenter.toggle(messageId: "m1", source: source1, previewRequest: nil, anchor: anchor, context: context, theme: theme)
        #expect(presenter.isVisible)
        #expect(presenter.currentKey == .init(messageId: "m1", number: 1))

        // Clicking a different citation switches directly to it.
        presenter.toggle(messageId: "m1", source: source2, previewRequest: nil, anchor: anchor, context: context, theme: theme)
        #expect(presenter.isVisible)
        #expect(presenter.currentKey == .init(messageId: "m1", number: 2))

        // Clicking the same citation again begins dismissal and clears the active key.
        presenter.toggle(messageId: "m1", source: source2, previewRequest: nil, anchor: anchor, context: context, theme: theme)
        #expect(presenter.currentKey == nil)

        // Immediate non-animated dismiss tears down the panel cleanly.
        presenter.dismiss(animated: false)
        #expect(!presenter.isVisible)
    }
}
