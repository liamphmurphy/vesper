import CoreGraphics
import Foundation

// MARK: - Canvas Scroll Wheel Logic (Cmd/Ctrl+Scroll Zoom & Trackpad Pan)

/// Normalized scroll-wheel event data extracted from `NSEvent` in local top-left canvas coordinates.
public struct CanvasScrollInput: Sendable, Equatable {
    public var deltaX: Double
    public var deltaY: Double
    public var hasPreciseDeltas: Bool
    public var isMomentum: Bool
    public var command: Bool
    public var control: Bool
    public var shift: Bool
    public var locationX: Double
    public var locationY: Double

    public init(
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool,
        isMomentum: Bool = false,
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        locationX: Double = 0,
        locationY: Double = 0
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.isMomentum = isMomentum
        self.command = command
        self.control = control
        self.shift = shift
        self.locationX = locationX
        self.locationY = locationY
    }
}

/// Interpreted canvas viewport action from a scroll-wheel event.
public enum CanvasScrollAction: Sendable, Equatable {
    case zoom(factor: Double, anchorX: Double, anchorY: Double)
    case pan(dx: Double, dy: Double)
    case ignore
}

public enum CanvasScrollLogic: Sendable {
    /// Exponential zoom gain per point of scroll delta (matches smooth Figma/Vesper feel).
    public static let defaultZoomSensitivity: Double = 0.0035
    /// Line-to-point multiplier for non-precise (notched) scroll wheels.
    public static let lineScrollScale: Double = 16.0
    /// Per-event exponent clamp so a rogue scroll spike cannot jump zoom wildly.
    public static let maxExponentMagnitude: Double = 0.5

    /// Interprets an AppKit scroll-wheel event into either a pointer-anchored zoom (when Command
    /// or Control is held) or a screen-space pan (otherwise).
    public static func interpret(
        _ input: CanvasScrollInput,
        zoomSensitivity: Double = defaultZoomSensitivity
    ) -> CanvasScrollAction {
        let scale = input.hasPreciseDeltas ? 1.0 : lineScrollScale
        if input.command || input.control {
            // Stop zooming immediately when fingers lift; ignore inertial momentum tail.
            guard !input.isMomentum, input.deltaY != 0 else { return .ignore }
            let rawExp = input.deltaY * scale * zoomSensitivity
            let clampedExp = max(-maxExponentMagnitude, min(maxExponentMagnitude, rawExp))
            let factor = exp(clampedExp)
            guard factor.isFinite, factor > 0 else { return .ignore }
            return .zoom(factor: factor, anchorX: input.locationX, anchorY: input.locationY)
        }

        let dx: Double
        let dy: Double
        if input.shift && input.deltaX == 0 && input.deltaY != 0 {
            dx = input.deltaY * scale
            dy = 0
        } else {
            dx = input.deltaX * scale
            dy = input.deltaY * scale
        }
        guard dx != 0 || dy != 0 else { return .ignore }
        return .pan(dx: dx, dy: dy)
    }
}

// MARK: - Canvas Backdrop Theme Resolution

public enum CanvasBackdropColor: Sendable, Equatable {
    case explicitHex(String)
    case themeSurfaceSunken
}

public enum CanvasBackdropLogic: Sendable {
    /// Resolves the infinite canvas backdrop color. When a design page does not declare an explicit
    /// `background`, falls back to Vesper's current theme (`surface-sunken`) rather than the
    /// document's content token `mode`, so canvases stay dark on dark themes.
    public static func resolveDesignBackdrop(pageBackgroundHex: String?) -> CanvasBackdropColor {
        if let hex = pageBackgroundHex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty {
            return .explicitHex(hex)
        }
        return .themeSurfaceSunken
    }

    /// Returns true when an RGB/RRGGBB/RRGGBBAA hex color has perceived luminance below 0.5.
    public static func isHexDark(_ hex: String) -> Bool {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        let r: Double
        let g: Double
        let b: Double
        if chars.count == 3 || chars.count == 4,
           let rv = Int(String([chars[0], chars[0]]), radix: 16),
           let gv = Int(String([chars[1], chars[1]]), radix: 16),
           let bv = Int(String([chars[2], chars[2]]), radix: 16) {
            r = Double(rv) / 255.0
            g = Double(gv) / 255.0
            b = Double(bv) / 255.0
        } else if chars.count >= 6,
                  let rv = Int(String(chars[0..<2]), radix: 16),
                  let gv = Int(String(chars[2..<4]), radix: 16),
                  let bv = Int(String(chars[4..<6]), radix: 16) {
            r = Double(rv) / 255.0
            g = Double(gv) / 255.0
            b = Double(bv) / 255.0
        } else {
            return false
        }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.5
    }
}

// MARK: - Design Infinite Canvas Camera

public struct DesignCamera: Sendable, Equatable {
    public static let minZoom: Double = 0.02
    public static let maxZoom: Double = 8.0

    public var x: Double // world x at top-left of viewport
    public var y: Double // world y at top-left of viewport
    public var z: Double // zoom scale (0.02 ... 8.0)

    public static let initial = DesignCamera(x: -80, y: -80, z: 1)

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func worldToScreen(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: (pt.x - x) * z, y: (pt.y - y) * z)
    }

    public func screenToWorld(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x / z + x, y: pt.y / z + y)
    }

    /// Zooms by `factor` around a screen-space `anchor`, keeping the world point beneath it stationary.
    public func zoomed(by factor: Double, around anchor: CGPoint) -> DesignCamera {
        let nextZ = min(Self.maxZoom, max(Self.minZoom, z * factor))
        let world = screenToWorld(anchor)
        return DesignCamera(
            x: world.x - anchor.x / nextZ,
            y: world.y - anchor.y / nextZ,
            z: nextZ
        )
    }

    /// Pans by a screen-space delta `(dx, dy)` in points (positive shifts content right/down).
    public func panned(dx: Double, dy: Double) -> DesignCamera {
        DesignCamera(x: x - dx / z, y: y - dy / z, z: z)
    }

    public static func fit(box: DesignBox, viewport: CGSize, pad: Double = 64) -> DesignCamera {
        guard viewport.width > 10, viewport.height > 10 else { return .initial }
        guard box.w > 0 && box.h > 0 else {
            return DesignCamera(x: -viewport.width / 2, y: -viewport.height / 2, z: 1)
        }
        let zx = max(minZoom, (viewport.width - pad * 2) / box.w)
        let zy = max(minZoom, (viewport.height - pad * 2) / box.h)
        let z = min(1.5, min(zx, zy))
        let cx = box.x + box.w / 2
        let cy = box.y + box.h / 2
        return DesignCamera(x: cx - viewport.width / (2 * z), y: cy - viewport.height / (2 * z), z: z)
    }
}
