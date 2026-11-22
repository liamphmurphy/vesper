import CoreGraphics
import Foundation

/// All 59 `ChatStatusKind` values from `web/lib/chat-ui.ts`.
public enum ActivitySceneKind: String, CaseIterable, Sendable, Hashable, Codable {
    case thinking
    case nextStep = "next-step"
    case writingReply = "writing-reply"
    case connector
    case secret
    case wiki
    case tickets
    case ticketLookup = "ticket-lookup"
    case readingCode = "reading-code"
    case searchingCode = "searching-code"
    case writingCode = "writing-code"
    case tests
    case build
    case install
    case terminal
    case github
    case commit
    case push
    case pullRequest = "pull-request"
    case repoHistory = "repo-history"
    case web
    case webPage = "web-page"
    case video
    case image
    case imageView = "image-view"
    case canvas
    case canvasComment = "canvas-comment"
    case design
    case designView = "design-view"
    case playground
    case runs
    case workflow
    case memory
    case memorySave = "memory-save"
    case chatHistory = "chat-history"
    case repoSearch = "repo-search"
    case repoAttach = "repo-attach"
    case videoRender = "video-render"
    case audioRender = "audio-render"
    case finance
    case financeSort = "finance-sort"
    case persona
    case schedule
    case learning
    case research
    case space
    case savedLinks = "saved-links"
    case projects
    case library
    case inbox
    case chart
    case diagram
    case app
    case customApp = "custom-app"
    case database
    case http
    case pdf
    case subagent
    case choices

    /// Aliases split off a broader kind (`SCENE_OF` in `activity-scene.tsx`).
    public static let splitAliases: [ActivitySceneKind: ActivitySceneKind] = [
        .writingReply: .writingCode,
        .imageView: .image,
        .designView: .design,
    ]

    /// Unique base scenes (all 56 keys in `SCENES`).
    public static let uniqueSceneKinds: [ActivitySceneKind] = allCases.filter { splitAliases[$0] == nil }

    /// Resolves split aliases (`writing-reply`, `image-view`, `design-view`) to their backing scene.
    public var resolvedScene: ActivitySceneKind {
        Self.splitAliases[self] ?? self
    }
}

/// CSS token color names referenced by scene elements (`tokens.css` & `globals.css`).
public enum SceneColorToken: String, Sendable, Equatable, Hashable {
    case accent
    case stateDone = "state-done"
    case stateProgress = "state-progress"
    case text
    case textTertiary = "text-tertiary"
    case surface
    case surfaceRaised = "surface-raised"
    case surfaceSunken = "surface-sunken"
    case borderSubtle = "border-subtle"
    case borderStrong = "border-strong"
}

/// Resolved sRGB color palette for scene rendering, seeded from `ThemeTokens` with `tokens.css` defaults.
public struct ActivityScenePalette: Sendable, Equatable {
    public var accent: RGBA
    public var stateDone: RGBA
    public var stateProgress: RGBA
    public var text: RGBA
    public var textTertiary: RGBA
    public var surface: RGBA
    public var surfaceRaised: RGBA
    public var surfaceSunken: RGBA
    public var borderSubtle: RGBA
    public var borderStrong: RGBA

    public static let dark = ActivityScenePalette(
        accent: RGBA(hex: "#9B8CFF")!,
        stateDone: RGBA(hex: "#4CB782")!,
        stateProgress: RGBA(hex: "#F0BF4C")!,
        text: RGBA(hex: "#EEEDF3")!,
        textTertiary: RGBA(hex: "#8C899C")!,
        surface: RGBA(hex: "#15141F")!,
        surfaceRaised: RGBA(hex: "#1B1A27")!,
        surfaceSunken: RGBA(hex: "#110F19")!,
        borderSubtle: RGBA(hex: "#1E1C29")!,
        borderStrong: RGBA(hex: "#2E2B3B")!
    )

    public static let light = ActivityScenePalette(
        accent: RGBA(hex: "#5B4BD6")!,
        stateDone: RGBA(hex: "#2E9E68")!,
        stateProgress: RGBA(hex: "#D49A0A")!,
        text: RGBA(hex: "#17151F")!,
        textTertiary: RGBA(hex: "#66637A")!,
        surface: RGBA(hex: "#FFFFFF")!,
        surfaceRaised: RGBA(hex: "#FFFFFF")!,
        surfaceSunken: RGBA(hex: "#F6F5FA")!,
        borderSubtle: RGBA(hex: "#ECE9F3")!,
        borderStrong: RGBA(hex: "#DEDAEA")!
    )

    public init(
        accent: RGBA,
        stateDone: RGBA,
        stateProgress: RGBA,
        text: RGBA,
        textTertiary: RGBA,
        surface: RGBA,
        surfaceRaised: RGBA,
        surfaceSunken: RGBA,
        borderSubtle: RGBA,
        borderStrong: RGBA
    ) {
        self.accent = accent
        self.stateDone = stateDone
        self.stateProgress = stateProgress
        self.text = text
        self.textTertiary = textTertiary
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.surfaceSunken = surfaceSunken
        self.borderSubtle = borderSubtle
        self.borderStrong = borderStrong
    }

    public init(theme: ThemeTokens) {
        let fallback = theme.mode == .dark ? Self.dark : Self.light
        self.accent = theme.color("accent") ?? fallback.accent
        self.stateDone = theme.color("state-done") ?? fallback.stateDone
        self.stateProgress = theme.color("state-progress") ?? fallback.stateProgress
        self.text = theme.color("text") ?? fallback.text
        self.textTertiary = theme.color("text-tertiary") ?? fallback.textTertiary
        self.surface = theme.color("surface") ?? fallback.surface
        self.surfaceRaised = theme.color("surface-raised") ?? fallback.surfaceRaised
        self.surfaceSunken = theme.color("surface-sunken") ?? fallback.surfaceSunken
        self.borderSubtle = theme.color("border-subtle") ?? fallback.borderSubtle
        self.borderStrong = theme.color("border-strong") ?? fallback.borderStrong
    }

    public func resolve(_ token: SceneColorToken) -> RGBA {
        switch token {
        case .accent: accent
        case .stateDone: stateDone
        case .stateProgress: stateProgress
        case .text: text
        case .textTertiary: textTertiary
        case .surface: surface
        case .surfaceRaised: surfaceRaised
        case .surfaceSunken: surfaceSunken
        case .borderSubtle: borderSubtle
        case .borderStrong: borderStrong
        }
    }
}

public enum SceneTransformOrigin: Sendable, Equatable {
    case zero
    case center
    case leftCenter
    case centerBottom
    case leftBottom
    case point(x: Double, y: Double)
}

public enum SceneLineCap: Sendable, Equatable {
    case butt
    case round
    case square
}

public enum SceneLineJoin: Sendable, Equatable {
    case miter
    case round
    case bevel
}

public enum SceneTextAnchor: Sendable, Equatable {
    case start
    case middle
    case end
}

public struct ScenePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Visual and motion styling for a single scene node, mirroring `.scene-*` CSS classes and SVG attributes.
public struct SceneStyle: Sendable, Equatable {
    public var fill: SceneColorToken?
    public var fillOpacity: Double
    public var stroke: SceneColorToken?
    public var strokeOpacity: Double
    public var strokeWidth: Double
    public var lineCap: SceneLineCap
    public var lineJoin: SceneLineJoin
    public var dashArray: [Double]?
    public var pathLengthOne: Bool
    public var opacity: Double
    public var baseDashOffset: Double
    public var baseTransform: MotionTransform
    public var transformOrigin: SceneTransformOrigin
    public var animation: MotionAnimation?

    public init(
        fill: SceneColorToken? = nil,
        fillOpacity: Double = 1,
        stroke: SceneColorToken? = nil,
        strokeOpacity: Double = 1,
        strokeWidth: Double = 1,
        lineCap: SceneLineCap = .butt,
        lineJoin: SceneLineJoin = .miter,
        dashArray: [Double]? = nil,
        pathLengthOne: Bool = false,
        opacity: Double = 1,
        baseDashOffset: Double = 0,
        baseTransform: MotionTransform = .identity,
        transformOrigin: SceneTransformOrigin = .zero,
        animation: MotionAnimation? = nil
    ) {
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.stroke = stroke
        self.strokeOpacity = strokeOpacity
        self.strokeWidth = strokeWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dashArray = dashArray
        self.pathLengthOne = pathLengthOne
        self.opacity = opacity
        self.baseDashOffset = baseDashOffset
        self.baseTransform = baseTransform
        self.transformOrigin = transformOrigin
        self.animation = animation
    }

    // MARK: - CSS Preset Equivalents

    public static let none = SceneStyle()
    public static let accent = SceneStyle(fill: .accent)
    public static let done = SceneStyle(fill: .stateDone)
    public static let warm = SceneStyle(fill: .stateProgress)
    public static let muted = SceneStyle(fill: .textTertiary)
    public static let paper = SceneStyle(fill: .surfaceRaised, stroke: .borderStrong, strokeWidth: 1)
    public static let empty = SceneStyle(fill: nil, stroke: .borderStrong, strokeWidth: 1.5)
    public static let line = SceneStyle(fill: nil, stroke: .textTertiary, strokeWidth: 2, lineCap: .round)
    public static let lineAccent = SceneStyle(fill: nil, stroke: .accent, strokeWidth: 2, lineCap: .round)
    public static let lineDone = SceneStyle(fill: nil, stroke: .stateDone, strokeWidth: 2, lineCap: .round)

    // MARK: - Chainable Modifiers

    public func withFill(_ fill: SceneColorToken?) -> SceneStyle {
        var copy = self; copy.fill = fill; return copy
    }

    public func withFillOpacity(_ alpha: Double) -> SceneStyle {
        var copy = self; copy.fillOpacity = alpha; return copy
    }

    public func withStroke(_ stroke: SceneColorToken?, width: Double? = nil) -> SceneStyle {
        var copy = self
        copy.stroke = stroke
        if let width { copy.strokeWidth = width }
        return copy
    }

    public func withStrokeOpacity(_ alpha: Double) -> SceneStyle {
        var copy = self; copy.strokeOpacity = alpha; return copy
    }

    public func withStrokeWidth(_ width: Double) -> SceneStyle {
        var copy = self; copy.strokeWidth = width; return copy
    }

    public func withLineCap(_ cap: SceneLineCap) -> SceneStyle {
        var copy = self; copy.lineCap = cap; return copy
    }

    public func withLineJoin(_ join: SceneLineJoin) -> SceneStyle {
        var copy = self; copy.lineJoin = join; return copy
    }

    public func withDash(_ dashes: [Double]?) -> SceneStyle {
        var copy = self; copy.dashArray = dashes; return copy
    }

    public func withPathLengthOne(_ enabled: Bool = true) -> SceneStyle {
        var copy = self; copy.pathLengthOne = enabled; return copy
    }

    public func withOpacity(_ opacity: Double) -> SceneStyle {
        var copy = self; copy.opacity = opacity; return copy
    }

    public func withBaseDashOffset(_ offset: Double) -> SceneStyle {
        var copy = self; copy.baseDashOffset = offset; return copy
    }

    public func withBaseTransform(_ transform: MotionTransform) -> SceneStyle {
        var copy = self; copy.baseTransform = transform; return copy
    }

    public func withOrigin(_ origin: SceneTransformOrigin) -> SceneStyle {
        var copy = self; copy.transformOrigin = origin; return copy
    }

    public func withAnimation(_ animation: MotionAnimation?) -> SceneStyle {
        var copy = self; copy.animation = animation; return copy
    }

    public func withDelay(_ seconds: Double) -> SceneStyle {
        var copy = self
        if var anim = copy.animation {
            anim.delay = seconds
            copy.animation = anim
        }
        return copy
    }
}

/// Declarative scene graph primitive matching SVG nodes in `activity-scene.tsx`.
public indirect enum SceneNode: Sendable, Equatable {
    case rect(x: Double, y: Double, width: Double, height: Double, rx: Double = 0, ry: Double? = nil, style: SceneStyle = .none)
    case circle(cx: Double, cy: Double, r: Double, style: SceneStyle = .none)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double, style: SceneStyle = .none)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, style: SceneStyle = .none)
    case polyline(points: [ScenePoint], style: SceneStyle = .none)
    case polygon(points: [ScenePoint], style: SceneStyle = .none)
    case path(d: String, style: SceneStyle = .none)
    case text(x: Double, y: Double, string: String, fontSize: Double, fontWeight: Int = 700, anchor: SceneTextAnchor = .start, fill: SceneColorToken = .surface, style: SceneStyle = .none)
    case group(style: SceneStyle = .none, children: [SceneNode])
    case viewport(x: Double, y: Double, width: Double, height: Double, children: [SceneNode])

    /// Un-transformed local geometry bounding box for `transform-box: fill-box` origin calculation.
    public var boundingBox: CGRect {
        switch self {
        case .rect(let x, let y, let w, let h, _, _, _):
            return CGRect(x: x, y: y, width: w, height: h)
        case .circle(let cx, let cy, let r, _):
            return CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        case .ellipse(let cx, let cy, let rx, let ry, _):
            return CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        case .line(let x1, let y1, let x2, let y2, _):
            return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        case .polyline(let pts, _), .polygon(let pts, _):
            guard let first = pts.first else { return .null }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .path(let d, _):
            return SVGPathParser.parse(d).boundingBoxOfPath
        case .text(let x, let y, _, let fontSize, _, _, _, _):
            return CGRect(x: x - fontSize * 0.5, y: y - fontSize * 0.8, width: fontSize, height: fontSize)
        case .group(_, let children):
            return Self.unionBox(children)
        case .viewport(let x, let y, let w, let h, _):
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private static func unionBox(_ nodes: [SceneNode]) -> CGRect {
        var acc = CGRect.null
        for node in nodes {
            let b = node.boundingBox
            if !b.isNull {
                acc = acc.isNull ? b : acc.union(b)
            }
        }
        return acc
    }

    /// Recursively collects every `MotionAnimation` inside this node tree.
    public func collectedAnimations() -> [MotionAnimation] {
        switch self {
        case .rect(_, _, _, _, _, _, let style),
             .circle(_, _, _, let style),
             .ellipse(_, _, _, _, let style),
             .line(_, _, _, _, let style),
             .polyline(_, let style),
             .polygon(_, let style),
             .path(_, let style),
             .text(_, _, _, _, _, _, _, let style):
            return style.animation.map { [$0] } ?? []
        case .group(let style, let children):
            var out = style.animation.map { [$0] } ?? []
            for child in children { out.append(contentsOf: child.collectedAnimations()) }
            return out
        case .viewport(_, _, _, _, let children):
            return children.flatMap { $0.collectedAnimations() }
        }
    }
}

/// Complete declarative description of one SVG activity scene inside `viewBox 0 0 132 56`.
public struct ActivitySceneDefinition: Sendable, Equatable {
    public static let viewBoxSize = CGSize(width: 132, height: 56)

    public var kind: ActivitySceneKind
    public var rootAnimation: MotionAnimation?
    public var nodes: [SceneNode]

    public init(kind: ActivitySceneKind, rootAnimation: MotionAnimation? = nil, nodes: [SceneNode]) {
        self.kind = kind
        self.rootAnimation = rootAnimation
        self.nodes = nodes
    }

    /// All animations referenced by the root and descendant nodes (for fixture parity tests).
    public func collectedAnimations() -> [MotionAnimation] {
        var out = rootAnimation.map { [$0] } ?? []
        for node in nodes { out.append(contentsOf: node.collectedAnimations()) }
        return out
    }
}
