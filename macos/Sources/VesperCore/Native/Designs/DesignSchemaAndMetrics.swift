import Foundation

// MARK: - Designs Schema (parity with server/internal/design/schema.go & web/lib/designs/schema.ts)

public enum DesignMode: String, Codable, Sendable, CaseIterable, Hashable {
    case dark, light
}

public enum DesignNodeType: String, Codable, Sendable, CaseIterable, Hashable {
    case frame, component, group, section, shape, path, text, image, instance, sticky, connector

    public var isContainer: Bool {
        switch self {
        case .frame, .component, .group, .section: true
        default: false
        }
    }

    public var isBoard: Bool {
        switch self {
        case .frame, .component, .section: true
        default: false
        }
    }
}

public struct DesignGradientPaint: Codable, Sendable, Equatable, Hashable {
    public var angle: Double
    public var stops: [String]

    public init(angle: Double = 90, stops: [String]) {
        self.angle = angle
        self.stops = stops.count >= 2 ? Array(stops.prefix(2)) : ["#FFFFFF", "#000000"]
    }
}

public enum DesignPaint: Codable, Sendable, Equatable, Hashable {
    case color(String)
    case gradient(DesignGradientPaint)

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let str = try? single.decode(String.self) {
            self = .color(str)
        } else {
            self = .gradient(try single.decode(DesignGradientPaint.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .color(let s): try single.encode(DesignSchema.upperHex(s))
        case .gradient(let g):
            try single.encode(DesignGradientPaint(
                angle: DesignSchema.round2(g.angle),
                stops: g.stops.map(DesignSchema.upperHex)
            ))
        }
    }
}

public enum DesignResolvedPaint: Sendable, Equatable, Hashable {
    case color(String)
    case gradient(angle: Double, start: String, end: String)
}

public struct DesignRun: Codable, Sendable, Equatable, Hashable {
    public var text: String
    public var size: Double
    public var weight: Int?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var color: String?
    public var highlight: String?

    public init(
        text: String,
        size: Double = 16,
        weight: Int? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strike: Bool? = nil,
        color: String? = nil,
        highlight: String? = nil
    ) {
        self.text = text
        self.size = size
        self.weight = weight
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.color = color
        self.highlight = highlight
    }

    public var effectiveWeight: Int {
        weight ?? ((bold ?? false) ? 700 : 400)
    }

    enum CodingKeys: String, CodingKey {
        case text, size, weight, bold, italic, underline, strike, color, highlight
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(DesignSchema.round2(size), forKey: .size)
        let w = effectiveWeight
        if w != 400 { try c.encode(w, forKey: .weight) }
        if italic == true { try c.encode(true, forKey: .italic) }
        if underline == true { try c.encode(true, forKey: .underline) }
        if strike == true { try c.encode(true, forKey: .strike) }
        if let color { try c.encode(DesignSchema.upperHex(color), forKey: .color) }
        if let highlight { try c.encode(DesignSchema.upperHex(highlight), forKey: .highlight) }
    }
}

public struct DesignParagraph: Codable, Sendable, Equatable, Hashable {
    public var runs: [DesignRun]
    public var align: String?
    public var bullet: String?
    public var level: Int?
    public var spaceBefore: Double?
    public var lineSpacing: Double?

    public init(
        runs: [DesignRun],
        align: String? = nil,
        bullet: String? = nil,
        level: Int? = nil,
        spaceBefore: Double? = nil,
        lineSpacing: Double? = nil
    ) {
        self.runs = runs
        self.align = align
        self.bullet = bullet
        self.level = level
        self.spaceBefore = spaceBefore
        self.lineSpacing = lineSpacing
    }

    enum CodingKeys: String, CodingKey {
        case runs, align, bullet, level, spaceBefore, lineSpacing
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runs, forKey: .runs)
        if let align { try c.encode(align, forKey: .align) }
        if let bullet { try c.encode(bullet, forKey: .bullet) }
        if let level, level != 0 { try c.encode(level, forKey: .level) }
        if let spaceBefore, spaceBefore != 0 { try c.encode(DesignSchema.round2(spaceBefore), forKey: .spaceBefore) }
        if let lineSpacing, lineSpacing != 1 { try c.encode(DesignSchema.round2(lineSpacing), forKey: .lineSpacing) }
    }
}

public struct DesignTextBox: Codable, Sendable, Equatable, Hashable {
    public var paragraphs: [DesignParagraph]
    public var valign: String?

    public init(paragraphs: [DesignParagraph], valign: String? = nil) {
        self.paragraphs = paragraphs
        self.valign = valign
    }
}

public struct DesignSizing: Codable, Sendable, Equatable, Hashable {
    public var w: String? // "fixed" | "hug" | "fill"
    public var h: String?

    public init(w: String? = nil, h: String? = nil) {
        self.w = w
        self.h = h
    }
}

public struct DesignAutoLayout: Codable, Sendable, Equatable, Hashable {
    public var direction: String // "horizontal" | "vertical"
    public var gap: Double?
    public var padding: [Double]? // [top, right, bottom, left]
    public var align: String? // "start" | "center" | "end"
    public var justify: String? // "start" | "center" | "end" | "space-between"

    public init(direction: String, gap: Double? = nil, padding: [Double]? = nil, align: String? = nil, justify: String? = nil) {
        self.direction = direction
        self.gap = gap
        self.padding = padding
        self.align = align
        self.justify = justify
    }
}

public struct DesignConstraints: Codable, Sendable, Equatable, Hashable {
    public var h: String? // "left" | "right" | "left-right" | "center" | "scale"
    public var v: String? // "top" | "bottom" | "top-bottom" | "center" | "scale"

    public init(h: String? = nil, v: String? = nil) {
        self.h = h
        self.v = v
    }
}

public struct DesignOverride: Codable, Sendable, Equatable, Hashable {
    public var text: String?
    public var fill: DesignPaint?
    public var visible: Bool?

    public init(text: String? = nil, fill: DesignPaint? = nil, visible: Bool? = nil) {
        self.text = text
        self.fill = fill
        self.visible = visible
    }
}

public struct DesignEndpoint: Codable, Sendable, Equatable, Hashable {
    public var node: String
    public var anchor: String? // "auto" | "top" | "right" | "bottom" | "left"

    public init(node: String, anchor: String? = nil) {
        self.node = node
        self.anchor = anchor
    }
}

public struct DesignNode: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var type: DesignNodeType
    public var name: String?
    // Box fields (absent on connector)
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rotation: Double?
    public var opacity: Double?
    public var visible: Bool?
    public var locked: Bool?
    public var sizing: DesignSizing?
    public var absolute: Bool?
    public var constraints: DesignConstraints?
    // Styled fields
    public var fill: DesignPaint?
    public var stroke: String?
    public var strokeWidth: Double?
    public var dash: String?
    // Container fields
    public var children: [DesignNode]?
    public var radius: Double?
    public var clip: Bool?
    public var mode: DesignMode?
    public var autoLayout: DesignAutoLayout?
    public var preset: String?
    public var linkedTickets: [String]?
    public var linkedPaths: [String]?
    // Shape fields
    public var shape: String?
    public var shapeText: DesignTextBox?
    // Path fields
    public var d: String?
    public var cap: String?
    public var join: String?
    // Text fields
    public var paragraphs: [DesignParagraph]?
    public var valign: String?
    // Image fields
    public var asset: String?
    public var fit: String?
    public var crop: SlideCrop?
    public var alt: String?
    // Instance fields
    public var component: String?
    public var overrides: [String: DesignOverride]?
    // Sticky fields
    public var stickyText: String?
    public var stickyColor: String?
    public var author: String?
    // Connector fields
    public var from: DesignEndpoint?
    public var to: DesignEndpoint?
    public var route: String?
    public var label: String?
    public var startArrow: String?
    public var endArrow: String?
    public var points: [[Double]]?

    public init(
        id: String,
        type: DesignNodeType,
        name: String? = nil,
        x: Double = 0,
        y: Double = 0,
        w: Double = 0,
        h: Double = 0,
        rotation: Double? = nil,
        opacity: Double? = nil,
        visible: Bool? = nil,
        locked: Bool? = nil,
        sizing: DesignSizing? = nil,
        absolute: Bool? = nil,
        constraints: DesignConstraints? = nil,
        fill: DesignPaint? = nil,
        stroke: String? = nil,
        strokeWidth: Double? = nil,
        dash: String? = nil,
        children: [DesignNode]? = nil,
        radius: Double? = nil,
        clip: Bool? = nil,
        mode: DesignMode? = nil,
        autoLayout: DesignAutoLayout? = nil,
        preset: String? = nil,
        linkedTickets: [String]? = nil,
        linkedPaths: [String]? = nil,
        shape: String? = nil,
        shapeText: DesignTextBox? = nil,
        d: String? = nil,
        cap: String? = nil,
        join: String? = nil,
        paragraphs: [DesignParagraph]? = nil,
        valign: String? = nil,
        asset: String? = nil,
        fit: String? = nil,
        crop: SlideCrop? = nil,
        alt: String? = nil,
        component: String? = nil,
        overrides: [String: DesignOverride]? = nil,
        stickyText: String? = nil,
        stickyColor: String? = nil,
        author: String? = nil,
        from: DesignEndpoint? = nil,
        to: DesignEndpoint? = nil,
        route: String? = nil,
        label: String? = nil,
        startArrow: String? = nil,
        endArrow: String? = nil,
        points: [[Double]]? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rotation = rotation
        self.opacity = opacity
        self.visible = visible
        self.locked = locked
        self.sizing = sizing
        self.absolute = absolute
        self.constraints = constraints
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.dash = dash
        self.children = children
        self.radius = radius
        self.clip = clip
        self.mode = mode
        self.autoLayout = autoLayout
        self.preset = preset
        self.linkedTickets = linkedTickets
        self.linkedPaths = linkedPaths
        self.shape = shape
        self.shapeText = shapeText
        self.d = d
        self.cap = cap
        self.join = join
        self.paragraphs = paragraphs
        self.valign = valign
        self.asset = asset
        self.fit = fit
        self.crop = crop
        self.alt = alt
        self.component = component
        self.overrides = overrides
        self.stickyText = stickyText
        self.stickyColor = stickyColor
        self.author = author
        self.from = from
        self.to = to
        self.route = route
        self.label = label
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.points = points
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, x, y, w, h, rotation, opacity, visible, locked, sizing, absolute, constraints
        case fill, stroke, strokeWidth = "stroke_width", dash
        case children, radius, clip, mode, autoLayout = "auto_layout", preset
        case linkedTickets = "linked_tickets", linkedPaths = "linked_paths"
        case shape, text, d, cap, join, paragraphs, valign
        case asset, fit, crop, alt
        case component, overrides
        case color, author
        case from, to, route, label, startArrow = "start_arrow", endArrow = "end_arrow", points
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(DesignNodeType.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        sizing = try c.decodeIfPresent(DesignSizing.self, forKey: .sizing)
        absolute = try c.decodeIfPresent(Bool.self, forKey: .absolute)
        constraints = try c.decodeIfPresent(DesignConstraints.self, forKey: .constraints)
        fill = try c.decodeIfPresent(DesignPaint.self, forKey: .fill)
        stroke = try c.decodeIfPresent(String.self, forKey: .stroke)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth)
        dash = try c.decodeIfPresent(String.self, forKey: .dash)
        children = try c.decodeIfPresent([DesignNode].self, forKey: .children)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        clip = try c.decodeIfPresent(Bool.self, forKey: .clip)
        mode = try c.decodeIfPresent(DesignMode.self, forKey: .mode)
        autoLayout = try c.decodeIfPresent(DesignAutoLayout.self, forKey: .autoLayout)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        linkedTickets = try c.decodeIfPresent([String].self, forKey: .linkedTickets)
        linkedPaths = try c.decodeIfPresent([String].self, forKey: .linkedPaths)
        shape = try c.decodeIfPresent(String.self, forKey: .shape)
        if type == .shape {
            shapeText = try c.decodeIfPresent(DesignTextBox.self, forKey: .text)
            stickyText = nil
        } else if type == .sticky {
            stickyText = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            shapeText = nil
        } else {
            shapeText = nil
            stickyText = nil
        }
        d = try c.decodeIfPresent(String.self, forKey: .d)
        cap = try c.decodeIfPresent(String.self, forKey: .cap)
        join = try c.decodeIfPresent(String.self, forKey: .join)
        paragraphs = try c.decodeIfPresent([DesignParagraph].self, forKey: .paragraphs)
        valign = try c.decodeIfPresent(String.self, forKey: .valign)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        fit = try c.decodeIfPresent(String.self, forKey: .fit)
        crop = try c.decodeIfPresent(SlideCrop.self, forKey: .crop)
        alt = try c.decodeIfPresent(String.self, forKey: .alt)
        component = try c.decodeIfPresent(String.self, forKey: .component)
        overrides = try c.decodeIfPresent([String: DesignOverride].self, forKey: .overrides)
        stickyColor = try c.decodeIfPresent(String.self, forKey: .color)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        from = try c.decodeIfPresent(DesignEndpoint.self, forKey: .from)
        to = try c.decodeIfPresent(DesignEndpoint.self, forKey: .to)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        startArrow = try c.decodeIfPresent(String.self, forKey: .startArrow)
        endArrow = try c.decodeIfPresent(String.self, forKey: .endArrow)
        points = try c.decodeIfPresent([[Double]].self, forKey: .points)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        if let name { try c.encode(name, forKey: .name) }
        if visible == false { try c.encode(false, forKey: .visible) }

        if type == .connector {
            if let from { try c.encode(from, forKey: .from) }
            if let to { try c.encode(to, forKey: .to) }
            if let route { try c.encode(route, forKey: .route) }
            if let label { try c.encode(label, forKey: .label) }
            if let stroke { try c.encode(DesignSchema.upperHex(stroke), forKey: .stroke) }
            if let strokeWidth { try c.encode(DesignSchema.round2(strokeWidth), forKey: .strokeWidth) }
            if let dash { try c.encode(dash, forKey: .dash) }
            if let startArrow { try c.encode(startArrow, forKey: .startArrow) }
            if let endArrow { try c.encode(endArrow, forKey: .endArrow) }
            if let points {
                try c.encode(points.map { $0.map(DesignSchema.round2) }, forKey: .points)
            }
            return
        }

        // Common box fields
        try c.encode(DesignSchema.round2(x), forKey: .x)
        try c.encode(DesignSchema.round2(y), forKey: .y)
        try c.encode(DesignSchema.round2(max(0, w)), forKey: .w)
        try c.encode(DesignSchema.round2(max(0, h)), forKey: .h)
        if let rotation, rotation != 0 { try c.encode(DesignSchema.round2(rotation), forKey: .rotation) }
        if let opacity, opacity != 1 { try c.encode(DesignSchema.round2(opacity), forKey: .opacity) }
        if locked == true { try c.encode(true, forKey: .locked) }
        if let sizing, sizing.w != nil || sizing.h != nil { try c.encode(sizing, forKey: .sizing) }
        if absolute == true { try c.encode(true, forKey: .absolute) }
        if let constraints, constraints.h != nil || constraints.v != nil { try c.encode(constraints, forKey: .constraints) }

        switch type {
        case .frame, .component:
            if let fill { try c.encode(fill, forKey: .fill) }
            if let stroke { try c.encode(DesignSchema.upperHex(stroke), forKey: .stroke) }
            if let strokeWidth { try c.encode(DesignSchema.round2(strokeWidth), forKey: .strokeWidth) }
            if let dash { try c.encode(dash, forKey: .dash) }
            try c.encode(children ?? [], forKey: .children)
            if let radius { try c.encode(DesignSchema.round2(radius), forKey: .radius) }
            if let clip { try c.encode(clip, forKey: .clip) }
            if let mode { try c.encode(mode, forKey: .mode) }
            if let autoLayout { try c.encode(autoLayout, forKey: .autoLayout) }
            if let preset { try c.encode(preset, forKey: .preset) }
            if let linkedTickets, !linkedTickets.isEmpty { try c.encode(linkedTickets, forKey: .linkedTickets) }
            if let linkedPaths, !linkedPaths.isEmpty { try c.encode(linkedPaths, forKey: .linkedPaths) }
        case .group:
            try c.encode(children ?? [], forKey: .children)
        case .section:
            if case .color(let hex) = fill { try c.encode(DesignSchema.upperHex(hex), forKey: .fill) }
            try c.encode(children ?? [], forKey: .children)
        case .shape:
            if let fill { try c.encode(fill, forKey: .fill) }
            if let stroke { try c.encode(DesignSchema.upperHex(stroke), forKey: .stroke) }
            if let strokeWidth { try c.encode(DesignSchema.round2(strokeWidth), forKey: .strokeWidth) }
            if let dash { try c.encode(dash, forKey: .dash) }
            try c.encode(shape ?? "rect", forKey: .shape)
            if let radius { try c.encode(DesignSchema.round2(radius), forKey: .radius) }
            if let shapeText { try c.encode(shapeText, forKey: .text) }
        case .path:
            if let fill { try c.encode(fill, forKey: .fill) }
            if let stroke { try c.encode(DesignSchema.upperHex(stroke), forKey: .stroke) }
            if let strokeWidth { try c.encode(DesignSchema.round2(strokeWidth), forKey: .strokeWidth) }
            if let dash { try c.encode(dash, forKey: .dash) }
            try c.encode(d ?? "M0 0 L10 10", forKey: .d)
            if let cap { try c.encode(cap, forKey: .cap) }
            if let join { try c.encode(join, forKey: .join) }
        case .text:
            try c.encode(paragraphs ?? [DesignParagraph(runs: [DesignRun(text: "", size: 16)])], forKey: .paragraphs)
            if let valign { try c.encode(valign, forKey: .valign) }
        case .image:
            try c.encode(asset ?? "", forKey: .asset)
            if let fit { try c.encode(fit, forKey: .fit) }
            if let crop { try c.encode(crop, forKey: .crop) }
            if let radius { try c.encode(DesignSchema.round2(radius), forKey: .radius) }
            if let alt { try c.encode(alt, forKey: .alt) }
        case .instance:
            try c.encode(component ?? "", forKey: .component)
            if let overrides, !overrides.isEmpty { try c.encode(overrides, forKey: .overrides) }
        case .sticky:
            try c.encode(stickyText ?? "", forKey: .text)
            if let stickyColor { try c.encode(stickyColor, forKey: .color) }
            if let author { try c.encode(author, forKey: .author) }
        case .connector:
            break
        }
    }
}

public struct DesignPage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var background: String?
    public var children: [DesignNode]

    public init(id: String, name: String, background: String? = nil, children: [DesignNode] = []) {
        self.id = id
        self.name = name
        self.background = background
        self.children = children
    }
}

public struct DesignLink: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var trigger: String // "click" | "hover" | "after-delay"
    public var delayMs: Int?
    public var transition: String // "instant" | "dissolve" | "slide-left" | "slide-right" | "slide-up" | "slide-down" | "smart-animate"
    public var durationMs: Int?

    public init(id: String, from: String, to: String, trigger: String = "click", delayMs: Int? = nil, transition: String = "dissolve", durationMs: Int? = 300) {
        self.id = id
        self.from = from
        self.to = to
        self.trigger = trigger
        self.delayMs = delayMs
        self.transition = transition
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case id, from, to, trigger, delayMs = "delay_ms", transition, durationMs = "duration_ms"
    }
}

public struct DesignToken: Codable, Sendable, Equatable, Hashable {
    public var kind: String // "color" | "dimension"
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct DesignTokenModes: Codable, Sendable, Equatable, Hashable {
    public var dark: [String: DesignToken]
    public var light: [String: DesignToken]?

    public init(dark: [String: DesignToken] = [:], light: [String: DesignToken]? = nil) {
        self.dark = dark
        self.light = light
    }
}

public struct DesignTokenSet: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var source: String?
    public var modes: DesignTokenModes

    public init(name: String, source: String? = nil, modes: DesignTokenModes) {
        self.name = name
        self.source = source
        self.modes = modes
    }
}

public struct DesignTokensRef: Codable, Sendable, Equatable, Hashable {
    public var set: String
    public var source: String?
    public var hash: String
    public var syncedAt: String

    enum CodingKeys: String, CodingKey {
        case set, source, hash, syncedAt = "synced_at"
    }
}

public struct DesignAsset: Codable, Sendable, Equatable, Hashable {
    public var mime: String
    public var w: Int
    public var h: Int
    public var alt: String?
    public var file: String?

    public init(mime: String, w: Int, h: Int, alt: String? = nil, file: String? = nil) {
        self.mime = mime
        self.w = w
        self.h = h
        self.alt = alt
        self.file = file
    }
}

public struct DesignDocument: Codable, Sendable, Equatable, Hashable {
    public var schema: Int
    public var mode: DesignMode
    public var tokensRef: DesignTokensRef?
    public var tokenSets: [String: DesignTokenSet]
    public var assets: [String: DesignAsset]
    public var pages: [DesignPage]
    public var links: [DesignLink]

    public init(
        schema: Int = 1,
        mode: DesignMode = .dark,
        tokensRef: DesignTokensRef? = nil,
        tokenSets: [String: DesignTokenSet] = [:],
        assets: [String: DesignAsset] = [:],
        pages: [DesignPage] = [DesignPage(id: "p_page1", name: "Page 1")],
        links: [DesignLink] = []
    ) {
        self.schema = schema
        self.mode = mode
        self.tokensRef = tokensRef
        self.tokenSets = tokenSets
        self.assets = assets
        self.pages = pages
        self.links = links
    }

    enum CodingKeys: String, CodingKey {
        case schema, mode, tokensRef = "tokens_ref", tokenSets = "token_sets", assets, pages, links
    }
}

public enum DesignSchema: Sendable {
    public static func round2(_ v: Double) -> Double {
        let r = (v * 100).rounded() / 100
        return r == 0 ? 0 : r
    }

    public static func upperHex(_ s: String) -> String {
        guard s.hasPrefix("#"), s.count == 7 || s.count == 9 else { return s }
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if s.dropFirst().unicodeScalars.allSatisfy({ hexChars.contains($0) }) {
            return s.uppercased()
        }
        return s
    }

    public static func parse(_ json: String) throws -> DesignDocument {
        try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
    }

    public static func encodeCanonical(_ doc: DesignDocument) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(doc)
        return String(decoding: data, as: UTF8.self)
    }

    public static func newId(prefix: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var s = ""
        s.reserveCapacity(10)
        for _ in 0..<10 { s.append(alphabet[Int.random(in: 0..<32)]) }
        return "\(prefix)_\(s)"
    }
}

// MARK: - Inter Advance Metrics (exact parity with web/lib/designs/measure.ts)

public struct DesignLineDecoMetrics: Codable, Sendable, Equatable {
    public var pos: Double
    public var thick: Double
}

public struct DesignFaceMetrics: Sendable {
    public let advances: [UInt32: Double]
    public let missing: Double
    public let asc: Double
    public let desc: Double
    public let underline: DesignLineDecoMetrics
    public let strike: DesignLineDecoMetrics
}

public enum DesignMetrics: Sendable {
    private struct RawFace: Codable {
        let adv: [String: Double]
        let missing: Double
        let asc: Double
        let desc: Double
        let underline: DesignLineDecoMetrics
        let strike: DesignLineDecoMetrics
    }

    private static let fallbackFace = DesignFaceMetrics(
        advances: [:],
        missing: 0.6,
        asc: 0.9688,
        desc: 0.2412,
        underline: .init(pos: 0.1699, thick: 0.0684),
        strike: .init(pos: 0.3276, thick: 0.0684)
    )

    private static let faces: [String: DesignFaceMetrics] = {
        guard let url = Bundle.module.url(forResource: "inter-metrics", withExtension: "json", subdirectory: "designs")
            ?? Bundle.module.url(forResource: "inter-metrics", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: RawFace].self, from: data) else {
            return ["400": fallbackFace]
        }
        var out: [String: DesignFaceMetrics] = [:]
        for (k, v) in raw {
            var map: [UInt32: Double] = [:]
            map.reserveCapacity(v.adv.count)
            for (cpStr, adv) in v.adv {
                if let cp = UInt32(cpStr) { map[cp] = adv }
            }
            out[k] = DesignFaceMetrics(advances: map, missing: v.missing, asc: v.asc, desc: v.desc, underline: v.underline, strike: v.strike)
        }
        return out
    }()

    public static func face(weight: Int, italic: Bool) -> DesignFaceMetrics {
        let key = "\(weight)\(italic ? "i" : "")"
        return faces[key] ?? faces["400"] ?? fallbackFace
    }

    /// Width in design px of `text` in Inter at a weight and size (matches `web/lib/designs/measure.ts`).
    public static func measure(text: String, weight: Int, italic: Bool, size: Double) -> Double {
        let f = face(weight: weight, italic: italic)
        var w = 0.0
        for scalar in text.unicodeScalars {
            w += f.advances[scalar.value] ?? f.missing
        }
        return w * size
    }
}
