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
    @Environment(NativeScreenContext.self) private var screenContext

    let text: String
    let theme: ThemeTokens
    var embeds: [KnowledgeEmbed] = []
    var embedLayoutVersion: Int = 0
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
    var onEmbedLayoutChange: () -> Void = {}

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
        view.onEmbedSizeChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.handleEmbedSizeChange(in: view)
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
        view.onEmbedSizeChange = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.handleEmbedSizeChange(in: view)
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

        if coordinator.applyStyling(to: view) {
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LivePreviewNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        if view.updateContainerWidth(width) {
            _ = context.coordinator.applyStyling(to: view)
        }
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
            var embeds: [KnowledgeEmbed]
            var embedSizes: [String: RoundedSize]
            var containerWidth: Int
        }

        private struct RoundedSize: Equatable {
            var width: Int
            var height: Int

            init(_ size: CGSize) {
                self.width = Int(ceil(size.width))
                self.height = Int(ceil(size.height))
            }
        }

        init(parent: KnowledgeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            _ = applyStyling(to: view)
            view.invalidateIntrinsicContentSize()
            parent.onTextChange(view.string, view.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            if applyStyling(to: view) {
                view.invalidateIntrinsicContentSize()
                scheduleEmbedLayoutNotify()
            }
            parent.onSelectionChange(view.selectedRange(), view.isFocusedEditor)
        }

        func handleFocusChange(in view: LivePreviewNSTextView, isFocused: Bool) {
            if applyStyling(to: view) {
                view.invalidateIntrinsicContentSize()
                scheduleEmbedLayoutNotify()
            }
            parent.onSelectionChange(view.selectedRange(), isFocused)
        }

        func handleEmbedSizeChange(in view: LivePreviewNSTextView) {
            if applyStyling(to: view) {
                view.invalidateIntrinsicContentSize()
                scheduleEmbedLayoutNotify()
            }
        }

        private func scheduleEmbedLayoutNotify() {
            let notify = parent.onEmbedLayoutChange
            Task { @MainActor in
                notify()
            }
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

        /// Returns `true` when inline embed metrics or group layout changed and the view's fitting height may differ.
        @discardableResult
        func applyStyling(to view: LivePreviewNSTextView) -> Bool {
            guard let storage = view.textStorage else { return false }
            let markdown = view.string
            let selection = view.selectedRange()
            let focused = view.isFocusedEditor
            let containerWidth = max(120, view.textContainer?.size.width ?? 600)

            let key = RenderKey(
                text: markdown,
                selection: selection,
                isFocused: focused,
                mode: parent.theme.mode,
                findMatches: parent.findMatches,
                activeFind: parent.activeFindMatchRange,
                embeds: parent.embeds,
                embedSizes: view.measuredEmbedSizes.mapValues(RoundedSize.init),
                containerWidth: Int(ceil(containerWidth))
            )
            guard key != lastRenderedKey else { return false }
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
                view.syncEmbedHosts(groups: [], theme: parent.theme, screenContext: parent.screenContext, containerWidth: containerWidth)
                return view.updateEmbedLayout(groups: [], metricsByID: [:])
            }

            let preview = KnowledgeMarkdownSyntax.livePreview(
                in: markdown,
                selection: selection,
                isFocused: focused
            )
            view.cachedTokens = preview.tokens

            let embedGroups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(
                in: markdown,
                embeds: parent.embeds,
                tokens: preview.tokens
            )
            view.syncEmbedHosts(
                groups: embedGroups,
                theme: parent.theme,
                screenContext: parent.screenContext,
                containerWidth: containerWidth
            )

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
            let hiddenAttrs: [NSAttributedString.Key: Any] = [
                .font: hiddenFont,
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
            ]
            for range in preview.hiddenRanges {
                guard let safe = clamped(range, length: fullLength) else { continue }
                storage.addAttributes(hiddenAttrs, range: safe)
            }

            // 4. Reserve inline paragraph spacing for resolved embeds and hide unedited embed tokens.
            var metricsByID: [String: KnowledgeInlineEmbedMetrics] = [:]
            for group in embedGroups {
                let anyRevealed = group.placements.contains {
                    KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
                        for: $0,
                        selection: selection,
                        isFocused: focused,
                        activeFindMatch: parent.activeFindMatchRange
                    )
                }
                let isCollapsedStandalone = group.isStandaloneLine && !anyRevealed
                let measured = view.measuredSize(forGroupID: group.id)
                let metrics = KnowledgeInlineEmbedLayout.metrics(
                    measuredSize: measured,
                    isCollapsedStandalone: isCollapsedStandalone
                )
                metricsByID[group.id] = metrics

                if isCollapsedStandalone {
                    if let safeContent = clamped(group.lineContentRange, length: fullLength) {
                        storage.addAttributes(hiddenAttrs, range: safeContent)
                    }
                } else {
                    for placement in group.placements {
                        let reveal = KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
                            for: placement,
                            selection: selection,
                            isFocused: focused,
                            activeFindMatch: parent.activeFindMatchRange
                        )
                        if reveal {
                            // Ensure delimiters stay visible when revealed via standalone-line caret or active Find match.
                            if let safeTok = clamped(placement.tokenRange, length: fullLength) {
                                storage.addAttribute(.font, value: baseFont, range: safeTok)
                            }
                            if let tok = preview.tokens.first(where: { $0.range == placement.tokenRange }) {
                                for delim in tok.syntaxRanges {
                                    if let safeDelim = clamped(delim, length: fullLength) {
                                        storage.addAttribute(.foregroundColor, value: tertiaryColor, range: safeDelim)
                                    }
                                }
                            }
                        } else if let safeTok = clamped(placement.tokenRange, length: fullLength) {
                            storage.addAttributes(hiddenAttrs, range: safeTok)
                        }
                    }
                }

                if let safeLine = clamped(group.lineRange, length: fullLength) {
                    let embedParaStyle = NSMutableParagraphStyle()
                    embedParaStyle.lineSpacing = isCollapsedStandalone ? 0 : parent.theme.lineSpacing(.body)
                    if isCollapsedStandalone {
                        embedParaStyle.maximumLineHeight = KnowledgeInlineEmbedLayout.collapsedStandaloneLineHeight
                    }
                    embedParaStyle.paragraphSpacing = metrics.reservedSpacing
                    storage.addAttribute(.paragraphStyle, value: embedParaStyle, range: safeLine)
                }
            }

            // 5. Overlay unified ⌘F find highlights.
            for match in parent.findMatches {
                guard let safe = clamped(match, length: fullLength) else { continue }
                let isActive = (parent.activeFindMatchRange == match)
                storage.addAttribute(.backgroundColor, value: isActive ? findActiveBg : findMatchBg, range: safe)
            }

            storage.endEditing()

            let embedLayoutChanged = view.updateEmbedLayout(groups: embedGroups, metricsByID: metricsByID)
            // Keep RenderKey in sync with any newly created host's initial measured size.
            lastRenderedKey?.embedSizes = view.measuredEmbedSizes.mapValues(RoundedSize.init)
            return embedLayoutChanged
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
/// native find bar, native `UndoManager`, plain-text paste, `⌘`-click `[[link]]` hit testing,
/// and inline SwiftUI embed hosts anchored directly at their source paragraphs.
@MainActor
final class LivePreviewNSTextView: NSTextView {
    private final class MountedEmbedHost {
        let id: String
        let hostView: NSHostingView<AnyView>
        var measuredSize: CGSize
        var lastEmbeds: [KnowledgeEmbed]
        var lastMaxWidth: CGFloat
        var lastThemeMode: ColorMode

        init(
            id: String,
            hostView: NSHostingView<AnyView>,
            measuredSize: CGSize,
            lastEmbeds: [KnowledgeEmbed],
            lastMaxWidth: CGFloat,
            lastThemeMode: ColorMode
        ) {
            self.id = id
            self.hostView = hostView
            self.measuredSize = measuredSize
            self.lastEmbeds = lastEmbeds
            self.lastMaxWidth = lastMaxWidth
            self.lastThemeMode = lastThemeMode
        }
    }

    private let contentStorage = NSTextContentStorage()
    var cachedTokens: [KnowledgeSyntaxToken] = []
    var onCommandClickLink: ((KnowledgeWikiTarget) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onEmbedSizeChange: (() -> Void)?
    private(set) var isFocusedEditor = false

    private var embedHosts: [String: MountedEmbedHost] = [:]
    private var activeEmbedGroups: [KnowledgeInlineEmbedParagraph] = []
    private var activeEmbedMetrics: [String: KnowledgeInlineEmbedMetrics] = [:]
    private var activeEmbedFrames: [KnowledgeInlineEmbedFrame] = []

    var hasMountedEmbeds: Bool { !embedHosts.isEmpty }

    var measuredEmbedSizes: [String: CGSize] {
        embedHosts.mapValues(\.measuredSize)
    }

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

    override func layout() {
        super.layout()
        layoutEmbedViews()
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

    func measuredSize(forGroupID id: String) -> CGSize {
        embedHosts[id]?.measuredSize ?? KnowledgeInlineEmbedLayout.defaultPlaceholderSize
    }

    /// Updates `textContainer.size.width` when SwiftUI proposes a new width, returning `true` if it changed.
    func updateContainerWidth(_ width: CGFloat) -> Bool {
        guard let container = textContainer, abs(container.size.width - width) > 0.5 else { return false }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        return true
    }

    /// Reconciles mounted `NSHostingView` subviews with `groups`, reusing views across unrelated prose edits.
    func syncEmbedHosts(
        groups: [KnowledgeInlineEmbedParagraph],
        theme: ThemeTokens,
        screenContext: NativeScreenContext,
        containerWidth: CGFloat
    ) {
        let maxWidth = max(120, containerWidth)
        let activeIDs = Set(groups.map(\.id))

        for (id, host) in embedHosts where !activeIDs.contains(id) {
            host.hostView.removeFromSuperview()
            embedHosts.removeValue(forKey: id)
        }

        for group in groups {
            let groupEmbeds = group.placements.map(\.embed)
            let rootView = AnyView(
                KnowledgeInlineEmbedGroupView(
                    placements: group.placements,
                    maxWidth: maxWidth,
                    fillsWidth: group.fillsContainerWidth,
                    onSizeChange: { [weak self] newSize in
                        self?.handleMeasuredSize(newSize, forGroupID: group.id)
                    }
                )
                .environment(screenContext)
                .environment(\.vesperTheme, theme)
            )

            if let existing = embedHosts[group.id] {
                let needsRootUpdate = existing.lastEmbeds != groupEmbeds
                    || abs(existing.lastMaxWidth - maxWidth) > 0.5
                    || existing.lastThemeMode != theme.mode
                if needsRootUpdate {
                    existing.hostView.rootView = rootView
                    existing.lastEmbeds = groupEmbeds
                    existing.lastMaxWidth = maxWidth
                    existing.lastThemeMode = theme.mode
                    let fitted = existing.hostView.fittingSize
                    if fitted.width > 1, fitted.height > 1 {
                        existing.measuredSize = fitted
                    }
                }
            } else {
                let hostView = NSHostingView(rootView: rootView)
                hostView.translatesAutoresizingMaskIntoConstraints = true
                let fitted = hostView.fittingSize
                let initialSize: CGSize = (fitted.width > 1 && fitted.height > 1)
                    ? fitted
                    : CGSize(
                        width: group.fillsContainerWidth ? maxWidth : min(maxWidth, KnowledgeInlineEmbedLayout.defaultPlaceholderSize.width),
                        height: KnowledgeInlineEmbedLayout.defaultPlaceholderSize.height
                    )
                hostView.frame = CGRect(origin: .zero, size: initialSize)
                addSubview(hostView)
                embedHosts[group.id] = MountedEmbedHost(
                    id: group.id,
                    hostView: hostView,
                    measuredSize: initialSize,
                    lastEmbeds: groupEmbeds,
                    lastMaxWidth: maxWidth,
                    lastThemeMode: theme.mode
                )
            }
        }
    }

    @discardableResult
    func updateEmbedLayout(
        groups: [KnowledgeInlineEmbedParagraph],
        metricsByID: [String: KnowledgeInlineEmbedMetrics]
    ) -> Bool {
        let changed = activeEmbedGroups != groups || activeEmbedMetrics != metricsByID
        activeEmbedGroups = groups
        activeEmbedMetrics = metricsByID
        layoutEmbedViews()
        return changed
    }

    private func handleMeasuredSize(_ newSize: CGSize, forGroupID id: String) {
        guard newSize.width.isFinite, newSize.height.isFinite, newSize.width > 1, newSize.height > 1 else { return }
        guard let host = embedHosts[id] else { return }
        guard abs(host.measuredSize.width - newSize.width) > 0.5
                || abs(host.measuredSize.height - newSize.height) > 0.5 else { return }
        host.measuredSize = newSize
        Task { @MainActor [weak self] in
            self?.onEmbedSizeChange?()
        }
    }

    func layoutEmbedViews() {
        guard let layoutManager = textLayoutManager, let container = textContainer else { return }
        let frames = KnowledgeInlineEmbedLayout.computeFrames(
            groups: activeEmbedGroups,
            metricsByID: activeEmbedMetrics,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            containerWidth: max(120, container.size.width),
            textContainerOrigin: textContainerOrigin
        )
        activeEmbedFrames = frames

        let frameByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.groupID, $0.frame) })
        for (id, host) in embedHosts {
            if let rect = frameByID[id] {
                if host.hostView.isHidden { host.hostView.isHidden = false }
                if host.hostView.frame != rect {
                    host.hostView.frame = rect
                }
            } else {
                host.hostView.isHidden = true
            }
        }
    }

    /// Computes the TextKit 2 layout height needed at `width`, including inline embeds.
    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager = textLayoutManager, let container = textContainer else { return 28 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutEmbedViews()
        return KnowledgeInlineEmbedLayout.totalFittingHeight(
            usageBoundsHeight: layoutManager.usageBoundsForTextContainer.height,
            embedFrames: activeEmbedFrames,
            verticalInset: textContainerInset.height
        )
    }
}
