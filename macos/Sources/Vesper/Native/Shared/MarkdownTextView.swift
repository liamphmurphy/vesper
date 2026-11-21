import AppKit
import VesperCore

/// Rendered markdown in a TextKit 2 text view: selectable, with Look Up, the context menu's
/// Copy and Services, link clicks, and the boxes, rules and quote bars `MarkdownDecoration`
/// describes drawn behind the text. Not editable and not scrollable: it is as tall as its text,
/// inside the screen's own scroll view.
@MainActor
final class MarkdownTextView: NSTextView, NSTextViewDelegate, NSTextLayoutManagerDelegate {
    private let contentStorage = NSTextContentStorage()
    /// Called with each link the person clicks, and whether ⌘ was held (open in a new tab).
    var onLink: ((MarkdownLinkTarget, _ newTab: Bool) -> Void)?
    private(set) var rendering: MarkdownRendering?
    private var findRanges: [NSRange] = []

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

    func show(_ rendering: MarkdownRendering) {
        self.rendering = rendering
        textStorage?.setAttributedString(rendering.text)
        applyFindHighlights()
    }

    /// The height the text needs at `width`.
    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager = textLayoutManager, let container = textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    // MARK: Find

    /// Tints every match of the find bar's query; on the current row, the first match more strongly,
    /// scrolled into view.
    func highlight(query: String, caseSensitive: Bool, isCurrent: Bool, match: NSColor, current: NSColor) {
        let ranges = MarkdownFind.ranges(of: query, in: string, caseSensitive: caseSensitive)
        findStyle = (match, current, isCurrent)
        guard ranges != findRanges || findStyle.isCurrent != isCurrent else { return }
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

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let target = MarkdownLinkTarget(url: url) else { return true }
        switch target {
        // In-page jumps: a heading, a footnote, back to its reference.
        case .anchor(let id): rendering?.anchors[id].map(reveal(location:))
        case .footnote(let n): rendering?.footnotes[n].map(reveal(location:))
        case .footnoteReference(let n): rendering?.footnoteReferences[n].map(reveal(location:))
        default: onLink?(target, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }
        return true
    }

    // MARK: Decorations

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(.markdownDecoration, at: 0, effectiveRange: nil) as? MarkdownDecoration {
            let fragment = MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
            fragment.decoration = decoration
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph that draws its `MarkdownDecoration` before its text. Slices of one box meet at the
/// fragments' edges (fragments tile the text), so a table or code fence reads as one shape.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
    var decoration: MarkdownDecoration?

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    override var renderingSurfaceBounds: CGRect {
        let full = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(full)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decoration { draw(decoration, at: point, in: context) }
        super.draw(at: point, in: context)
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
