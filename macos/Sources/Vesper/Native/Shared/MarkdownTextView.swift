import AppKit
import VesperCore

/// Screen-space anchor of a clicked link inside `MarkdownTextView`, used to attach floating
/// popovers or bubbles directly to the clicked inline badge (e.g. a `[1]` citation pill).
@MainActor
struct MarkdownLinkAnchor {
    let screenRect: CGRect
    weak var window: NSWindow?
}

/// Rendered markdown in a TextKit 2 text view: selectable, with Look Up, the context menu's
/// Copy and Services, link clicks, and the boxes, rules and quote bars `MarkdownDecoration`
/// describes drawn behind the text. Not editable and not scrollable: it is as tall as its text,
/// inside the screen's own scroll view.
@MainActor
final class MarkdownTextView: NSTextView, NSTextViewDelegate, NSTextLayoutManagerDelegate {
    private let contentStorage = NSTextContentStorage()
    /// Called with each link the person clicks, whether ⌘ was held (open in a new tab), and the
    /// link's screen-space anchor rect when available.
    var onLink: ((MarkdownLinkTarget, _ newTab: Bool, _ anchor: MarkdownLinkAnchor?) -> Void)?
    /// Called when the person triggers a selection action (Quote, Thread, Explain, Clip) on highlighted text.
    var onSelectionAction: (@MainActor (ChatSelectionAction, String) -> Void)?
    var selectionTheme: ThemeTokens = ThemeTokens(mode: .light)
    private struct CachedHuggedSize {
        var laidOutMaxWidth: CGFloat
        var size: CGSize
        var singleLine: Bool
    }

    private(set) var rendering: MarkdownRendering?
    private(set) var layoutPassCount = 0
    private var findRanges: [NSRange] = []
    private var cachedHeight: (width: CGFloat, height: CGFloat, singleLineWidth: CGFloat?)?
    private var cachedHuggedSize: CachedHuggedSize?
    private var appliedTabStopWidth: CGFloat?
    private var renderVersion: UInt64 = 0
    private var lastFind: (version: UInt64, query: String, caseSensitive: Bool, isCurrent: Bool)?

    init() {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        layoutManager.delegate = self
        delegate = self
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // Colours come from the text itself (accent links, tertiary ghosts), not one link style.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        isAutomaticLinkDetectionEnabled = false
        // The window's find bar searches native screens; the text view's own would be a second one.
        usesFindBar = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ rendering: MarkdownRendering, renderedWidth: CGFloat? = nil) {
        self.rendering = rendering
        renderVersion &+= 1
        cachedHeight = nil
        cachedHuggedSize = nil
        appliedTabStopWidth = renderedWidth?.rounded()
        lastFind = nil
        textStorage?.setAttributedString(rendering.text)
        if !findRanges.isEmpty {
            applyFindHighlights()
        }
    }

    /// Updates width-dependent right-aligned tab stops (e.g. chat code-fence "Copy" headers)
    /// in place without rebuilding `NSAttributedString` or replacing `textStorage`.
    func updateRightTabStops(forWidth width: CGFloat) {
        guard let stops = rendering?.rightTabStops, !stops.isEmpty, let storage = textStorage else { return }
        let rounded = width.rounded()
        guard appliedTabStopWidth != rounded else { return }
        appliedTabStopWidth = rounded
        let totalLength = storage.length
        storage.beginEditing()
        for stop in stops {
            guard stop.range.location >= 0,
                  stop.range.location + stop.range.length <= totalLength,
                  stop.range.length > 0 else { continue }
            let existing = storage.attribute(.paragraphStyle, at: stop.range.location, effectiveRange: nil) as? NSParagraphStyle
            let updated = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            updated.tabStops = [NSTextTab(textAlignment: .right, location: max(stop.minLocation, width - stop.trailingInset))]
            storage.addAttribute(.paragraphStyle, value: updated, range: stop.range)
        }
        storage.endEditing()
        cachedHeight = nil
        cachedHuggedSize = nil
    }

    /// The height the text needs at `width`. Cached per rounded width (and across wider widths for
    /// single-line paragraphs without trailing tab stops) and invalidated by `show(_:)` so repeated
    /// SwiftUI `sizeThatFits` probes and split-view resizes skip redundant TextKit 2 full-document layouts.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let rounded = width.rounded()
        if let cached = cachedHeight {
            if cached.width == rounded {
                return cached.height
            }
            if let minWidth = cached.singleLineWidth, rounded >= minWidth {
                return cached.height
            }
        }
        guard let layoutManager = textLayoutManager, let container = textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutPassCount &+= 1
        let height = ceil(layoutManager.usageBoundsForTextContainer.height)
        var singleLineWidth: CGFloat?
        if rendering?.rightTabStops.isEmpty ?? true {
            var lineCount = 0
            var maxX: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location,
                options: []
            ) { fragment in
                for line in fragment.textLineFragments {
                    lineCount += 1
                    maxX = max(maxX, line.typographicBounds.maxX)
                    if lineCount > 1 { return false }
                }
                return true
            }
            if lineCount <= 1, maxX > 0 {
                singleLineWidth = ceil(maxX) + 2
            }
        }
        cachedHeight = (rounded, height, singleLineWidth)
        return height
    }

    /// Natural text bounds up to `maxWidth`: lets short user chat bubbles hug their text width
    /// instead of stretching to the maximum bubble column width. Reuses the cached measurement
    /// when SwiftUI re-probes at the hugged width (or any width between natural width and the
    /// laid-out max width) to avoid double-probe relayout thrash.
    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let rounded = maxWidth.rounded()
        if let cached = cachedHuggedSize {
            if cached.laidOutMaxWidth == rounded {
                return cached.size
            }
            if cached.singleLine && rounded >= cached.size.width {
                return cached.size
            }
            if !cached.singleLine && rounded >= cached.size.width && rounded <= cached.laidOutMaxWidth {
                return cached.size
            }
        }
        guard let layoutManager = textLayoutManager, let container = textContainer else {
            return CGSize(width: maxWidth, height: 0)
        }
        if abs(container.size.width - maxWidth) > 0.5 {
            container.size = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutPassCount &+= 1
        let height = ceil(layoutManager.usageBoundsForTextContainer.height)
        var widest: CGFloat = 0
        var lineCount = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            for line in fragment.textLineFragments {
                lineCount += 1
                widest = max(widest, line.typographicBounds.maxX)
            }
            return true
        }
        let naturalWidth = widest > 0 ? min(maxWidth, ceil(widest) + 2) : maxWidth
        let size = CGSize(width: naturalWidth, height: height)
        cachedHuggedSize = CachedHuggedSize(
            laidOutMaxWidth: rounded,
            size: size,
            singleLine: lineCount <= 1
        )
        return size
    }

    // MARK: Find

    /// Tints every match of the find bar's query; on the current row, the first match more strongly,
    /// scrolled into view.
    func highlight(query: String, caseSensitive: Bool, isCurrent: Bool, match: NSColor, current: NSColor) {
        if query.isEmpty && findRanges.isEmpty {
            lastFind = (renderVersion, query, caseSensitive, isCurrent)
            return
        }
        if let last = lastFind,
           last.version == renderVersion,
           last.query == query,
           last.caseSensitive == caseSensitive,
           last.isCurrent == isCurrent {
            return
        }
        let wasCurrent = findStyle.isCurrent
        let ranges = query.isEmpty ? [] : MarkdownFind.ranges(of: query, in: string, caseSensitive: caseSensitive)
        findStyle = (match, current, isCurrent)
        lastFind = (renderVersion, query, caseSensitive, isCurrent)
        guard ranges != findRanges || wasCurrent != isCurrent else { return }
        findRanges = ranges
        applyFindHighlights()
        if isCurrent, let first = ranges.first { scrollRangeToVisible(first) }
    }

    private var findStyle: (match: NSColor, current: NSColor, isCurrent: Bool) = (.clear, .clear, false)

    private func applyFindHighlights() {
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        for (i, range) in findRanges.enumerated() {
            guard let textRange = textRange(range) else { continue }
            let color = findStyle.isCurrent && i == 0 ? findStyle.current : findStyle.match
            layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
        }
    }

    private func textRange(_ range: NSRange) -> NSTextRange? {
        let start = contentStorage.documentRange.location
        guard range.location + range.length <= (string as NSString).length,
              let from = contentStorage.location(start, offsetBy: range.location),
              let to = contentStorage.location(from, offsetBy: range.length) else { return nil }
        return NSTextRange(location: from, end: to)
    }

    /// Scrolls the enclosing scroll view to a character (a heading or footnote).
    func reveal(location: Int) {
        let length = (string as NSString).length
        guard location <= length else { return }
        scrollRangeToVisible(NSRange(location: location, length: min(1, length - location)))
        setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: Links

    /// Computes the screen-space bounding rect of the link run at `charIndex` via TextKit 2.
    func linkAnchor(at charIndex: Int) -> MarkdownLinkAnchor? {
        let totalLength = (string as NSString).length
        guard totalLength > 0 else { return nil }
        let clamped = min(max(charIndex, 0), totalLength - 1)
        var effective = NSRange(location: clamped, length: 1)
        if let storage = textStorage, storage.length == totalLength {
            var range = NSRange(location: 0, length: 0)
            if storage.attribute(.link, at: clamped, effectiveRange: &range) != nil, range.length > 0 {
                effective = range
            }
        }

        var localRect = CGRect.null
        if let layoutManager = textLayoutManager, let tr = textRange(effective) {
            layoutManager.ensureLayout(for: tr)
            let origin = textContainerOrigin
            layoutManager.enumerateTextSegments(in: tr, type: .standard, options: []) { _, segmentFrame, _, _ in
                let shifted = segmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                localRect = localRect.isNull ? shifted : localRect.union(shifted)
                return true
            }
        }

        if let window, !localRect.isNull, !localRect.isEmpty {
            let inWindow = convert(localRect, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            return MarkdownLinkAnchor(screenRect: inScreen, window: window)
        }
        let mouse = NSEvent.mouseLocation
        return MarkdownLinkAnchor(
            screenRect: CGRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16),
            window: window
        )
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let target = MarkdownLinkTarget(url: url) else { return true }
        switch target {
        // In-page jumps: a heading, a footnote, back to its reference.
        case .anchor(let id): rendering?.anchors[id].map(reveal(location:))
        case .footnote(let n): rendering?.footnotes[n].map(reveal(location:))
        case .footnoteReference(let n): rendering?.footnoteReferences[n].map(reveal(location:))
        default:
            let anchor = linkAnchor(at: charIndex)
            onLink?(target, NSApp.currentEvent?.modifierFlags.contains(.command) == true, anchor)
        }
        return true
    }

    // MARK: Text Selection Actions

    private func selectedExcerpt() -> String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let ns = string as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ChatSelectionLogic.cleanSelection(ns.substring(with: range))
    }

    private func selectionAnchor(for range: NSRange) -> MarkdownLinkAnchor? {
        var localRect = CGRect.null
        if let layoutManager = textLayoutManager, let tr = textRange(range) {
            layoutManager.ensureLayout(for: tr)
            let origin = textContainerOrigin
            layoutManager.enumerateTextSegments(in: tr, type: .standard, options: []) { _, segmentFrame, _, _ in
                let shifted = segmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                localRect = localRect.isNull ? shifted : localRect.union(shifted)
                return true
            }
        }
        if let window, !localRect.isNull, !localRect.isEmpty {
            let inWindow = convert(localRect, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            return MarkdownLinkAnchor(screenRect: inScreen, window: window)
        }
        let mouse = NSEvent.mouseLocation
        return MarkdownLinkAnchor(screenRect: CGRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16), window: window)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let handler = onSelectionAction else { return }
        if let excerpt = selectedExcerpt(), let anchor = selectionAnchor(for: selectedRange()) {
            ChatSelectionPopoverPresenter.shared.show(
                selection: excerpt,
                anchor: anchor,
                theme: selectionTheme,
                onAction: handler
            )
        } else {
            ChatSelectionPopoverPresenter.shared.dismiss()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard onSelectionAction != nil, selectedExcerpt() != nil else { return base }
        ChatSelectionPopoverPresenter.shared.dismiss()
        let sep = NSMenuItem.separator()
        base.insertItem(sep, at: 0)
        for action in ChatSelectionAction.allCases.reversed() {
            let item = NSMenuItem(title: action.menuTitle, action: #selector(handleSelectionMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            base.insertItem(item, at: 0)
        }
        return base
    }

    @objc private func handleSelectionMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = ChatSelectionAction(rawValue: raw),
              let excerpt = selectedExcerpt() else { return }
        onSelectionAction?(action, excerpt)
    }

    // MARK: Decorations

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let decoration = paragraph.attributedString.attribute(.markdownDecoration, at: 0, effectiveRange: nil) as? MarkdownDecoration
            var hasInlineCode = false
            paragraph.attributedString.enumerateAttribute(
                .markdownInlineCode,
                in: NSRange(location: 0, length: paragraph.attributedString.length),
                options: []
            ) { value, _, stop in
                if value is MarkdownInlineCodeStyle {
                    hasInlineCode = true
                    stop.pointee = true
                }
            }
            if decoration != nil || hasInlineCode {
                let fragment = MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
                fragment.decoration = decoration
                fragment.hasInlineCode = hasInlineCode
                return fragment
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph that draws its `MarkdownDecoration` and inline code pills before its text. Slices
/// of one box meet at the fragments' edges (fragments tile the text), so a table or code fence
/// reads as one shape.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
    var decoration: MarkdownDecoration?
    var hasInlineCode = true

    private struct CachedInlineCodePills {
        var fragmentSize: CGSize
        var lineCount: Int
        var specs: [(rect: CGRect, style: MarkdownInlineCodeStyle)]
    }

    private var cachedPills: CachedInlineCodePills?
    private(set) var inlineCodePillComputationCount = 0

    override func invalidateLayout() {
        cachedPills = nil
        super.invalidateLayout()
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    override var renderingSurfaceBounds: CGRect {
        let full = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(full).insetBy(dx: -3, dy: -1)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decoration { draw(decoration, at: point, in: context) }
        if hasInlineCode { drawInlineCodePills(at: point, in: context) }
        super.draw(at: point, in: context)
    }

    /// Computes (and caches per fragment layout size) rounded pill frames for every `.markdownInlineCode`
    /// span inside this paragraph.
    func inlineCodePillSpecs(at point: CGPoint) -> [(rect: CGRect, style: MarkdownInlineCodeStyle)] {
        let local = cachedLocalInlineCodePillSpecs()
        guard point != .zero else { return local }
        return local.map { ($0.rect.offsetBy(dx: point.x, dy: point.y), $0.style) }
    }

    private func cachedLocalInlineCodePillSpecs() -> [(rect: CGRect, style: MarkdownInlineCodeStyle)] {
        guard hasInlineCode else { return [] }
        let size = layoutFragmentFrame.size
        let lineCount = textLineFragments.count
        if let cached = cachedPills,
           cached.fragmentSize == size,
           cached.lineCount == lineCount {
            return cached.specs
        }
        inlineCodePillComputationCount &+= 1
        let specs = computeLocalInlineCodePillSpecs()
        cachedPills = CachedInlineCodePills(fragmentSize: size, lineCount: lineCount, specs: specs)
        return specs
    }

    private func computeLocalInlineCodePillSpecs() -> [(rect: CGRect, style: MarkdownInlineCodeStyle)] {
        guard let paragraph = textElement as? NSTextParagraph else { return [] }
        let attr = paragraph.attributedString
        guard attr.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: attr.length)
        var runs: [(NSRange, MarkdownInlineCodeStyle)] = []
        attr.enumerateAttribute(.markdownInlineCode, in: fullRange, options: []) { value, range, _ in
            if let style = value as? MarkdownInlineCodeStyle {
                runs.append((range, style))
            }
        }
        guard !runs.isEmpty else { return [] }

        var specs: [(CGRect, MarkdownInlineCodeStyle)] = []
        for (runRange, style) in runs {
            for line in textLineFragments {
                let lineRange = line.characterRange
                let inter = NSIntersectionRange(runRange, lineRange)
                guard inter.length > 0 else { continue }
                let localStart = inter.location - lineRange.location
                let localEnd = localStart + inter.length
                let x1 = line.locationForCharacter(at: localStart).x
                let x2 = line.locationForCharacter(at: localEnd).x
                let minX = min(x1, x2)
                let maxX = max(x1, x2)
                guard maxX > minX else { continue }
                let lineOrigin = line.typographicBounds.origin
                let lineHeight = line.typographicBounds.height
                let rect = CGRect(
                    x: lineOrigin.x + minX - 2.5,
                    y: lineOrigin.y + 0.5,
                    width: (maxX - minX) + 5.0,
                    height: max(4, lineHeight - 1.0)
                )
                specs.append((rect, style))
            }
        }
        return specs
    }

    private func drawInlineCodePills(at point: CGPoint, in context: CGContext) {
        let specs = cachedLocalInlineCodePillSpecs()
        guard !specs.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if point != .zero {
            context.translateBy(x: point.x, y: point.y)
        }
        for (rect, style) in specs {
            let radius = min(4.0, rect.height * 0.45)
            let fillPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setFillColor(style.fill.cgColor)
            context.addPath(fillPath)
            context.fillPath()

            let strokeRect = rect.insetBy(dx: 0.375, dy: 0.375)
            if strokeRect.width > 0 && strokeRect.height > 0 {
                let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setStrokeColor(style.border.cgColor)
                context.setLineWidth(0.75)
                context.addPath(strokePath)
                context.strokePath()
            }
        }
    }

    private func draw(_ decoration: MarkdownDecoration, at point: CGPoint, in context: CGContext) {
        let lines = textLineFragments
        let textTop = lines.first?.typographicBounds.minY ?? 0
        let textBottom = lines.last?.typographicBounds.maxY ?? layoutFragmentFrame.height
        let originX = point.x - layoutFragmentFrame.minX
        let right = originX + containerWidth
        context.saveGState()
        defer { context.restoreGState() }

        if let box = decoration.box {
            let top = point.y + (box.isFirst ? max(0, textTop - box.padTop) : 0)
            let bottom = point.y + (box.isLast ? min(layoutFragmentFrame.height, textBottom + box.padBottom) : layoutFragmentFrame.height)
            let rect = CGRect(x: originX + box.left, y: top, width: max(0, right - originX - box.left), height: max(0, bottom - top))
            let r = box.cornerRadius
            if let fill = box.fill {
                context.setFillColor(fill.cgColor)
                context.addPath(Self.slice(rect, radius: r, top: box.isFirst, bottom: box.isLast, closed: true))
                context.fillPath()
            }
            context.setLineWidth(1)
            if let line = box.lineAbove {
                context.setStrokeColor(line.cgColor)
                context.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.minY + 0.5), CGPoint(x: rect.maxX, y: rect.minY + 0.5)])
            }
            if let line = box.lineBelow {
                context.setStrokeColor(line.cgColor)
                context.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.maxY - 0.5), CGPoint(x: rect.maxX, y: rect.maxY - 0.5)])
            }
            if let border = box.border {
                context.setStrokeColor(border.cgColor)
                context.addPath(Self.slice(rect.insetBy(dx: 0.5, dy: 0), radius: r, top: box.isFirst, bottom: box.isLast, closed: false, inset: 0.5))
                context.strokePath()
            }
        }

        for bar in decoration.quoteBars {
            let top = point.y + (bar.isFirst ? textTop : 0)
            let bottom = point.y + (bar.isLast ? textBottom : layoutFragmentFrame.height)
            context.setFillColor(bar.color.cgColor)
            context.fill(CGRect(x: originX + bar.x, y: top, width: 2, height: max(0, bottom - top)))
        }

        if let rule = decoration.rule {
            let y = point.y + ((textTop + textBottom) / 2).rounded(.down) + 0.5
            context.setStrokeColor(rule.color.cgColor)
            context.setLineWidth(1)
            context.strokeLineSegments(between: [CGPoint(x: originX + rule.left, y: y), CGPoint(x: right, y: y)])
        }
    }

    /// One paragraph's slice of a box (in the flipped text coordinates): rounded at the top when it
    /// starts the box and at the bottom when it ends it. Open slices draw only what this paragraph
    /// owns of the border: its sides, plus the top or bottom edge.
    static func slice(_ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool, closed: Bool, inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, rect.width / 2, rect.height / 2)
        let minY = rect.minY + (top ? inset : 0)
        let maxY = rect.maxY - (bottom ? inset : 0)
        if closed || (top && bottom) {
            path.move(to: CGPoint(x: rect.minX, y: top ? minY + r : minY))
            if top { path.addArc(tangent1End: CGPoint(x: rect.minX, y: minY), tangent2End: CGPoint(x: rect.minX + r, y: minY), radius: r) }
            path.addLine(to: CGPoint(x: rect.maxX - (top ? r : 0), y: minY))
            if top { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: minY), tangent2End: CGPoint(x: rect.maxX, y: minY + r), radius: r) }
            path.addLine(to: CGPoint(x: rect.maxX, y: maxY - (bottom ? r : 0)))
            if bottom { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: maxY), tangent2End: CGPoint(x: rect.maxX - r, y: maxY), radius: r) }
            path.addLine(to: CGPoint(x: rect.minX + (bottom ? r : 0), y: maxY))
            if bottom { path.addArc(tangent1End: CGPoint(x: rect.minX, y: maxY), tangent2End: CGPoint(x: rect.minX, y: maxY - r), radius: r) }
            path.closeSubpath()
            return path
        }
        // Left side (and the top-left corner and top edge when it starts the box)…
        path.move(to: CGPoint(x: rect.minX, y: maxY - (bottom ? r : 0)))
        if top {
            path.addLine(to: CGPoint(x: rect.minX, y: minY + r))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: minY), tangent2End: CGPoint(x: rect.minX + r, y: minY), radius: r)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: minY), tangent2End: CGPoint(x: rect.maxX, y: minY + r), radius: r)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: minY))
            path.move(to: CGPoint(x: rect.maxX, y: minY))
        }
        // …then the right side, and the bottom edge when it ends the box.
        path.addLine(to: CGPoint(x: rect.maxX, y: maxY - (bottom ? r : 0)))
        if bottom {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: maxY), tangent2End: CGPoint(x: rect.maxX - r, y: maxY), radius: r)
            path.addLine(to: CGPoint(x: rect.minX + r, y: maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: maxY), tangent2End: CGPoint(x: rect.minX, y: maxY - r), radius: r)
        }
        return path
    }
}
