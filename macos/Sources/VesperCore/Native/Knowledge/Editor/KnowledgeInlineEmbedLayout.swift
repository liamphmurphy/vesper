#if os(macOS)
import AppKit

/// Vertical spacing and container dimensions reserved for one paragraph's inline embed group.
public struct KnowledgeInlineEmbedMetrics: Sendable, Equatable {
    public var size: CGSize
    public var topGap: CGFloat
    public var bottomGap: CGFloat

    public init(size: CGSize, topGap: CGFloat, bottomGap: CGFloat) {
        self.size = size
        self.topGap = topGap
        self.bottomGap = bottomGap
    }

    /// Extra vertical space reserved below the paragraph's text via `NSParagraphStyle.paragraphSpacing`.
    public var reservedSpacing: CGFloat {
        topGap + size.height + bottomGap
    }
}

/// Computed frame for a single paragraph's inline embed container in `LivePreviewNSTextView` coordinates.
public struct KnowledgeInlineEmbedFrame: Sendable, Equatable {
    public var groupID: String
    public var frame: CGRect
    public var bottomGap: CGFloat

    public init(groupID: String, frame: CGRect, bottomGap: CGFloat) {
        self.groupID = groupID
        self.frame = frame
        self.bottomGap = bottomGap
    }
}

/// TextKit 2 layout math anchoring inline embed containers directly beneath their source paragraphs.
@MainActor
public enum KnowledgeInlineEmbedLayout {
    public static let collapsedStandaloneLineHeight: CGFloat = 2
    public static let collapsedTopGap: CGFloat = 4
    public static let standardTopGap: CGFloat = 8
    public static let bottomGap: CGFloat = 8
    public static let defaultPlaceholderSize = CGSize(width: 240, height: 52)

    public static func metrics(
        measuredSize: CGSize,
        isCollapsedStandalone: Bool
    ) -> KnowledgeInlineEmbedMetrics {
        let clamped = CGSize(
            width: max(1, ceil(measuredSize.width)),
            height: max(1, ceil(measuredSize.height))
        )
        return KnowledgeInlineEmbedMetrics(
            size: clamped,
            topGap: isCollapsedStandalone ? collapsedTopGap : standardTopGap,
            bottomGap: bottomGap
        )
    }

    /// Computes each embed group's frame in text-view coordinates from TextKit 2 layout fragments.
    public static func computeFrames(
        groups: [KnowledgeInlineEmbedParagraph],
        metricsByID: [String: KnowledgeInlineEmbedMetrics],
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        containerWidth: CGFloat,
        textContainerOrigin: CGPoint
    ) -> [KnowledgeInlineEmbedFrame] {
        guard !groups.isEmpty else { return [] }
        let docStart = contentStorage.documentRange.location
        let textLength = contentStorage.attributedString?.length ?? 0
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var frames: [KnowledgeInlineEmbedFrame] = []
        frames.reserveCapacity(groups.count)

        for group in groups {
            guard group.lineRange.location >= 0,
                  group.lineRange.location < textLength,
                  let loc = contentStorage.location(docStart, offsetBy: group.lineRange.location),
                  let fragment = layoutManager.textLayoutFragment(for: loc),
                  let metrics = metricsByID[group.id] else {
                continue
            }
            layoutManager.ensureLayout(for: fragment.rangeInElement)
            let fragFrame = fragment.layoutFragmentFrame
            let lastLineBottom = fragment.textLineFragments.last?.typographicBounds.maxY ?? 0
            let y = textContainerOrigin.y + fragFrame.minY + lastLineBottom + metrics.topGap
            let width = group.fillsContainerWidth
                ? max(1, containerWidth)
                : max(1, min(containerWidth, metrics.size.width))
            let rect = CGRect(
                x: textContainerOrigin.x,
                y: y,
                width: width,
                height: metrics.size.height
            )
            frames.append(KnowledgeInlineEmbedFrame(
                groupID: group.id,
                frame: rect,
                bottomGap: metrics.bottomGap
            ))
        }
        return frames
    }

    /// Total text-view height needed for both TextKit 2 text and all inline embeds, including
    /// any embed anchored to the final paragraph where TextKit 2 omits trailing paragraph spacing.
    public static func totalFittingHeight(
        usageBoundsHeight: CGFloat,
        embedFrames: [KnowledgeInlineEmbedFrame],
        verticalInset: CGFloat
    ) -> CGFloat {
        let textHeight = usageBoundsHeight + verticalInset * 2 + 4
        let embedHeight = embedFrames.reduce(CGFloat(0)) { acc, item in
            max(acc, item.frame.maxY + item.bottomGap + verticalInset)
        }
        return ceil(max(textHeight, embedHeight))
    }
}
#endif
