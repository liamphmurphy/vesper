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
    var selectedEmbedID: String? = nil
    var deletableEmbedURLs: Set<String> = []

    let onTextChange: (String, NSRange) -> Void
    let onSelectionChange: (NSRange, Bool) -> Void
    let onOpenLink: (KnowledgeWikiTarget) -> Void
    let onCompletionKey: (KnowledgeTextKeyAction) -> Bool
    var onEmbedLayoutChange: () -> Void = {}
    var onDropFiles: ([URL], Int) -> Void = { _, _ in }
    var onFileDragActiveChange: (Bool) -> Void = { _ in }
    var onPasteFiles: ([URL], NSRange) -> Void = { _, _ in }
    var onPasteImageData: (Data, String, NSRange) -> Void = { _, _, _ in }
    var onDropKnowledgeItem: (KnowledgeDragItem, Int, Bool) -> Void = { _, _, _ in }
    var onKnowledgeDragActiveChange: (KnowledgeDragItem?) -> Void = { _ in }
    var onResizeImage: (KnowledgeInlineEmbedPlacement, Int?) -> Void = { _, _ in }
    var onSelectEmbed: (KnowledgeInlineEmbedPlacement?) -> Void = { _ in }
    var onRemoveEmbed: (KnowledgeInlineEmbedPlacement) -> Void = { _ in }
    var onDeleteAttachment: (KnowledgeInlineEmbedPlacement) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> LivePreviewNSTextView {
        let view = LivePreviewNSTextView()
        view.delegate = context.coordinator
        wireCallbacks(on: view, coordinator: context.coordinator)
        view.string = text
        context.coordinator.applyStyling(to: view)
        return view
    }

    func updateNSView(_ view: LivePreviewNSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        wireCallbacks(on: view, coordinator: coordinator)

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        if view.string != text {
            let previousSelection = view.selectedRange()
            view.string = text
            coordinator.markNeedsFullRestyle()
            view.invalidateFittingHeightCache()
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

        if coordinator.applyStyling(to: view).layoutMayHaveChanged {
            coordinator.invalidateSizeIfNeeded(for: view)
        }
    }

    private func wireCallbacks(on view: LivePreviewNSTextView, coordinator: Coordinator) {
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
        view.onDropFiles = { [weak coordinator] urls, offset in
            coordinator?.parent.onDropFiles(urls, offset)
        }
        view.onFileDragActiveChange = { [weak coordinator] active in
            coordinator?.parent.onFileDragActiveChange(active)
        }
        view.onPasteFiles = { [weak coordinator] urls, range in
            coordinator?.parent.onPasteFiles(urls, range)
        }
        view.onPasteImageData = { [weak coordinator] data, filename, range in
            coordinator?.parent.onPasteImageData(data, filename, range)
        }
        view.onDropKnowledgeItem = { [weak coordinator] item, offset, optionHeld in
            coordinator?.parent.onDropKnowledgeItem(item, offset, optionHeld)
        }
        view.onKnowledgeDragActiveChange = { [weak coordinator] item in
            coordinator?.parent.onKnowledgeDragActiveChange(item)
        }
        view.onResizeImage = { [weak coordinator] placement, width in
            coordinator?.parent.onResizeImage(placement, width)
        }
        view.onSelectEmbed = { [weak coordinator] placement in
            coordinator?.parent.onSelectEmbed(placement)
        }
        view.onRemoveEmbed = { [weak coordinator] placement in
            coordinator?.parent.onRemoveEmbed(placement)
        }
        view.onDeleteAttachment = { [weak coordinator] placement in
            coordinator?.parent.onDeleteAttachment(placement)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LivePreviewNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        if view.updateContainerWidth(width) {
            _ = context.coordinator.applyStyling(to: view)
        }
        let height = max(minHeight, view.fittingHeight(width: width))
        view.noteReportedHeight(height)
        return CGSize(width: width, height: height)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KnowledgeTextView
        var isUpdatingFromSwiftUI = false
        var lastAppliedSelectionToken: Int?
        private var lastRenderedKey: RenderKey?
        private var lastDocumentKey: DocumentKey?
        private var cachedTokens: [KnowledgeSyntaxToken] = []
        private var cachedEmbedGroups: [KnowledgeInlineEmbedParagraph] = []
        private var lastSnapshot: StyleSnapshot?
        private var needsFullRestyle = true

        // Diagnostic counters verified by VesperTests.
        private(set) var fullRestyleCount = 0
        private(set) var incrementalRestyleCount = 0
        private(set) var skippedSelectionRestyleCount = 0
        private(set) var lastStyledRanges: [NSRange] = []

        private struct DocumentKey: Equatable {
            var text: String
            var embeds: [KnowledgeEmbed]
        }

        private struct EmbedVisualState: Equatable {
            var groupID: String
            var lineRange: NSRange
            var lineContentRange: NSRange
            var isCollapsedStandalone: Bool
            var revealedTokenRanges: [NSRange]
            var metrics: KnowledgeInlineEmbedMetrics
        }

        private struct StyleSnapshot {
            var text: String
            var mode: ColorMode
            var typeScale: Double
            var tokens: [KnowledgeSyntaxToken]
            var revealedTokenIndices: Set<Int>
            var embedStates: [EmbedVisualState]
            var findMatches: [NSRange]
            var activeFind: NSRange?
        }

        private struct RenderKey: Equatable {
            var text: String
            var selection: NSRange
            var isFocused: Bool
            var mode: ColorMode
            var typeScale: Double
            var findMatches: [NSRange]
            var activeFind: NSRange?
            var embeds: [KnowledgeEmbed]
            var embedSizes: [String: RoundedSize]
            var containerWidth: Int
            var selectedEmbedID: String?
            var deletableEmbedURLs: Set<String>
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

        func markNeedsFullRestyle() {
            needsFullRestyle = true
        }

        func invalidateSizeIfNeeded(for view: LivePreviewNSTextView) {
            view.invalidateFittingHeightCache()
            guard let previousHeight = view.lastReportedHeight,
                  let width = view.textContainer?.size.width,
                  width.isFinite, width > 1 else {
                view.invalidateIntrinsicContentSize()
                return
            }
            let nextHeight = max(parent.minHeight, view.fittingHeight(width: width))
            if abs(nextHeight - previousHeight) > 0.5 {
                view.invalidateIntrinsicContentSize()
            }
        }

        struct StyleApplyResult {
            var layoutMayHaveChanged: Bool
            var embedLayoutChanged: Bool

            static let unchanged = StyleApplyResult(layoutMayHaveChanged: false, embedLayoutChanged: false)
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            let result = applyStyling(to: view)
            invalidateSizeIfNeeded(for: view)
            if result.embedLayoutChanged {
                scheduleEmbedLayoutNotify()
            }
            parent.onTextChange(view.string, view.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, let view = notification.object as? LivePreviewNSTextView else { return }
            let result = applyStyling(to: view)
            if result.layoutMayHaveChanged {
                invalidateSizeIfNeeded(for: view)
            }
            if result.embedLayoutChanged {
                scheduleEmbedLayoutNotify()
            }
            parent.onSelectionChange(view.selectedRange(), view.isFocusedEditor)
        }

        func handleFocusChange(in view: LivePreviewNSTextView, isFocused: Bool) {
            let result = applyStyling(to: view)
            if result.layoutMayHaveChanged {
                invalidateSizeIfNeeded(for: view)
            }
            if result.embedLayoutChanged {
                scheduleEmbedLayoutNotify()
            }
            parent.onSelectionChange(view.selectedRange(), isFocused)
        }

        func handleEmbedSizeChange(in view: LivePreviewNSTextView) {
            let result = applyStyling(to: view)
            if result.layoutMayHaveChanged {
                invalidateSizeIfNeeded(for: view)
            }
            if result.embedLayoutChanged {
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
            if parent.isCompletionOpen {
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

            guard let view = textView as? LivePreviewNSTextView, !view.hasMarkedText() else {
                return false
            }

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if let res = KnowledgeSmartEditing.handleNewline(in: view.string, selection: view.selectedRange()) {
                    view.applySmartEdit(res)
                    return true
                }
            case #selector(NSResponder.insertTab(_:)):
                if let res = KnowledgeSmartEditing.handleTab(in: view.string, selection: view.selectedRange(), outdent: false) {
                    view.applySmartEdit(res)
                    return true
                }
            case #selector(NSResponder.insertBacktab(_:)):
                if let res = KnowledgeSmartEditing.handleTab(in: view.string, selection: view.selectedRange(), outdent: true) {
                    view.applySmartEdit(res)
                    return true
                }
            case #selector(NSResponder.deleteBackward(_:)):
                if let res = KnowledgeSmartEditing.handleBackspace(in: view.string, selection: view.selectedRange()) {
                    view.applySmartEdit(res)
                    return true
                }
            default:
                break
            }
            return false
        }

        /// Applies live-preview styling incrementally to dirty line ranges and reports whether
        /// fitting height or inline embed layout may have changed.
        @discardableResult
        func applyStyling(to view: LivePreviewNSTextView) -> StyleApplyResult {
            guard let storage = view.textStorage else { return .unchanged }
            let markdown = view.string
            let selection = view.selectedRange()
            let focused = view.isFocusedEditor
            let containerWidth = max(120, view.textContainer?.size.width ?? 600)

            let key = RenderKey(
                text: markdown,
                selection: selection,
                isFocused: focused,
                mode: parent.theme.mode,
                typeScale: parent.theme.typeScale,
                findMatches: parent.findMatches,
                activeFind: parent.activeFindMatchRange,
                embeds: parent.embeds,
                embedSizes: view.measuredEmbedSizes.mapValues(RoundedSize.init),
                containerWidth: Int(ceil(containerWidth)),
                selectedEmbedID: parent.selectedEmbedID,
                deletableEmbedURLs: parent.deletableEmbedURLs
            )
            guard needsFullRestyle || key != lastRenderedKey else { return .unchanged }
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
                needsFullRestyle = false
                lastDocumentKey = nil
                cachedTokens = []
                cachedEmbedGroups = []
                lastSnapshot = nil
                lastStyledRanges = []
                view.cachedTokens = []
                if view.hasMountedEmbeds {
                    view.syncEmbedHosts(
                        groups: [],
                        theme: parent.theme,
                        screenContext: parent.screenContext,
                        containerWidth: containerWidth,
                        selectedEmbedID: parent.selectedEmbedID,
                        deletableEmbedURLs: parent.deletableEmbedURLs
                    )
                }
                view.invalidateFittingHeightCache()
                let embedChanged = view.updateEmbedLayout(groups: [], metricsByID: [:])
                return StyleApplyResult(layoutMayHaveChanged: true, embedLayoutChanged: embedChanged)
            }

            let docKey = DocumentKey(text: markdown, embeds: parent.embeds)
            let tokens: [KnowledgeSyntaxToken]
            let embedGroups: [KnowledgeInlineEmbedParagraph]
            if docKey == lastDocumentKey {
                tokens = cachedTokens
                embedGroups = cachedEmbedGroups
            } else {
                tokens = KnowledgeMarkdownSyntax.scan(markdown)
                embedGroups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(
                    in: markdown,
                    embeds: parent.embeds,
                    tokens: tokens
                )
                cachedTokens = tokens
                cachedEmbedGroups = embedGroups
                lastDocumentKey = docKey
            }
            view.cachedTokens = tokens

            let preview = KnowledgeMarkdownSyntax.livePreview(
                tokens: tokens,
                selection: selection,
                isFocused: focused,
                activeFindMatch: parent.activeFindMatchRange
            )

            if !embedGroups.isEmpty || view.hasMountedEmbeds {
                view.syncEmbedHosts(
                    groups: embedGroups,
                    theme: parent.theme,
                    screenContext: parent.screenContext,
                    containerWidth: containerWidth,
                    selectedEmbedID: parent.selectedEmbedID,
                    deletableEmbedURLs: parent.deletableEmbedURLs
                )
            }

            var metricsByID: [String: KnowledgeInlineEmbedMetrics] = [:]
            var embedStates: [EmbedVisualState] = []
            embedStates.reserveCapacity(embedGroups.count)
            for group in embedGroups {
                var revealedTokenRanges: [NSRange] = []
                for placement in group.placements {
                    if KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
                        for: placement,
                        selection: selection,
                        isFocused: focused,
                        activeFindMatch: parent.activeFindMatchRange
                    ) {
                        revealedTokenRanges.append(placement.tokenRange)
                    }
                }
                let isCollapsedStandalone = group.isStandaloneLine && revealedTokenRanges.isEmpty
                let measured = view.measuredSize(forGroupID: group.id)
                let metrics = KnowledgeInlineEmbedLayout.metrics(
                    measuredSize: measured,
                    isCollapsedStandalone: isCollapsedStandalone
                )
                metricsByID[group.id] = metrics
                embedStates.append(EmbedVisualState(
                    groupID: group.id,
                    lineRange: group.lineRange,
                    lineContentRange: group.lineContentRange,
                    isCollapsedStandalone: isCollapsedStandalone,
                    revealedTokenRanges: revealedTokenRanges,
                    metrics: metrics
                ))
            }

            let nextSnapshot = StyleSnapshot(
                text: markdown,
                mode: parent.theme.mode,
                typeScale: parent.theme.typeScale,
                tokens: tokens,
                revealedTokenIndices: preview.revealedTokenIndices,
                embedStates: embedStates,
                findMatches: parent.findMatches,
                activeFind: parent.activeFindMatchRange
            )

            let dirtyPlan = computeDirtyRanges(
                previous: needsFullRestyle ? nil : lastSnapshot,
                current: nextSnapshot,
                fullLength: fullLength
            )
            needsFullRestyle = false
            lastSnapshot = nextSnapshot

            let dirtyRanges = dirtyPlan.ranges
            lastStyledRanges = dirtyRanges

            if dirtyRanges.isEmpty {
                skippedSelectionRestyleCount += 1
                let embedLayoutChanged = view.updateEmbedLayout(groups: embedGroups, metricsByID: metricsByID)
                lastRenderedKey?.embedSizes = view.measuredEmbedSizes.mapValues(RoundedSize.init)
                return StyleApplyResult(layoutMayHaveChanged: embedLayoutChanged, embedLayoutChanged: embedLayoutChanged)
            }

            if dirtyPlan.isFullDocument {
                fullRestyleCount += 1
            } else {
                incrementalRestyleCount += 1
            }

            let dirtyMin = dirtyRanges.first!.location
            let dirtyMax = dirtyRanges.last!.location + dirtyRanges.last!.length

            storage.beginEditing()
            for dirty in dirtyRanges {
                storage.setAttributes(baseAttrs, range: dirty)
            }

            // 1. Style token content ranges intersecting `dirtyRanges`.
            for token in preview.tokens {
                let tokenEnd = token.range.location + token.range.length
                if tokenEnd <= dirtyMin { continue }
                if token.range.location >= dirtyMax { break }
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
                    let font = NSFont.systemFont(ofSize: baseSize * scale, weight: weight)
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttribute(.font, value: font, range: sub)
                    }

                case .bold:
                    let font = NSFont.systemFont(ofSize: baseSize, weight: .semibold)
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttribute(.font, value: font, range: sub)
                    }

                case .italic:
                    let font = italicFont(size: baseSize, bold: false)
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttribute(.font, value: font, range: sub)
                    }

                case .boldItalic:
                    let font = italicFont(size: baseSize, bold: true)
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttribute(.font, value: font, range: sub)
                    }

                case .strikethrough:
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: secondaryColor,
                        ], range: sub)
                    }

                case .inlineCode:
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .font: monoFont,
                            .backgroundColor: codeBg,
                        ], range: sub)
                    }

                case .fencedCodeBlock:
                    for sub in clippedToDirty(token.range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .font: monoFont,
                            .backgroundColor: codeBg,
                        ], range: sub)
                    }

                case .blockquote:
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttribute(.foregroundColor, value: secondaryColor, range: sub)
                    }

                case .listItem(_, let checked):
                    if checked == true {
                        for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                            storage.addAttributes([
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .foregroundColor: secondaryColor,
                            ], range: sub)
                        }
                    }

                case .frontmatter:
                    for sub in clippedToDirty(token.range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .font: monoFont,
                            .foregroundColor: tertiaryColor,
                        ], range: sub)
                    }

                case .wikiLink(let target):
                    var linkAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: accentColor.withAlphaComponent(0.45),
                    ]
                    if !target.target.isEmpty {
                        linkAttrs[.toolTip] = target.target
                    }
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes(linkAttrs, range: sub)
                    }

                case .embed:
                    for sub in clippedToDirty(token.contentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .foregroundColor: accentColor,
                            .backgroundColor: tagBg,
                        ], range: sub)
                    }

                case .tag:
                    let font = NSFont.systemFont(ofSize: max(11, baseSize - 1), weight: .medium)
                    for sub in clippedToDirty(token.range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .foregroundColor: accentColor,
                            .backgroundColor: tagBg,
                            .font: font,
                        ], range: sub)
                    }

                case .blockID:
                    let font = NSFont.monospacedSystemFont(ofSize: max(10, baseSize - 2), weight: .regular)
                    for sub in clippedToDirty(token.range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes([
                            .foregroundColor: tertiaryColor,
                            .backgroundColor: blockBg,
                            .font: font,
                        ], range: sub)
                    }
                }
            }

            // 2. Style revealed syntax delimiters as muted syntax markers.
            for range in preview.revealedRanges {
                for sub in clippedToDirty(range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                    storage.addAttribute(.foregroundColor, value: tertiaryColor, range: sub)
                }
            }

            // 3. Hide unrevealed syntax delimiters while preserving exact UTF-16 backing offsets.
            let hiddenFont = NSFont.systemFont(ofSize: 0.01)
            let hiddenAttrs: [NSAttributedString.Key: Any] = [
                .font: hiddenFont,
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
            ]
            for range in preview.hiddenRanges {
                for sub in clippedToDirty(range, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                    storage.addAttributes(hiddenAttrs, range: sub)
                }
            }

            // 4. Reserve inline paragraph spacing for resolved embeds and hide unedited embed tokens.
            for (group, state) in zip(embedGroups, embedStates) {
                let groupEnd = group.lineRange.location + group.lineRange.length
                guard groupEnd > dirtyMin && group.lineRange.location < dirtyMax else { continue }
                let revealedSet = Set(state.revealedTokenRanges)

                if state.isCollapsedStandalone {
                    for sub in clippedToDirty(group.lineContentRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                        storage.addAttributes(hiddenAttrs, range: sub)
                    }
                } else {
                    for placement in group.placements {
                        if revealedSet.contains(placement.tokenRange) {
                            for sub in clippedToDirty(placement.tokenRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                                storage.addAttribute(.font, value: baseFont, range: sub)
                            }
                            if let tok = preview.tokens.first(where: { $0.range == placement.tokenRange }) {
                                for delim in tok.syntaxRanges {
                                    for sub in clippedToDirty(delim, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                                        storage.addAttribute(.foregroundColor, value: tertiaryColor, range: sub)
                                    }
                                }
                            }
                        } else {
                            for sub in clippedToDirty(placement.tokenRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                                storage.addAttributes(hiddenAttrs, range: sub)
                            }
                        }
                    }
                }

                let embedParaStyle = NSMutableParagraphStyle()
                embedParaStyle.lineSpacing = state.isCollapsedStandalone ? 0 : parent.theme.lineSpacing(.body)
                if state.isCollapsedStandalone {
                    embedParaStyle.maximumLineHeight = KnowledgeInlineEmbedLayout.collapsedStandaloneLineHeight
                }
                embedParaStyle.paragraphSpacing = state.metrics.reservedSpacing
                for sub in clippedToDirty(group.lineRange, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                    storage.addAttribute(.paragraphStyle, value: embedParaStyle, range: sub)
                }
            }

            // 5. Overlay unified ⌘F find highlights.
            for match in parent.findMatches {
                let isActive = (parent.activeFindMatchRange == match)
                let bg = isActive ? findActiveBg : findMatchBg
                for sub in clippedToDirty(match, dirtyRanges: dirtyRanges, fullLength: fullLength) {
                    storage.addAttribute(.backgroundColor, value: bg, range: sub)
                }
            }

            storage.endEditing()

            view.invalidateFittingHeightCache()
            let embedLayoutChanged = view.updateEmbedLayout(groups: embedGroups, metricsByID: metricsByID)
            // Keep RenderKey in sync with any newly created host's initial measured size.
            lastRenderedKey?.embedSizes = view.measuredEmbedSizes.mapValues(RoundedSize.init)
            return StyleApplyResult(
                layoutMayHaveChanged: embedLayoutChanged || dirtyPlan.mayChangeLayoutHeight,
                embedLayoutChanged: embedLayoutChanged
            )
        }

        private struct DirtyPlan {
            var ranges: [NSRange]
            var isFullDocument: Bool
            var mayChangeLayoutHeight: Bool
        }

        private func computeDirtyRanges(
            previous: StyleSnapshot?,
            current: StyleSnapshot,
            fullLength: Int
        ) -> DirtyPlan {
            let fullRange = NSRange(location: 0, length: fullLength)
            guard let previous, previous.mode == current.mode, previous.typeScale == current.typeScale else {
                return DirtyPlan(ranges: [fullRange], isFullDocument: true, mayChangeLayoutHeight: true)
            }

            // Selection / focus / find / embed-size update with identical markdown text.
            if previous.text == current.text {
                if previous.revealedTokenIndices == current.revealedTokenIndices
                    && previous.embedStates == current.embedStates
                    && previous.findMatches == current.findMatches
                    && previous.activeFind == current.activeFind {
                    return DirtyPlan(ranges: [], isFullDocument: false, mayChangeLayoutHeight: false)
                }

                var rawRanges: [NSRange] = []
                var mayChangeHeight = false

                let changedReveal = previous.revealedTokenIndices.symmetricDifference(current.revealedTokenIndices)
                for idx in changedReveal where idx < current.tokens.count {
                    let tok = current.tokens[idx]
                    mayChangeHeight = true
                    if isMultiLineToken(tok.kind) {
                        for delim in tok.syntaxRanges {
                            rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: delim, in: current.text))
                        }
                    } else {
                        rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: tok.range, in: current.text))
                    }
                }

                if previous.embedStates != current.embedStates {
                    mayChangeHeight = true
                    let prevByID = Dictionary(previous.embedStates.map { ($0.groupID, $0) }, uniquingKeysWith: { _, latest in latest })
                    let currByID = Dictionary(current.embedStates.map { ($0.groupID, $0) }, uniquingKeysWith: { _, latest in latest })
                    for id in Set(prevByID.keys).union(currByID.keys) where prevByID[id] != currByID[id] {
                        if let oldState = prevByID[id] {
                            rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: oldState.lineRange, in: current.text))
                        }
                        if let newState = currByID[id] {
                            rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: newState.lineRange, in: current.text))
                        }
                    }
                }

                if previous.findMatches != current.findMatches || previous.activeFind != current.activeFind {
                    let prevSet = Set(previous.findMatches)
                    let currSet = Set(current.findMatches)
                    for r in prevSet.symmetricDifference(currSet) {
                        rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: r, in: current.text))
                    }
                    if previous.activeFind != current.activeFind {
                        if let oldActive = previous.activeFind {
                            rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: oldActive, in: current.text))
                        }
                        if let newActive = current.activeFind {
                            rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: newActive, in: current.text))
                        }
                    }
                }

                return DirtyPlan(
                    ranges: mergeRanges(rawRanges, maxLength: fullLength),
                    isFullDocument: false,
                    mayChangeLayoutHeight: mayChangeHeight
                )
            }

            // Text changed: compute minimal edited line span + any cross-line state transitions.
            guard let delta = KnowledgeMarkdownSyntax.minimalEditDelta(from: previous.text, to: current.text) else {
                return DirtyPlan(ranges: [fullRange], isFullDocument: true, mayChangeLayoutHeight: true)
            }

            let editStart = delta.oldRange.location
            let editEndOld = delta.oldRange.location + delta.oldRange.length
            let editEndNew = delta.newRange.location + delta.newRange.length
            let shift = delta.newRange.length - delta.oldRange.length

            func mapOldRange(_ oldRange: NSRange) -> NSRange {
                let oldStart = oldRange.location
                let oldEnd = oldRange.location + oldRange.length
                let newStart: Int
                if oldStart <= editStart {
                    newStart = oldStart
                } else if oldStart >= editEndOld {
                    newStart = oldStart + shift
                } else {
                    newStart = editStart
                }
                let newEnd: Int
                if oldEnd <= editStart {
                    newEnd = oldEnd
                } else if oldEnd >= editEndOld {
                    newEnd = oldEnd + shift
                } else {
                    newEnd = editEndNew
                }
                let clampedStart = max(0, min(newStart, fullLength))
                let clampedEnd = max(clampedStart, min(newEnd, fullLength))
                return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
            }

            var rawRanges: [NSRange] = [
                KnowledgeMarkdownSyntax.lineSpan(covering: delta.newRange, in: current.text)
            ]

            // 1. Multi-line blocks (frontmatter, fenced code blocks): if boundaries/kinds changed, restyle affected span.
            struct MultiLineKey: Hashable {
                var kind: KnowledgeSyntaxKind
                var range: NSRange
            }
            let prevMulti = previous.tokens.filter { isMultiLineToken($0.kind) }.map {
                MultiLineKey(kind: $0.kind, range: mapOldRange($0.range))
            }
            let currMulti = current.tokens.filter { isMultiLineToken($0.kind) }.map {
                MultiLineKey(kind: $0.kind, range: $0.range)
            }
            if prevMulti != currMulti {
                let prevSet = Set(prevMulti)
                let currSet = Set(currMulti)
                for item in prevSet.symmetricDifference(currSet) {
                    rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: item.range, in: current.text))
                }
            }

            // 2. Revealed syntax tokens on other lines (e.g. selection moved across lines during edit).
            struct RevealedKey: Hashable {
                var kind: KnowledgeSyntaxKind
                var range: NSRange
                var syntaxRanges: [NSRange]
            }
            let prevRevealed = Set(previous.revealedTokenIndices.compactMap { idx -> RevealedKey? in
                guard idx < previous.tokens.count else { return nil }
                let tok = previous.tokens[idx]
                return RevealedKey(kind: tok.kind, range: mapOldRange(tok.range), syntaxRanges: tok.syntaxRanges.map(mapOldRange))
            })
            let currRevealed = Set(current.revealedTokenIndices.compactMap { idx -> RevealedKey? in
                guard idx < current.tokens.count else { return nil }
                let tok = current.tokens[idx]
                return RevealedKey(kind: tok.kind, range: tok.range, syntaxRanges: tok.syntaxRanges)
            })
            for item in prevRevealed.symmetricDifference(currRevealed) {
                if isMultiLineToken(item.kind) {
                    for delim in item.syntaxRanges {
                        rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: delim, in: current.text))
                    }
                } else {
                    rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: item.range, in: current.text))
                }
            }

            // 3. Embed paragraph visual state changes outside the edited line.
            let mappedPrevEmbeds = Dictionary(previous.embedStates.map { state in
                let mapped = EmbedVisualState(
                    groupID: state.groupID,
                    lineRange: mapOldRange(state.lineRange),
                    lineContentRange: mapOldRange(state.lineContentRange),
                    isCollapsedStandalone: state.isCollapsedStandalone,
                    revealedTokenRanges: state.revealedTokenRanges.map(mapOldRange),
                    metrics: state.metrics
                )
                return (mapped.groupID, mapped)
            }, uniquingKeysWith: { _, latest in latest })
            let currEmbeds = Dictionary(current.embedStates.map { ($0.groupID, $0) }, uniquingKeysWith: { _, latest in latest })
            for id in Set(mappedPrevEmbeds.keys).union(currEmbeds.keys) where mappedPrevEmbeds[id] != currEmbeds[id] {
                if let oldState = mappedPrevEmbeds[id] {
                    rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: oldState.lineRange, in: current.text))
                }
                if let newState = currEmbeds[id] {
                    rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: newState.lineRange, in: current.text))
                }
            }

            // 4. Find match highlights that shifted or changed.
            if !previous.findMatches.isEmpty || !current.findMatches.isEmpty {
                let mappedPrevMatches = Set(previous.findMatches.map(mapOldRange))
                let currMatches = Set(current.findMatches)
                for r in mappedPrevMatches.symmetricDifference(currMatches) {
                    rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: r, in: current.text))
                }
                let mappedPrevActive = previous.activeFind.map(mapOldRange)
                if mappedPrevActive != current.activeFind {
                    if let oldActive = mappedPrevActive {
                        rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: oldActive, in: current.text))
                    }
                    if let newActive = current.activeFind {
                        rawRanges.append(KnowledgeMarkdownSyntax.lineSpan(covering: newActive, in: current.text))
                    }
                }
            }

            let merged = mergeRanges(rawRanges, maxLength: fullLength)
            let isFull = merged.count == 1 && merged[0].location == 0 && merged[0].length == fullLength
            return DirtyPlan(ranges: merged, isFullDocument: isFull, mayChangeLayoutHeight: true)
        }

        private func isMultiLineToken(_ kind: KnowledgeSyntaxKind) -> Bool {
            switch kind {
            case .fencedCodeBlock, .frontmatter:
                return true
            default:
                return false
            }
        }

        private func mergeRanges(_ ranges: [NSRange], maxLength: Int) -> [NSRange] {
            let clamped = ranges.compactMap { clamped($0, length: maxLength) }
            guard clamped.count > 1 else { return clamped }
            let sorted = clamped.sorted { $0.location < $1.location }
            var merged: [NSRange] = [sorted[0]]
            for next in sorted.dropFirst() {
                let last = merged[merged.count - 1]
                let lastEnd = last.location + last.length
                if next.location <= lastEnd {
                    let newEnd = max(lastEnd, next.location + next.length)
                    merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
                } else {
                    merged.append(next)
                }
            }
            return merged
        }

        private func clippedToDirty(_ range: NSRange, dirtyRanges: [NSRange], fullLength: Int) -> [NSRange] {
            guard let safe = clamped(range, length: fullLength) else { return [] }
            let safeEnd = safe.location + safe.length
            var result: [NSRange] = []
            for dirty in dirtyRanges {
                let dirtyEnd = dirty.location + dirty.length
                if dirtyEnd <= safe.location { continue }
                if dirty.location >= safeEnd { break }
                let start = max(safe.location, dirty.location)
                let end = min(safeEnd, dirtyEnd)
                if end > start {
                    result.append(NSRange(location: start, length: end - start))
                }
            }
            return result
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
        var lastPlacements: [KnowledgeInlineEmbedPlacement]
        var lastMaxWidth: CGFloat
        var lastThemeMode: ColorMode
        var lastSelectedEmbedID: String?
        var lastDeletableEmbedURLs: Set<String>

        init(
            id: String,
            hostView: NSHostingView<AnyView>,
            measuredSize: CGSize,
            lastPlacements: [KnowledgeInlineEmbedPlacement],
            lastMaxWidth: CGFloat,
            lastThemeMode: ColorMode,
            lastSelectedEmbedID: String?,
            lastDeletableEmbedURLs: Set<String>
        ) {
            self.id = id
            self.hostView = hostView
            self.measuredSize = measuredSize
            self.lastPlacements = lastPlacements
            self.lastMaxWidth = lastMaxWidth
            self.lastThemeMode = lastThemeMode
            self.lastSelectedEmbedID = lastSelectedEmbedID
            self.lastDeletableEmbedURLs = lastDeletableEmbedURLs
        }
    }

    private let contentStorage = NSTextContentStorage()
    var cachedTokens: [KnowledgeSyntaxToken] = []
    var onCommandClickLink: ((KnowledgeWikiTarget) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onEmbedSizeChange: (() -> Void)?
    var onDropFiles: (([URL], Int) -> Void)?
    var onFileDragActiveChange: ((Bool) -> Void)?
    var onPasteFiles: (([URL], NSRange) -> Void)?
    var onPasteImageData: ((Data, String, NSRange) -> Void)?
    var onDropKnowledgeItem: ((KnowledgeDragItem, Int, Bool) -> Void)?
    var onKnowledgeDragActiveChange: ((KnowledgeDragItem?) -> Void)?
    var onResizeImage: ((KnowledgeInlineEmbedPlacement, Int?) -> Void)?
    var onSelectEmbed: ((KnowledgeInlineEmbedPlacement?) -> Void)?
    var onRemoveEmbed: ((KnowledgeInlineEmbedPlacement) -> Void)?
    var onDeleteAttachment: ((KnowledgeInlineEmbedPlacement) -> Void)?
    private(set) var isFocusedEditor = false

    private var embedHosts: [String: MountedEmbedHost] = [:]
    private var activeEmbedGroups: [KnowledgeInlineEmbedParagraph] = []
    private var activeEmbedMetrics: [String: KnowledgeInlineEmbedMetrics] = [:]
    private var activeEmbedFrames: [KnowledgeInlineEmbedFrame] = []
    private var cachedFittingHeight: (width: CGFloat, height: CGFloat)?
    private(set) var lastReportedHeight: CGFloat?
    private(set) var layoutMeasurementCount = 0

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
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFocusedEditor = true
            onSelectEmbed?(nil)
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

    // MARK: - Smart Editing & Clipboard Paste

    func applySmartEdit(_ result: KnowledgeMarkdownFormatting.EditResult) {
        guard let delta = KnowledgeMarkdownSyntax.minimalEditDelta(from: string, to: result.text) else {
            setSelectedRange(result.selection)
            return
        }
        let replacement = (result.text as NSString).substring(with: delta.newRange)
        guard shouldChangeText(in: delta.oldRange, replacementString: replacement) else { return }
        replaceCharacters(in: delta.oldRange, with: replacement)
        let newLen = (string as NSString).length
        let loc = max(0, min(result.selection.location, newLen))
        let len = max(0, min(result.selection.length, newLen - loc))
        setSelectedRange(NSRange(location: loc, length: len))
        didChangeText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !hasMarkedText(),
           replacementRange.location == NSNotFound,
           let raw: String = (insertString as? String) ?? (insertString as? NSAttributedString)?.string,
           raw.count == 1,
           let res = KnowledgeSmartEditing.handleTypedText(raw, in: string, selection: selectedRange()) {
            applySmartEdit(res)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let range = selectedRange()

        // 1. Copied Finder files (`Cmd+C` in Finder) take precedence over icon TIFFs and filenames.
        let fileURLs = readFileURLs(from: pb)
        if !fileURLs.isEmpty {
            onPasteFiles?(fileURLs, range)
            return
        }

        // 2. Screenshots (`Cmd+Ctrl+Shift+4`) and copied images.
        if let (imageData, filename) = extractClipboardImage(from: pb) {
            onPasteImageData?(imageData, filename, range)
            return
        }

        // 3. Pasting a URL over selected text turns it into `[phrase](url)`.
        if range.length > 0,
           let pastedText = pb.string(forType: .string),
           let res = KnowledgeMarkdownFormatting.pasteURLOverSelection(
               text: string,
               selection: range,
               pastedString: pastedText
           ) {
            applySmartEdit(res)
            return
        }

        pasteAsPlainText(sender)
    }

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objs = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return objs.filter(\.isFileURL)
    }

    private func extractClipboardImage(from pasteboard: NSPasteboard) -> (Data, String)? {
        let explicitTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"),
        ]
        for (pbType, ext) in explicitTypes {
            if let data = pasteboard.data(forType: pbType), !data.isEmpty {
                return (data, KnowledgeMarkdownFormatting.screenshotFilename(extension: ext))
            }
        }
        // Fallback for apps that copy TIFF-only images (e.g. Safari/Preview Copy Image).
        // Skip TIFF if non-URL plain text is also on the pasteboard so rich-text copies paste as text.
        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
            let plain = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let plainIsIgnorable = plain.isEmpty || KnowledgeMarkdownFormatting.pastableURL(from: plain) != nil
            if plainIsIgnorable,
               let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]),
               !pngData.isEmpty {
                return (pngData, KnowledgeMarkdownFormatting.screenshotFilename(extension: "png"))
            }
        }
        return nil
    }

    // MARK: - Finder File & Sidebar Knowledge Drag & Drop

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        readFileURLs(from: sender.draggingPasteboard)
    }

    private func draggedKnowledgeItem(from sender: NSDraggingInfo) -> KnowledgeDragItem? {
        guard let raw = sender.draggingPasteboard.string(forType: .string),
              let item = KnowledgeDragItem.decodeDragPayload(raw),
              item.kind == .page || item.kind == .attachment else {
            return nil
        }
        return item
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !draggedFileURLs(from: sender).isEmpty {
            onFileDragActiveChange?(true)
            return .copy
        }
        if let item = draggedKnowledgeItem(from: sender) {
            onKnowledgeDragActiveChange?(item)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !draggedFileURLs(from: sender).isEmpty {
            return .copy
        }
        if draggedKnowledgeItem(from: sender) != nil {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragActiveChange?(false)
        onKnowledgeDragActiveChange?(nil)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !draggedFileURLs(from: sender).isEmpty || draggedKnowledgeItem(from: sender) != nil {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let rawOffset = characterIndexForInsertion(at: point)
        let maxLen = (string as NSString).length
        let clampedOffset = rawOffset == NSNotFound ? maxLen : max(0, min(rawOffset, maxLen))

        let urls = draggedFileURLs(from: sender)
        if !urls.isEmpty {
            onFileDragActiveChange?(false)
            onDropFiles?(urls, clampedOffset)
            return true
        }
        if let item = draggedKnowledgeItem(from: sender) {
            onKnowledgeDragActiveChange?(nil)
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            onDropKnowledgeItem?(item, clampedOffset, optionHeld)
            return true
        }
        return super.performDragOperation(sender)
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
        invalidateFittingHeightCache()
        return true
    }

    func invalidateFittingHeightCache() {
        cachedFittingHeight = nil
    }

    func noteReportedHeight(_ height: CGFloat) {
        lastReportedHeight = height
    }

    /// Reconciles mounted `NSHostingView` subviews with `groups`, reusing views across unrelated prose edits.
    func syncEmbedHosts(
        groups: [KnowledgeInlineEmbedParagraph],
        theme: ThemeTokens,
        screenContext: NativeScreenContext,
        containerWidth: CGFloat,
        selectedEmbedID: String?,
        deletableEmbedURLs: Set<String>
    ) {
        let maxWidth = max(120, containerWidth)
        let activeIDs = Set(groups.map(\.id))

        for (id, host) in embedHosts where !activeIDs.contains(id) {
            host.hostView.removeFromSuperview()
            embedHosts.removeValue(forKey: id)
        }

        for group in groups {
            let rootView = AnyView(
                KnowledgeInlineEmbedGroupView(
                    placements: group.placements,
                    maxWidth: maxWidth,
                    fillsWidth: group.fillsContainerWidth,
                    selectedEmbedID: selectedEmbedID,
                    onSelectEmbed: { [weak self] placement in
                        self?.onSelectEmbed?(placement)
                    },
                    onResizeImage: { [weak self] placement, width in
                        self?.onResizeImage?(placement, width)
                    },
                    onRemoveEmbed: { [weak self] placement in
                        self?.onRemoveEmbed?(placement)
                    },
                    canDeleteAttachment: { placement in
                        guard let url = placement.embed.url, !url.isEmpty else { return false }
                        return deletableEmbedURLs.contains(url)
                    },
                    onDeleteAttachment: { [weak self] placement in
                        self?.onDeleteAttachment?(placement)
                    },
                    onSizeChange: { [weak self] newSize in
                        self?.handleMeasuredSize(newSize, forGroupID: group.id)
                    }
                )
                .environment(screenContext)
                .environment(\.vesperTheme, theme)
            )

            if let existing = embedHosts[group.id] {
                let needsRootUpdate = existing.lastPlacements != group.placements
                    || abs(existing.lastMaxWidth - maxWidth) > 0.5
                    || existing.lastThemeMode != theme.mode
                    || existing.lastSelectedEmbedID != selectedEmbedID
                    || existing.lastDeletableEmbedURLs != deletableEmbedURLs
                if needsRootUpdate {
                    existing.hostView.rootView = rootView
                    existing.lastPlacements = group.placements
                    existing.lastMaxWidth = maxWidth
                    existing.lastThemeMode = theme.mode
                    existing.lastSelectedEmbedID = selectedEmbedID
                    existing.lastDeletableEmbedURLs = deletableEmbedURLs
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
                    lastPlacements: group.placements,
                    lastMaxWidth: maxWidth,
                    lastThemeMode: theme.mode,
                    lastSelectedEmbedID: selectedEmbedID,
                    lastDeletableEmbedURLs: deletableEmbedURLs
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

        let frameByID = Dictionary(frames.map { ($0.groupID, $0.frame) }, uniquingKeysWith: { _, latest in latest })
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
    /// Cached per rounded width so repeated SwiftUI `sizeThatFits` probes don't re-run full-document layout.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let rounded = width.rounded()
        if let cached = cachedFittingHeight, cached.width == rounded {
            return cached.height
        }
        guard let layoutManager = textLayoutManager, let container = textContainer else { return 28 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutMeasurementCount += 1
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutEmbedViews()
        let height = KnowledgeInlineEmbedLayout.totalFittingHeight(
            usageBoundsHeight: layoutManager.usageBoundsForTextContainer.height,
            embedFrames: activeEmbedFrames,
            verticalInset: textContainerInset.height
        )
        cachedFittingHeight = (rounded, height)
        return height
    }
}
