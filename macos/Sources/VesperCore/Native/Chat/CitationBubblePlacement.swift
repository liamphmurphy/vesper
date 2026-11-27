import Foundation

/// Pure placement and display metadata for the floating citation bubble.
/// Uses macOS screen coordinates (`minY` is bottom, `maxY` is top) for panel framing,
/// and SwiftUI top-down normalized coordinates (`0...1`) for the spring scale anchor.
public enum CitationBubblePlacement: Sendable {
    public struct Placement: Sendable, Equatable {
        /// Bottom-left screen origin for the bubble's content frame (excluding outer shadow padding).
        public var origin: TooltipPoint
        /// `true` when the bubble is placed above the citation badge, `false` when flipped below.
        public var placedAbove: Bool
        /// Normalized horizontal animation anchor (`0...1`) aligned with the citation badge.
        public var anchorUnitX: Double
        /// Normalized vertical animation anchor (`1.0` when placed above, `0.0` when placed below).
        public var anchorUnitY: Double

        public init(origin: TooltipPoint, placedAbove: Bool, anchorUnitX: Double, anchorUnitY: Double) {
            self.origin = origin
            self.placedAbove = placedAbove
            self.anchorUnitX = anchorUnitX
            self.anchorUnitY = anchorUnitY
        }
    }

    /// Places a square citation bubble above `anchor` by default (keeping the reading line visible
    /// beneath it), flipping below when there isn't enough room above, and clamping horizontally
    /// inside `visibleFrame`.
    public static func place(
        anchor: TooltipRect,
        bubbleSize: TooltipSize,
        visibleFrame: TooltipRect,
        gap: Double = 8,
        edgePadding: Double = 10
    ) -> Placement {
        let minAllowedX = visibleFrame.minX + edgePadding
        let maxAllowedX = visibleFrame.maxX - edgePadding - bubbleSize.width
        let centeredX = anchor.midX - bubbleSize.width / 2
        let clampedX: Double
        if maxAllowedX < minAllowedX {
            clampedX = minAllowedX
        } else {
            clampedX = min(max(centeredX, minAllowedX), maxAllowedX)
        }

        let minAllowedY = visibleFrame.minY + edgePadding
        let maxAllowedY = visibleFrame.maxY - edgePadding - bubbleSize.height
        let aboveY = anchor.maxY + gap
        let belowY = anchor.minY - gap - bubbleSize.height

        let chosenY: Double
        let placedAbove: Bool
        if aboveY <= maxAllowedY {
            chosenY = max(aboveY, minAllowedY)
            placedAbove = true
        } else if belowY >= minAllowedY {
            chosenY = min(belowY, maxAllowedY)
            placedAbove = false
        } else {
            // Neither side fits cleanly; pick whichever side has more space and clamp.
            let roomAbove = visibleFrame.maxY - anchor.maxY
            let roomBelow = anchor.minY - visibleFrame.minY
            placedAbove = roomAbove >= roomBelow
            let rawY = placedAbove ? aboveY : belowY
            if maxAllowedY < minAllowedY {
                chosenY = minAllowedY
            } else {
                chosenY = min(max(rawY, minAllowedY), maxAllowedY)
            }
        }

        let roundedX = clampedX.rounded()
        let roundedY = chosenY.rounded()

        let rawUnitX = bubbleSize.width > 0 ? (anchor.midX - roundedX) / bubbleSize.width : 0.5
        let clampedUnitX = min(max(rawUnitX, 0.12), 0.88)
        let anchorUnitY = placedAbove ? 1.0 : 0.0

        return Placement(
            origin: TooltipPoint(x: roundedX, y: roundedY),
            placedAbove: placedAbove,
            anchorUnitX: clampedUnitX,
            anchorUnitY: anchorUnitY
        )
    }

    /// Best human-readable name for a cited source, preferring fetched preview title,
    /// then the source's own title, wiki ref, host, or raw URL.
    public static func displayTitle(source: ChatListedSource, previewTitle: String?) -> String {
        if let previewTitle, !previewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return previewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        if let ref = source.ref, !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ref.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let host = hostLabel(for: source.url), !host.isEmpty {
            return host
        }
        return source.url.isEmpty ? "Source" : source.url
    }

    /// Secondary host or Knowledge path shown as the source's link label.
    public static func displayDestination(source: ChatListedSource, previewSite: String?) -> String {
        if !source.url.isEmpty {
            if let site = previewSite, !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return site.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return hostLabel(for: source.url) ?? source.url
        }
        if let ref = source.ref, !ref.isEmpty {
            return ref
        }
        return "Knowledge"
    }

    /// Actionable destination: external URL string for web sources, or `/wiki/...` path for Knowledge refs.
    public static func destination(source: ChatListedSource) -> Destination? {
        let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            return .external(url)
        }
        if let ref = source.ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            let encoded = ref.components(separatedBy: "/").map(MarkdownSource.encodeURIComponent).joined(separator: "/")
            return .knowledgePath("/wiki/\(encoded)")
        }
        return nil
    }

    public enum Destination: Sendable, Equatable {
        case external(String)
        case knowledgePath(String)
    }

    private static func hostLabel(for rawURL: String) -> String? {
        guard let host = URL(string: rawURL)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
