import CoreGraphics

/// Maps root user space to the canvas view's points at a zoom (points per user unit).
public struct MockupCanvasMapping: Equatable, Sendable {
    public var viewBox: CGRect
    public var zoom: CGFloat

    public init(viewBox: CGRect, zoom: CGFloat) {
        self.viewBox = viewBox
        self.zoom = zoom
    }

    public func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - viewBox.minX) * zoom, y: (p.y - viewBox.minY) * zoom)
    }

    public func rect(_ r: CGRect) -> CGRect {
        CGRect(origin: point(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    public func user(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + viewBox.minX, y: p.y / zoom + viewBox.minY)
    }

    public var size: CGSize { CGSize(width: viewBox.width * zoom, height: viewBox.height * zoom) }
}

public enum MockupResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func anchor(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The rect after dragging this handle by `d` (same space as `r`), never flipped or empty.
    public func resized(_ r: CGRect, by d: CGSize) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch self {
        case .topLeft: minX += d.width; minY += d.height
        case .top: minY += d.height
        case .topRight: maxX += d.width; minY += d.height
        case .right: maxX += d.width
        case .bottomRight: maxX += d.width; maxY += d.height
        case .bottom: maxY += d.height
        case .bottomLeft: minX += d.width; maxY += d.height
        case .left: minX += d.width
        }
        let x0 = min(minX, maxX), x1 = max(minX, maxX), y0 = min(minY, maxY), y1 = max(minY, maxY)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
    }
}
