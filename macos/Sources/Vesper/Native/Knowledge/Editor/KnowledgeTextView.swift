import AppKit
import SwiftUI
import VesperCore

// MARK: - Selection & Completion Key Types

/// Keyboard actions intercepted when the `[[` / `![[` / `#` completion popover is open.
enum KnowledgeTextKeyAction: Sendable, Equatable {
    case moveUp
    case moveDown
    case accept
    case dismiss
}

/// Versioned programmatic selection request so external edits (e.g. completion insertion or find jump)
/// update the caret without fighting user typing.
struct KnowledgeTextSelectionRequest: Equatable, Sendable {
    let token: Int
    let segmentIndex: Int
    let range: NSRange
}

// MARK: - Isolated macOS TextKit 2 Live-Preview Editor

/// Isolated AppKit `NSViewRepresentable` wrapping a TextKit 2 `NSTextView` with Obsidian-style
/// live-preview styling driven by `KnowledgeMarkdownSyntax.livePreview(in:selection:isFocused:)`.
///
/// Kept in this single file so iOS-over-Tailscale can swap in a `UITextView` implementation
/// without touching `KnowledgeEditorView` or `VesperCore`.
struct KnowledgeTextView: NSViewRepresentable {
    let text: String
    let theme: ThemeTokens
    var isCompletionOpen: Bool = false
    var findMatches: [NSRange] = []
    var activeFindMatchRange: NSRange? = nil
    var selectionRequest: KnowledgeTextSelectionRequest? = nil
    var segmentIndex: Int = 0
    var minHeight: CGFloat = 28

    let onTextChange: (String, NSRange) -> Void
    let onSelectionChange: (NSRange, Bool) -> Void
    let onOpenLink: (KnowledgeWikiTarget) -> Void
    let onCompletionKey: (KnowledgeTextKeyAction) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> LivePreviewNSTextView {
        let view = LivePreviewNSTextView()
        view.delegate = context.coordinator
        view.onCommandClickLink = { [weak coordinator = context.coordinator] target in
            coordinator?.parent.onOpenLink(target)
        }
        view.onFocusChange = { [weak coordinator = context.coordinator, weak view] focused in
            guard let coordinator, let view else { return }
            coordinator.handleFocusChange(in: view, isFocused: focused)
        }
        view.string = text
        context.coordinator.applyStyling(to: view)
        return view
    }

    func updateNSView(_ view: LivePreviewNSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.onCommandClickLink = { [weak coordinator] target in
            coordinator?.parent.onOpenLink(target)
        }
        view.onFocusChange = { [weak coordinator, weak view] focused in
            guard let coordinator, let view else { return }
            coordinator.handleFocusChange(in: view, isFocused: focused)
        }

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        if view.string != text {
            let previousSelection = view.selectedRange()
            view.string = text
            let maxLen = (text as NSString).length
            let clampedLoc = min(previousSelection.location, maxLen)
            let clampedLen = min(previousSelection.length, maxLen - clampedLoc)
            view.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
        }

        if let req = selectionRequest,
           req.segmentIndex == segmentIndex,
           req.token != coordinator.lastAppliedSelectionToken {
            coordinator.lastAppliedSelectionToken = req.token
            let maxLen = (view.string as NSString).length
            let loc = max(0, min(req.range.location, maxLen))
            let len = max(0, min(req.range.length, maxLen - loc))
            let clamped = NSRange(location: loc, length: len)
            view.setSelectedRange(clamped)
            view.scrollRangeToVisible(clamped)
            view.window?.makeFirstResponder(view)
        }

        coordinator.applyStyling(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LivePreviewNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = max(minHeight, view.fittingHeight(width: width))
        return CGSize(width: width, height: height)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KnowledgeTextView
        var isUpdatingFromSwiftUI = false
        var lastAppliedSelectionToken: Int?
        private var lastRenderedKey: RenderKey?

        private struct RenderKey: Equatable {
            var text: String
            var selection: NSRange
            var isFocused: Bool
            var mode: ColorMode
            var findMatches: [NSRange]
            var activeFind: NSRange?
        }

        init(parent: KnowledgeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            applyStyling(to: view)
            view.invalidateIntrinsicContentSize()
            parent.onTextChange(view.string, view.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            applyStyling(to: view)
            parent.onSelectionChange(view.selectedRange(), view.isFocusedEditor)
        }

        func handleFocusChange(in view: LivePreviewNSTextView, isFocused: Bool) {
            applyStyling(to: view)
            parent.onSelectionChange(view.selectedRange(), isFocused)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.isCompletionOpen else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCompletionKey(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCompletionKey(.moveDown)
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertNewline(_:)):
                return parent.onCompletionKey(.accept)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCompletionKey(.dismiss)
            default:
                return false
            }
        }

        func applyStyling(to view: LivePreviewNSTextView) {
            guard let storage = view.textStorage else { return }
            let markdown = view.string
            let selection = view.selectedRange()
            let focused = view.isFocusedEditor

            let key = RenderKey(
                text: markdown,
                selection: selection,
                isFocused: focused,
                mode: parent.theme.mode,
                findMatches: parent.findMatches,
                activeFind: parent.activeFindMatchRange
            )
            guard key != lastRenderedKey else { return }
            lastRenderedKey = key

            let palette = parent.theme.palette
            let baseSize = parent.theme.pointSize(.body)
            let baseFont = NSFont.systemFont(ofSize: baseSize, weight: .regular)
            let monoFont = NSFont.monospacedSystemFont(ofSize: max(11, baseSize - 1), weight: .regular)
            let textColor = NSColor(palette.text)
            let secondaryColor = NSColor(palette.secondaryText)
            let tertiaryColor = NSColor(palette.tertiaryText)
            let accentColor = NSColor(palette.accent)
            let codeBg = NSColor(parent.theme.swiftUIColor("surface-sunken", fallback: palette.surface))
            let tagBg = NSColor(parent.theme.swiftUIColor("accent-soft", fallback: palette.selected))
            let blockBg = NSColor(palette.hover)
            let findMatchBg = NSColor(palette.selected)
            let findActiveBg = NSColor(palette.accent.opacity(0.35))

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = parent.theme.lineSpacing(.body)

            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
            ]

            view.insertionPointColor = accentColor
            view.typingAttributes = baseAttrs

            let fullLength = storage.length
            guard fullLength > 0 else {
                view.cachedTokens = []
                return
            }

            let preview = KnowledgeMarkdownSyntax.livePreview(
                in: markdown,
                selection: selection,
                isFocused: focused
            )
            view.cachedTokens = preview.tokens

            storage.beginEditing()
            storage.setAttributes(baseAttrs, range: NSRange(location: 0, length: fullLength))

            // 1. Style token content ranges.
            for token in preview.tokens {
                guard let contentRange = clamped(token.contentRange, length: fullLength) else { continue }
                switch token.kind {
                case .heading(let level):
                    let scale: CGFloat = switch level {
                    case 1: 1.65
                    case 2: 1.40
                    case 3: 1.22
                    case 4: 1.10
                    default: 1.00
                    }
                    let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize * scale, weight: weight), range: contentRange)

                case .bold:
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize, weight: .semibold), range: contentRange)

                case .italic:
                    storage.addAttribute(.font, value: italicFont(size: baseSize, bold: false), range: contentRange)

                case .boldItalic:
                    storage.addAttribute(.font, value: italicFont(size: baseSize, bold: true), range: contentRange)

                case .strikethrough:
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: secondaryColor,
                    ], range: contentRange)

                case .inlineCode:
                    storage.addAttributes([
                        .font: monoFont,
                        .backgroundColor: codeBg,
                    ], range: contentRange)

                case .fencedCodeBlock:
                    if let fullRange = clamped(token.range, length: fullLength) {
                        storage.addAttributes([
                            .font: monoFont,
                            .backgroundColor: codeBg,
                        ], range: fullRange)
                    }

                case .blockquote:
                    storage.addAttribute(.foregroundColor, value: secondaryColor, range: contentRange)

                case .listItem(_, let checked):
                    if checked == true {
                        storage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: secondaryColor,
                        ], range: contentRange)
                    }

                case .frontmatter:
                    if let fullRange = clamped(token.range, length: fullLength) {
                        storage.addAttributes([
                            .font: monoFont,
                            .foregroundColor: tertiaryColor,
                        ], range: fullRange)
                    }

                case .wikiLink:
                    storage.addAttributes([
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: accentColor.withAlphaComponent(0.45),
                    ], range: contentRange)

                case .embed:
                    storage.addAttributes([
                        .foregroundColor: accentColor,
                        .backgroundColor: tagBg,
                    ], range: contentRange)

                case .tag:
                    if let fullRange = clamped(token.range, length: fullLength) {
                        storage.addAttributes([
                            .foregroundColor: accentColor,
                            .backgroundColor: tagBg,
                            .font: NSFont.systemFont(ofSize: max(11, baseSize - 1), weight: .medium),
                        ], range: fullRange)
                    }

                case .blockID:
                    if let fullRange = clamped(token.range, length: fullLength) {
                        storage.addAttributes([
                            .foregroundColor: tertiaryColor,
                            .backgroundColor: blockBg,
                            .font: NSFont.monospacedSystemFont(ofSize: max(10, baseSize - 2), weight: .regular),
                        ], range: fullRange)
                    }
                }
            }

            // 2. Style revealed syntax delimiters as muted syntax markers.
            for range in preview.revealedRanges {
                guard let safe = clamped(range, length: fullLength) else { continue }
                storage.addAttribute(.foregroundColor, value: tertiaryColor, range: safe)
            }

            // 3. Hide unrevealed syntax delimiters while preserving exact UTF-16 backing offsets.
            let hiddenFont = NSFont.systemFont(ofSize: 0.01)
            for range in preview.hiddenRanges {
                guard let safe = clamped(range, length: fullLength) else { continue }
                storage.addAttributes([
                    .font: hiddenFont,
                    .foregroundColor: NSColor.clear,
                    .backgroundColor: NSColor.clear,
                ], range: safe)
            }

            // 4. Overlay unified ⌘F find highlights.
            for match in parent.findMatches {
                guard let safe = clamped(match, length: fullLength) else { continue }
                let isActive = (parent.activeFindMatchRange == match)
                storage.addAttribute(.backgroundColor, value: isActive ? findActiveBg : findMatchBg, range: safe)
            }

            storage.endEditing()
        }

        private func clamped(_ range: NSRange, length: Int) -> NSRange? {
            guard range.location != NSNotFound, range.location >= 0, range.location < length else { return nil }
            let clampedLen = min(range.length, length - range.location)
            guard clampedLen > 0 else { return nil }
            return NSRange(location: range.location, length: clampedLen)
        }

        private func italicFont(size: CGFloat, bold: Bool) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            var traits: NSFontDescriptor.SymbolicTraits = [.italic]
            if bold { traits.insert(.bold) }
            let desc = base.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: desc, size: size) ?? base
        }
    }
}

// MARK: - TextKit 2 NSTextView Subclass

/// Editable TextKit 2 `NSTextView` with Writing Tools, spellcheck, dictation, Look Up,
/// native find bar, native `UndoManager`, plain-text paste, and `⌘`-click `[[link]]` hit testing.
@MainActor
final class LivePreviewNSTextView: NSTextView {
    private let contentStorage = NSTextContentStorage()
    var cachedTokens: [KnowledgeSyntaxToken] = []
    var onCommandClickLink: ((KnowledgeWikiTarget) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private(set) var isFocusedEditor = false

    init() {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)

        isEditable = true
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        writingToolsBehavior = .complete
        textContainerInset = NSSize(width: 0, height: 4)
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFocusedEditor = true
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            isFocusedEditor = false
            onFocusChange?(false)
        }
        return ok
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: point)
            if let target = KnowledgeMarkdownSyntax.hitTestLink(at: offset, in: string, tokens: cachedTokens) {
                onCommandClickLink?(target)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Computes the TextKit 2 layout height needed at `width`.
    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager = textLayoutManager, let container = textContainer else { return 28 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let insetHeight = textContainerInset.height * 2
        return ceil(layoutManager.usageBoundsForTextContainer.height + insetHeight + 4)
    }
}
