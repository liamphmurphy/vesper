import CoreGraphics
import Foundation

// MARK: - Slides Schema (parity with server/internal/deck and web/lib/slides/schema.ts)

public enum SlideConstants {
    public static let width: Double = 1920
    public static let height: Double = 1080
    public static let inset: Double = 16
    public static let lineHeightMultiplier: Double = 1.2
    public static let bulletIndent: Double = 60
    public static let strikePosition: Double = 0.26
}

public enum SlideFontSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case sans, serif, mono

    public var displayName: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    public var systemFontName: String {
        switch self {
        case .sans: "Helvetica Neue"
        case .serif: "Georgia"
        case .mono: "Menlo"
        }
    }

    public var officeFontName: String {
        switch self {
        case .sans: "Arial"
        case .serif: "Georgia"
        case .mono: "Courier New"
        }
    }

    public var metrics: (asc: Double, desc: Double) {
        switch self {
        case .sans: (0.9053, 0.2119)
        case .serif: (0.8911, 0.2163)
        case .mono: (0.8325, 0.3003)
        }
    }
}

public enum SlideThemeColorKey: String, Codable, Sendable, CaseIterable, Hashable {
    case background, text, heading, accent, accent2, muted, surface
}

public struct SlideGradient: Codable, Sendable, Equatable, Hashable {
    public var type: String
    public var angle: Double
    public var stops: [String]

    public init(type: String = "linear", angle: Double = 90, stops: [String]) {
        self.type = type
        self.angle = angle
        self.stops = stops.count >= 2 ? Array(stops.prefix(2)) : ["#FFFFFF", "#000000"]
    }
}

public enum SlideFill: Codable, Sendable, Equatable, Hashable {
    case solid(String)
    case gradient(SlideGradient)

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let str = try? single.decode(String.self) {
            self = .solid(str)
        } else {
            self = .gradient(try single.decode(SlideGradient.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .solid(let s): try single.encode(s)
        case .gradient(let g): try single.encode(g)
        }
    }
}

public enum SlideResolvedPaint: Sendable, Equatable, Hashable {
    case solid(String)
    case gradient(angle: Double, start: String, end: String)
}

public enum SlideDash: String, Codable, Sendable, CaseIterable, Hashable {
    case solid, dash, dot, dashDot, longDash

    public var label: String {
        switch self {
        case .solid: "Solid"
        case .dash: "Dash"
        case .dot: "Dot"
        case .dashDot: "Dash-dot"
        case .longDash: "Long dash"
        }
    }

    public var patternMultipliers: [Double] {
        switch self {
        case .solid: []
        case .dash: [4, 3]
        case .dot: [1, 1]
        case .dashDot: [4, 3, 1, 3]
        case .longDash: [8, 3]
        }
    }

    public var pptxValue: String {
        switch self {
        case .solid: "solid"
        case .dash: "dash"
        case .dot: "sysDot"
        case .dashDot: "dashDot"
        case .longDash: "lgDash"
        }
    }

    public func lengths(strokeWidth: Double) -> [Double] {
        patternMultipliers.map { $0 * strokeWidth }
    }
}

public struct SlideRun: Codable, Sendable, Equatable, Hashable {
    public var text: String
    public var size: Double
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var color: String?
    public var highlight: String?
    public var font: String?

    public init(
        text: String,
        size: Double = 44,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strike: Bool? = nil,
        color: String? = nil,
        highlight: String? = nil,
        font: String? = nil
    ) {
        self.text = text
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.color = color
        self.highlight = highlight
        self.font = font
    }
}

public struct SlideParagraph: Codable, Sendable, Equatable, Hashable {
    public var runs: [SlideRun]
    public var align: String?
    public var bullet: String?
    public var level: Int?
    public var spaceBefore: Double?
    public var lineSpacing: Double?

    public init(
        runs: [SlideRun],
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
}

public struct SlideTextBox: Codable, Sendable, Equatable, Hashable {
    public var paragraphs: [SlideParagraph]
    public var valign: String?

    public init(paragraphs: [SlideParagraph], valign: String? = nil) {
        self.paragraphs = paragraphs
        self.valign = valign
    }
}

public struct SlideFrame: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct SlideCrop: Codable, Sendable, Equatable, Hashable {
    public var l: Double
    public var t: Double
    public var r: Double
    public var b: Double

    public init(l: Double = 0, t: Double = 0, r: Double = 0, b: Double = 0) {
        self.l = l
        self.t = t
        self.r = r
        self.b = b
    }
}

public enum SlideShapeKind: String, Codable, Sendable, CaseIterable, Hashable {
    case rect, roundRect, ellipse
    case triangle, rtTriangle, diamond, pentagon, hexagon, octagon
    case rightArrow, leftArrow, upArrow, downArrow, chevron, homePlate
    case wedgeRectCallout, wedgeRoundRectCallout
    case star5, plus, donut, heart

    public var label: String {
        switch self {
        case .rect: "Rectangle"
        case .roundRect: "Rounded rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .rtTriangle: "Right triangle"
        case .diamond: "Diamond"
        case .pentagon: "Pentagon"
        case .hexagon: "Hexagon"
        case .octagon: "Octagon"
        case .rightArrow: "Right arrow"
        case .leftArrow: "Left arrow"
        case .upArrow: "Up arrow"
        case .downArrow: "Down arrow"
        case .chevron: "Chevron"
        case .homePlate: "Pentagon arrow"
        case .wedgeRectCallout: "Rectangle callout"
        case .wedgeRoundRectCallout: "Rounded callout"
        case .star5: "Star"
        case .plus: "Plus"
        case .donut: "Donut"
        case .heart: "Heart"
        }
    }

    public var category: String {
        switch self {
        case .rect, .roundRect, .ellipse, .triangle, .rtTriangle, .diamond, .pentagon, .hexagon, .octagon:
            "Basics"
        case .rightArrow, .leftArrow, .upArrow, .downArrow, .chevron, .homePlate:
            "Arrows & flow"
        case .wedgeRectCallout, .wedgeRoundRectCallout:
            "Callouts"
        case .star5, .plus, .donut, .heart:
            "Accents"
        }
    }

    public var isPreset: Bool {
        self != .rect && self != .roundRect && self != .ellipse
    }
}

public struct SlideTextElement: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var frame: SlideFrame
    public var rotation: Double?
    public var placeholder: String?
    public var paragraphs: [SlideParagraph]
    public var valign: String?

    public init(
        id: String,
        frame: SlideFrame,
        rotation: Double? = nil,
        placeholder: String? = nil,
        paragraphs: [SlideParagraph],
        valign: String? = nil
    ) {
        self.id = id
        self.type = "text"
        self.frame = frame
        self.rotation = rotation
        self.placeholder = placeholder
        self.paragraphs = paragraphs
        self.valign = valign
    }

    public var textBox: SlideTextBox {
        SlideTextBox(paragraphs: paragraphs, valign: valign)
    }
}

public struct SlideShapeElement: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var frame: SlideFrame
    public var rotation: Double?
    public var placeholder: String?
    public var shape: SlideShapeKind
    public var fill: SlideFill?
    public var fillOpacity: Double?
    public var stroke: String?
    public var strokeWidth: Double?
    public var strokeOpacity: Double?
    public var dash: SlideDash?
    public var radius: Double?
    public var text: SlideTextBox?

    public init(
        id: String,
        frame: SlideFrame,
        rotation: Double? = nil,
        placeholder: String? = nil,
        shape: SlideShapeKind,
        fill: SlideFill? = nil,
        fillOpacity: Double? = nil,
        stroke: String? = nil,
        strokeWidth: Double? = nil,
        strokeOpacity: Double? = nil,
        dash: SlideDash? = nil,
        radius: Double? = nil,
        text: SlideTextBox? = nil
    ) {
        self.id = id
        self.type = "shape"
        self.frame = frame
        self.rotation = rotation
        self.placeholder = placeholder
        self.shape = shape
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.strokeOpacity = strokeOpacity
        self.dash = dash
        self.radius = radius
        self.text = text
    }
}

public struct SlideLineElement: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var frame: SlideFrame
    public var rotation: Double?
    public var placeholder: String?
    public var stroke: String
    public var strokeWidth: Double
    public var strokeOpacity: Double?
    public var dash: SlideDash?
    public var endArrow: Bool?
    public var startArrow: Bool?

    public init(
        id: String,
        frame: SlideFrame,
        rotation: Double? = nil,
        placeholder: String? = nil,
        stroke: String = "accent",
        strokeWidth: Double = 6,
        strokeOpacity: Double? = nil,
        dash: SlideDash? = nil,
        endArrow: Bool? = nil,
        startArrow: Bool? = nil
    ) {
        self.id = id
        self.type = "line"
        self.frame = frame
        self.rotation = rotation
        self.placeholder = placeholder
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.strokeOpacity = strokeOpacity
        self.dash = dash
        self.endArrow = endArrow
        self.startArrow = startArrow
    }
}

public struct SlideImageElement: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var frame: SlideFrame
    public var rotation: Double?
    public var placeholder: String?
    public var asset: String
    public var crop: SlideCrop?
    public var alt: String?
    public var opacity: Double?

    public init(
        id: String,
        frame: SlideFrame,
        rotation: Double? = nil,
        placeholder: String? = nil,
        asset: String,
        crop: SlideCrop? = nil,
        alt: String? = nil,
        opacity: Double? = nil
    ) {
        self.id = id
        self.type = "image"
        self.frame = frame
        self.rotation = rotation
        self.placeholder = placeholder
        self.asset = asset
        self.crop = crop
        self.alt = alt
        self.opacity = opacity
    }
}

public struct SlideGroupElement: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: String
    public var frame: SlideFrame
    public var rotation: Double?
    public var placeholder: String?
    public var elements: [SlideElement]

    public init(id: String, frame: SlideFrame, elements: [SlideElement]) {
        self.id = id
        self.type = "group"
        self.frame = frame
        self.rotation = nil
        self.placeholder = nil
        self.elements = elements
    }
}

public enum SlideElement: Codable, Sendable, Equatable, Hashable, Identifiable {
    case text(SlideTextElement)
    case shape(SlideShapeElement)
    case line(SlideLineElement)
    case image(SlideImageElement)
    case group(SlideGroupElement)

    private enum DiscriminatorKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try SlideTextElement(from: decoder))
        case "shape": self = .shape(try SlideShapeElement(from: decoder))
        case "line": self = .line(try SlideLineElement(from: decoder))
        case "image": self = .image(try SlideImageElement(from: decoder))
        case "group": self = .group(try SlideGroupElement(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown slide element type: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let e): try e.encode(to: encoder)
        case .shape(let e): try e.encode(to: encoder)
        case .line(let e): try e.encode(to: encoder)
        case .image(let e): try e.encode(to: encoder)
        case .group(let e): try e.encode(to: encoder)
        }
    }

    public var id: String {
        switch self {
        case .text(let e): e.id
        case .shape(let e): e.id
        case .line(let e): e.id
        case .image(let e): e.id
        case .group(let e): e.id
        }
    }

    public var frame: SlideFrame {
        get {
            switch self {
            case .text(let e): e.frame
            case .shape(let e): e.frame
            case .line(let e): e.frame
            case .image(let e): e.frame
            case .group(let e): e.frame
            }
        }
        set {
            switch self {
            case .text(var e): e.frame = newValue; self = .text(e)
            case .shape(var e): e.frame = newValue; self = .shape(e)
            case .line(var e): e.frame = newValue; self = .line(e)
            case .image(var e): e.frame = newValue; self = .image(e)
            case .group(var e): e.frame = newValue; self = .group(e)
            }
        }
    }

    public var rotation: Double? {
        get {
            switch self {
            case .text(let e): e.rotation
            case .shape(let e): e.rotation
            case .line(let e): e.rotation
            case .image(let e): e.rotation
            case .group(let e): e.rotation
            }
        }
        set {
            switch self {
            case .text(var e): e.rotation = newValue; self = .text(e)
            case .shape(var e): e.rotation = newValue; self = .shape(e)
            case .line(var e): e.rotation = newValue; self = .line(e)
            case .image(var e): e.rotation = newValue; self = .image(e)
            case .group(var e): e.rotation = newValue; self = .group(e)
            }
        }
    }

    public var placeholder: String? {
        get {
            switch self {
            case .text(let e): e.placeholder
            case .shape(let e): e.placeholder
            case .line(let e): e.placeholder
            case .image(let e): e.placeholder
            case .group(let e): e.placeholder
            }
        }
        set {
            switch self {
            case .text(var e): e.placeholder = newValue; self = .text(e)
            case .shape(var e): e.placeholder = newValue; self = .shape(e)
            case .line(var e): e.placeholder = newValue; self = .line(e)
            case .image(var e): e.placeholder = newValue; self = .image(e)
            case .group(var e): e.placeholder = newValue; self = .group(e)
            }
        }
    }

    public var textBox: SlideTextBox? {
        switch self {
        case .text(let e): e.textBox
        case .shape(let e): e.text
        default: nil
        }
    }

    public var isImageSlot: Bool {
        if case .text(let e) = self, e.placeholder == "image" { return true }
        return false
    }

    public func withText(_ paragraphs: [SlideParagraph]) -> SlideElement {
        switch self {
        case .text(var e):
            e.paragraphs = paragraphs
            return .text(e)
        case .shape(var e):
            var tb = e.text ?? SlideTextBox(paragraphs: paragraphs, valign: "middle")
            tb.paragraphs = paragraphs
            e.text = tb
            return .shape(e)
        default:
            return self
        }
    }

    public var plainText: String {
        switch self {
        case .image(let img):
            return img.alt ?? ""
        default:
            return (textBox?.paragraphs ?? [])
                .map { $0.runs.map(\.text).joined() }
                .joined(separator: "\n")
        }
    }
}

public enum SlideLayoutKind: String, Codable, Sendable, CaseIterable, Hashable {
    case title
    case titleBody = "title-body"
    case twoColumn = "two-column"
    case imageRight = "image-right"
    case section
    case blank
    case quote
    case bigNumber = "big-number"
    case threeColumn = "three-column"
    case comparison
    case imageFull = "image-full"
    case imageLeft = "image-left"
    case agenda
    case closing

    public var label: String {
        switch self {
        case .title: "Title"
        case .titleBody: "Title and body"
        case .twoColumn: "Two columns"
        case .imageRight: "Text and image"
        case .section: "Section"
        case .blank: "Blank"
        case .quote: "Quote"
        case .bigNumber: "Big number"
        case .threeColumn: "Three columns"
        case .comparison: "Comparison"
        case .imageFull: "Full-bleed image"
        case .imageLeft: "Image and text"
        case .agenda: "Agenda"
        case .closing: "Closing"
        }
    }
}

public struct SlideBackground: Codable, Sendable, Equatable, Hashable {
    public var color: SlideFill

    public init(color: SlideFill) {
        self.color = color
    }
}

public struct Slide: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var layout: SlideLayoutKind
    public var background: SlideBackground?
    public var notes: String?
    public var hidden: Bool?
    public var elements: [SlideElement]

    public init(
        id: String,
        layout: SlideLayoutKind,
        background: SlideBackground? = nil,
        notes: String? = nil,
        hidden: Bool? = nil,
        elements: [SlideElement]
    ) {
        self.id = id
        self.layout = layout
        self.background = background
        self.notes = notes
        self.hidden = hidden
        self.elements = elements
    }
}

public struct SlideThemeFonts: Codable, Sendable, Equatable, Hashable {
    public var heading: SlideFontSlot
    public var body: SlideFontSlot

    public init(heading: SlideFontSlot = .sans, body: SlideFontSlot = .sans) {
        self.heading = heading
        self.body = body
    }
}

public struct SlideThemeColors: Codable, Sendable, Equatable, Hashable {
    public var background: String
    public var text: String
    public var heading: String
    public var accent: String
    public var accent2: String
    public var muted: String
    public var surface: String

    public init(background: String, text: String, heading: String, accent: String, accent2: String, muted: String, surface: String) {
        self.background = background
        self.text = text
        self.heading = heading
        self.accent = accent
        self.accent2 = accent2
        self.muted = muted
        self.surface = surface
    }

    public subscript(key: SlideThemeColorKey) -> String {
        get {
            switch key {
            case .background: background
            case .text: text
            case .heading: heading
            case .accent: accent
            case .accent2: accent2
            case .muted: muted
            case .surface: surface
            }
        }
        set {
            switch key {
            case .background: background = newValue
            case .text: text = newValue
            case .heading: heading = newValue
            case .accent: accent = newValue
            case .accent2: accent2 = newValue
            case .muted: muted = newValue
            case .surface: surface = newValue
            }
        }
    }
}

public struct SlideTheme: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var fonts: SlideThemeFonts
    public var colors: SlideThemeColors

    public init(name: String, fonts: SlideThemeFonts, colors: SlideThemeColors) {
        self.name = name
        self.fonts = fonts
        self.colors = colors
    }
}

public struct SlideAsset: Codable, Sendable, Equatable, Hashable {
    public var mime: String
    public var w: Int
    public var h: Int
    public var alt: String?

    public init(mime: String, w: Int, h: Int, alt: String? = nil) {
        self.mime = mime
        self.w = w
        self.h = h
        self.alt = alt
    }
}

public struct SlideDeckSize: Codable, Sendable, Equatable, Hashable {
    public var w: Double
    public var h: Double

    public init(w: Double = SlideConstants.width, h: Double = SlideConstants.height) {
        self.w = w
        self.h = h
    }
}

public struct SlideDeck: Codable, Sendable, Equatable, Hashable {
    public var schema: Int
    public var size: SlideDeckSize
    public var theme: SlideTheme
    public var assets: [String: SlideAsset]
    public var slides: [Slide]

    public init(
        schema: Int = 1,
        size: SlideDeckSize = SlideDeckSize(),
        theme: SlideTheme = SlideSchema.builtInThemes["light"]!,
        assets: [String: SlideAsset] = [:],
        slides: [Slide]
    ) {
        self.schema = schema
        self.size = size
        self.theme = theme
        self.assets = assets
        self.slides = slides
    }
}

// MARK: - Schema Helpers, Built-in Themes & Layout Placeholders

public enum SlideSchema: Sendable {
    public static let themeOrder: [String] = [
        "light", "dark", "paper", "contrast", "dusk", "ocean", "forest", "sunset", "mono", "blueprint"
    ]

    public static let builtInThemes: [String: SlideTheme] = [
        "light": SlideTheme(name: "Light", fonts: .init(heading: .sans, body: .sans), colors: .init(background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#5F6673", surface: "#F3F5F9")),
        "dark": SlideTheme(name: "Dark", fonts: .init(heading: .sans, body: .sans), colors: .init(background: "#14151A", text: "#E6E7EB", heading: "#FFFFFF", accent: "#8B9CFF", accent2: "#F2B35E", muted: "#9AA0AE", surface: "#1F2129")),
        "paper": SlideTheme(name: "Paper", fonts: .init(heading: .serif, body: .serif), colors: .init(background: "#FBF8F1", text: "#2B2723", heading: "#1A1612", accent: "#A2462E", accent2: "#3F6B5C", muted: "#655D53", surface: "#F1EBDD")),
        "contrast": SlideTheme(name: "Contrast", fonts: .init(heading: .sans, body: .serif), colors: .init(background: "#FFFFFF", text: "#000000", heading: "#000000", accent: "#D7263D", accent2: "#1B998B", muted: "#4A4A4A", surface: "#F0F0F0")),
        "dusk": SlideTheme(name: "Dusk", fonts: .init(heading: .sans, body: .sans), colors: .init(background: "#1B1830", text: "#E4E0F5", heading: "#FFFFFF", accent: "#B79CFF", accent2: "#F4A261", muted: "#A9A3C4", surface: "#262240")),
        "ocean": SlideTheme(name: "Ocean", fonts: .init(heading: .sans, body: .sans), colors: .init(background: "#0B2540", text: "#D6E4F0", heading: "#FFFFFF", accent: "#4CC9F0", accent2: "#FFD166", muted: "#9DB4CB", surface: "#13355A")),
        "forest": SlideTheme(name: "Forest", fonts: .init(heading: .serif, body: .sans), colors: .init(background: "#F3F6EF", text: "#1E2A20", heading: "#14301B", accent: "#2F6B3A", accent2: "#B5651D", muted: "#56635A", surface: "#E3EADC")),
        "sunset": SlideTheme(name: "Sunset", fonts: .init(heading: .sans, body: .sans), colors: .init(background: "#FFF4EC", text: "#3A1F2B", heading: "#5A1A33", accent: "#D1495B", accent2: "#7B4FA0", muted: "#7A5560", surface: "#FBE3D3")),
        "mono": SlideTheme(name: "Mono", fonts: .init(heading: .mono, body: .sans), colors: .init(background: "#FAFAFA", text: "#1A1A1A", heading: "#000000", accent: "#111111", accent2: "#777777", muted: "#5C5C5C", surface: "#EDEDED")),
        "blueprint": SlideTheme(name: "Blueprint", fonts: .init(heading: .mono, body: .sans), colors: .init(background: "#123A6B", text: "#E8F1FB", heading: "#FFFFFF", accent: "#9BD1FF", accent2: "#FFE08A", muted: "#B4CBE6", surface: "#1B4A82")),
    ]

    public static func newId(prefix: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var chars = ""
        chars.reserveCapacity(10)
        for _ in 0..<10 {
            chars.append(alphabet[Int.random(in: 0..<32)])
        }
        return "\(prefix)_\(chars)"
    }

    public static func parseDeck(_ json: String) throws -> SlideDeck {
        try JSONDecoder().decode(SlideDeck.self, from: Data(json.utf8))
    }

    public static func encodeDeck(_ deck: SlideDeck) throws -> String {
        let enc = JSONEncoder()
        let data = try enc.encode(deck)
        return String(decoding: data, as: UTF8.self)
    }

    public static func resolveColor(_ theme: SlideTheme, _ ref: String?, fallback: SlideThemeColorKey = .text) -> String {
        let v = ref ?? fallback.rawValue
        if v.hasPrefix("#") { return v.uppercased() }
        if let key = SlideThemeColorKey(rawValue: v) { return theme.colors[key].uppercased() }
        return theme.colors[fallback].uppercased()
    }

    public static func resolvePaint(_ theme: SlideTheme, _ fill: SlideFill?, fallback: SlideThemeColorKey = .text) -> SlideResolvedPaint {
        guard let fill else { return .solid(resolveColor(theme, nil, fallback: fallback)) }
        switch fill {
        case .solid(let s):
            return .solid(resolveColor(theme, s, fallback: fallback))
        case .gradient(let g):
            let s0 = resolveColor(theme, g.stops.first, fallback: fallback)
            let s1 = resolveColor(theme, g.stops.dropFirst().first ?? g.stops.first, fallback: fallback)
            return .gradient(angle: g.angle, start: s0, end: s1)
        }
    }

    public static func slotOf(_ theme: SlideTheme, font: String?) -> SlideFontSlot {
        guard let font else { return theme.fonts.body }
        switch font {
        case "heading": return theme.fonts.heading
        case "body": return theme.fonts.body
        default: return SlideFontSlot(rawValue: font) ?? theme.fonts.body
        }
    }

    public static func gradientLine(angle: Double, x: Double, y: Double, w: Double, h: Double) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let rad = angle * .pi / 180
        let dx = cos(rad)
        let dy = sin(rad)
        let half = (abs(w * dx) + abs(h * dy)) / 2
        let cx = x + w / 2
        let cy = y + h / 2
        return (cx - dx * half, cy - dy * half, cx + dx * half, cy + dy * half)
    }

    public static func placeholders(for layout: SlideLayoutKind, title: String = "") -> [SlideElement] {
        func heading(_ text: String, size: Double, frame: SlideFrame, valign: String, align: String? = nil) -> SlideElement {
            .text(SlideTextElement(
                id: newId(prefix: "e"),
                frame: frame,
                placeholder: "title",
                paragraphs: [SlideParagraph(runs: [SlideRun(text: text, size: size, bold: true, color: "heading", font: "heading")], align: align)],
                valign: valign
            ))
        }
        func body(_ role: String, frame: SlideFrame) -> SlideElement {
            .text(SlideTextElement(
                id: newId(prefix: "e"),
                frame: frame,
                placeholder: role,
                paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 44, color: "text", font: "body")], bullet: "disc")],
                valign: "top"
            ))
        }
        func imageSlot(_ frame: SlideFrame) -> SlideElement {
            .text(SlideTextElement(
                id: newId(prefix: "e"),
                frame: frame,
                placeholder: "image",
                paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 40, color: "muted", font: "body")])],
                valign: "middle"
            ))
        }

        switch layout {
        case .title:
            return [
                heading(title.isEmpty ? "Title" : title, size: 112, frame: .init(x: 160, y: 300, w: 1600, h: 280), valign: "bottom"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 160, y: 600, w: 1600, h: 120), placeholder: "subtitle", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 44, color: "muted", font: "body")])], valign: "top")),
            ]
        case .titleBody:
            return [
                heading("", size: 80, frame: .init(x: 120, y: 80, w: 1680, h: 160), valign: "middle"),
                body("body", frame: .init(x: 120, y: 280, w: 1680, h: 700)),
            ]
        case .twoColumn:
            return [
                heading("", size: 80, frame: .init(x: 120, y: 80, w: 1680, h: 160), valign: "middle"),
                body("body", frame: .init(x: 120, y: 280, w: 810, h: 700)),
                body("body2", frame: .init(x: 990, y: 280, w: 810, h: 700)),
            ]
        case .imageRight:
            return [
                heading("", size: 72, frame: .init(x: 120, y: 120, w: 800, h: 300), valign: "top"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 120, y: 460, w: 800, h: 480), placeholder: "body", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 40, color: "text", font: "body")])], valign: "top")),
                imageSlot(.init(x: 1000, y: 120, w: 800, h: 840)),
            ]
        case .section:
            return [heading("", size: 128, frame: .init(x: 160, y: 380, w: 1600, h: 320), valign: "middle", align: "center")]
        case .quote:
            return [
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 200, y: 220, w: 1520, h: 480), placeholder: "body", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 72, italic: true, color: "heading", font: "heading")])], valign: "bottom")),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 200, y: 740, w: 1520, h: 100), placeholder: "subtitle", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 44, color: "muted", font: "body")])], valign: "top")),
            ]
        case .bigNumber:
            return [
                heading("", size: 280, frame: .init(x: 160, y: 220, w: 1600, h: 420), valign: "bottom", align: "center"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 160, y: 680, w: 1600, h: 160), placeholder: "subtitle", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 56, color: "muted", font: "body")], align: "center")], valign: "top")),
            ]
        case .threeColumn:
            return [
                heading("", size: 80, frame: .init(x: 120, y: 80, w: 1680, h: 160), valign: "middle"),
                body("body", frame: .init(x: 120, y: 280, w: 520, h: 700)),
                body("body2", frame: .init(x: 700, y: 280, w: 520, h: 700)),
                body("body3", frame: .init(x: 1280, y: 280, w: 520, h: 700)),
            ]
        case .comparison:
            let lbl = { (role: String, x: Double) in
                SlideElement.text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: x, y: 280, w: 810, h: 90), placeholder: role, paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 52, bold: true, color: "accent", font: "heading")])], valign: "middle"))
            }
            return [
                heading("", size: 80, frame: .init(x: 120, y: 80, w: 1680, h: 160), valign: "middle"),
                lbl("label", 120),
                lbl("label2", 990),
                body("body", frame: .init(x: 120, y: 390, w: 810, h: 590)),
                body("body2", frame: .init(x: 990, y: 390, w: 810, h: 590)),
            ]
        case .imageFull:
            return [
                imageSlot(.init(x: 0, y: 0, w: 1920, h: 1080)),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 120, y: 780, w: 1680, h: 200), placeholder: "title", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 96, bold: true, color: "#FFFFFF", font: "heading")])], valign: "bottom")),
            ]
        case .imageLeft:
            return [
                imageSlot(.init(x: 120, y: 120, w: 800, h: 840)),
                heading("", size: 72, frame: .init(x: 1000, y: 120, w: 800, h: 300), valign: "top"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 1000, y: 460, w: 800, h: 480), placeholder: "body", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 40, color: "text", font: "body")])], valign: "top")),
            ]
        case .agenda:
            return [
                heading("", size: 80, frame: .init(x: 120, y: 80, w: 1680, h: 160), valign: "middle"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 120, y: 280, w: 1680, h: 700), placeholder: "body", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 52, color: "text", font: "body")], bullet: "number")], valign: "top")),
            ]
        case .closing:
            return [
                heading(title.isEmpty ? "Thank you" : title, size: 128, frame: .init(x: 160, y: 300, w: 1600, h: 280), valign: "bottom", align: "center"),
                .text(SlideTextElement(id: newId(prefix: "e"), frame: .init(x: 160, y: 620, w: 1600, h: 140), placeholder: "subtitle", paragraphs: [SlideParagraph(runs: [SlideRun(text: "", size: 44, color: "muted", font: "body")], align: "center")], valign: "top")),
            ]
        case .blank:
            return []
        }
    }

    public static func newSlide(layout: SlideLayoutKind) -> Slide {
        Slide(id: newId(prefix: "s"), layout: layout, elements: placeholders(for: layout))
    }

    public static func relayout(_ slide: Slide, to layout: SlideLayoutKind) -> Slide {
        let fresh = placeholders(for: layout)
        var used = Set<String>()
        let wantsImage = fresh.contains { $0.placeholder == "image" }
        let keep = wantsImage ? slide.elements : slide.elements.filter { !$0.isImageSlot }
        var elements: [SlideElement] = keep.map { el in
            guard let role = el.placeholder,
                  let target = fresh.first(where: { $0.placeholder == role && !used.contains(role) }) else {
                return el
            }
            used.insert(role)
            var moved = el
            moved.frame = target.frame
            return moved
        }
        for f in fresh {
            if let role = f.placeholder, !used.contains(role) {
                elements.append(f)
                used.insert(role)
            }
        }
        var out = slide
        out.layout = layout
        out.elements = elements
        return out
    }

    public static func slideTitle(_ slide: Slide) -> String {
        let all = slide.elements.flatMap { el -> [SlideElement] in
            if case .group(let g) = el { return g.elements }
            return [el]
        }
        let target = all.first(where: { $0.placeholder == "title" }) ?? all.first(where: { $0.textBox != nil })
        let raw = target?.plainText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Untitled slide" : raw
    }

    public static func contrastRatio(_ a: String, _ b: String) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    public static func contrastIssues(in theme: SlideTheme) -> [(fg: SlideThemeColorKey, bg: SlideThemeColorKey, ratio: Double)] {
        var out: [(SlideThemeColorKey, SlideThemeColorKey, Double)] = []
        for fg in [SlideThemeColorKey.text, .heading, .muted] {
            for bg in [SlideThemeColorKey.background, .surface] {
                let r = contrastRatio(theme.colors[fg], theme.colors[bg])
                if r < 4.5 { out.append((fg, bg, r)) }
            }
        }
        return out
    }

    private static func luminance(_ hex: String) -> Double {
        let (r, g, b, _) = parseHexRGBA(hex)
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public static func parseHexRGBA(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6 || s.count == 8, let val = UInt64(s, radix: 16) else { return (0, 0, 0, 1) }
        if s.count == 8 {
            return (
                Double((val >> 24) & 0xFF) / 255.0,
                Double((val >> 16) & 0xFF) / 255.0,
                Double((val >> 8) & 0xFF) / 255.0,
                Double(val & 0xFF) / 255.0
            )
        }
        return (
            Double((val >> 16) & 0xFF) / 255.0,
            Double((val >> 8) & 0xFF) / 255.0,
            Double(val & 0xFF) / 255.0,
            1.0
        )
    }
}

// MARK: - Preset Shape Geometry (exact port of web/lib/slides/geometry.ts; shared with Designs)

public enum SlidePathSeg: Sendable, Equatable, Hashable {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

public struct SlideShapeGeom: Sendable, Equatable {
    public var segs: [SlidePathSeg]
    public var text: SlideFrame
}

public enum SlideShapeGeometry: Sendable {
    private static let kappa = 0.5522847498
    private static let deg = Double.pi / 180.0

    private static func pos(_ v: Double, _ a: Double, _ b: Double) -> Double { v > 0 ? a : b }
    private static func pin(_ lo: Double, _ v: Double, _ hi: Double) -> Double { max(lo, min(v, hi)) }

    private static func poly(_ pts: [(Double, Double)]) -> [SlidePathSeg] {
        guard let first = pts.first else { return [] }
        var segs: [SlidePathSeg] = [.move(first.0, first.1)]
        for p in pts.dropFirst() { segs.append(.line(p.0, p.1)) }
        segs.append(.close)
        return segs
    }

    private static func corner(_ x0: Double, _ y0: Double, _ cx: Double, _ cy: Double, _ x1: Double, _ y1: Double) -> SlidePathSeg {
        .curve(
            x0 + kappa * (cx - x0), y0 + kappa * (cy - y0),
            x1 + kappa * (cx - x1), y1 + kappa * (cy - y1),
            x1, y1
        )
    }

    private static func ellipseSegs(cx: Double, cy: Double, rx: Double, ry: Double, reverse: Bool = false) -> [SlidePathSeg] {
        let pts: [(Double, Double)] = reverse
            ? [(cx + rx, cy), (cx, cy - ry), (cx - rx, cy), (cx, cy + ry), (cx + rx, cy)]
            : [(cx + rx, cy), (cx, cy + ry), (cx - rx, cy), (cx, cy - ry), (cx + rx, cy)]
        var segs: [SlidePathSeg] = [.move(pts[0].0, pts[0].1)]
        for i in 0..<4 {
            let (x0, y0) = pts[i]
            let (x1, y1) = pts[i + 1]
            let c = x0 == cx ? (x1, y0) : (x0, y1)
            segs.append(corner(x0, y0, c.0, c.1, x1, y1))
        }
        segs.append(.close)
        return segs
    }

    private static func wedge(w: Double, h: Double, adj1: Double = -20833, adj2: Double = 62500) -> (x1: Double, x2: Double, y1: Double, y2: Double, xl: Double, yl: Double, xt: Double, yt: Double, xr: Double, yr: Double, xb: Double, yb: Double) {
        let dxPos = (w * adj1) / 100000
        let dyPos = (h * adj2) / 100000
        let xPos = w / 2 + dxPos
        let yPos = h / 2 + dyPos
        let dq = w == 0 ? 0 : (dxPos * h) / w
        let dz = abs(dyPos) - abs(dq)
        let x1 = (w * pos(dxPos, 7, 2)) / 12
        let x2 = (w * pos(dxPos, 10, 5)) / 12
        let y1 = (h * pos(dyPos, 7, 2)) / 12
        let y2 = (h * pos(dyPos, 10, 5)) / 12
        return (
            x1, x2, y1, y2,
            pos(dz, 0, pos(dxPos, 0, xPos)), pos(dz, y1, pos(dxPos, y1, yPos)),
            pos(dz, pos(dyPos, x1, xPos), x1), pos(dz, pos(dyPos, 0, yPos), 0),
            pos(dz, w, pos(dxPos, xPos, w)), pos(dz, y1, pos(dxPos, yPos, y1)),
            pos(dz, pos(dyPos, xPos, x1), x1), pos(dz, pos(dyPos, yPos, h), h)
        )
    }

    public static func geometry(for shape: SlideShapeKind, in f: SlideFrame, radius: Double = 24) -> SlideShapeGeom {
        let w = max(0.001, f.w)
        let h = max(0.001, f.h)
        let ss = min(w, h)
        let hc = w / 2
        let vc = h / 2
        let local: (segs: [SlidePathSeg], text: (Double, Double, Double, Double))

        switch shape {
        case .rect:
            local = (poly([(0, 0), (w, 0), (w, h), (0, h)]), (0, 0, w, h))
        case .roundRect:
            let r = min(radius, w / 2, h / 2)
            local = ([
                .move(r, 0), .line(w - r, 0), corner(w - r, 0, w, 0, w, r),
                .line(w, h - r), corner(w, h - r, w, h, w - r, h),
                .line(r, h), corner(r, h, 0, h, 0, h - r),
                .line(0, r), corner(0, r, 0, 0, r, 0), .close
            ], (0, 0, w, h))
        case .ellipse:
            local = (ellipseSegs(cx: hc, cy: vc, rx: hc, ry: vc), (0, 0, w, h))
        case .triangle:
            local = (poly([(hc, 0), (w, h), (0, h)]), (w / 4, vc, 3 * w / 4, h))
        case .rtTriangle:
            local = (poly([(0, h), (0, 0), (w, h)]), (w / 12, 7 * h / 12, 7 * w / 12, 11 * h / 12))
        case .diamond:
            local = (poly([(0, vc), (hc, 0), (w, vc), (hc, h)]), (w / 4, h / 4, 3 * w / 4, 3 * h / 4))
        case .pentagon:
            let swd2 = hc * 105146 / 100000
            let shd2 = vc * 110557 / 100000
            let svc = vc * 110557 / 100000
            let dx1 = swd2 * cos(18 * deg)
            let dx2 = swd2 * cos(54 * deg)
            let y1 = svc - shd2 * sin(18 * deg)
            let y2 = svc + shd2 * sin(54 * deg)
            let it = (y1 * dx2) / dx1
            local = (poly([(hc - dx1, y1), (hc, 0), (hc + dx1, y1), (hc + dx2, y2), (hc - dx2, y2)]), (hc - dx2, it, hc + dx2, y2))
        case .hexagon:
            let maxAdj = 50000 * w / ss
            let a = pin(0, 25000, maxAdj)
            let shd2 = vc * 115470 / 100000
            let x1 = ss * a / 100000
            let dy1 = shd2 * sin(60 * deg)
            let q1 = -maxAdj / 2
            let q2 = a + q1
            let q3 = pos(q2, 4, 2)
            let q4 = pos(q2, 3, 2)
            let q5 = pos(q2, q1, 0)
            let q8 = q3 - ((a + q5) / q1) * q4
            let il = w * q8 / 24
            let it = h * q8 / 24
            local = (poly([(0, vc), (x1, vc - dy1), (w - x1, vc - dy1), (w, vc), (w - x1, vc + dy1), (x1, vc + dy1)]), (il, it, w - il, h - it))
        case .octagon:
            let x1 = ss * 29289 / 100000
            let il = x1 / 2
            local = (poly([(0, x1), (x1, 0), (w - x1, 0), (w, x1), (w, h - x1), (w - x1, h), (x1, h), (0, h - x1)]), (il, il, w - il, h - il))
        case .rightArrow:
            let a2 = pin(0, 50000, 100000 * w / ss)
            let dx1 = ss * a2 / 100000
            let x1 = w - dx1
            let dy1 = h / 4
            let y1 = vc - dy1
            let y2 = vc + dy1
            let x2 = x1 + (y1 * dx1) / vc
            local = (poly([(0, y1), (x1, y1), (x1, 0), (w, vc), (x1, h), (x1, y2), (0, y2)]), (0, y1, x2, y2))
        case .leftArrow:
            let a2 = pin(0, 50000, 100000 * w / ss)
            let dx2 = ss * a2 / 100000
            let x2 = dx2
            let dy1 = h / 4
            let y1 = vc - dy1
            let y2 = vc + dy1
            let x1 = x2 - (y1 * dx2) / vc
            local = (poly([(0, vc), (x2, 0), (x2, y1), (w, y1), (w, y2), (x2, y2), (x2, h)]), (x1, y1, w, y2))
        case .upArrow:
            let a2 = pin(0, 50000, 100000 * h / ss)
            let dy2 = ss * a2 / 100000
            let y2 = dy2
            let dx1 = w / 4
            let x1 = hc - dx1
            let x2 = hc + dx1
            let y1 = y2 - (x1 * dy2) / hc
            local = (poly([(0, y2), (hc, 0), (w, y2), (x2, y2), (x2, h), (x1, h), (x1, y2)]), (x1, y1, x2, h))
        case .downArrow:
            let a2 = pin(0, 50000, 100000 * h / ss)
            let dy1 = ss * a2 / 100000
            let y1 = h - dy1
            let dx1 = w / 4
            let x1 = hc - dx1
            let x2 = hc + dx1
            let y2 = y1 + (x1 * dy1) / hc
            local = (poly([(0, y1), (x1, y1), (x1, 0), (x2, 0), (x2, y1), (w, y1), (hc, h)]), (x1, 0, x2, y2))
        case .chevron:
            let a = pin(0, 50000, 100000 * w / ss)
            let x1 = ss * a / 100000
            let x2 = w - x1
            let dx = x2 - x1
            local = (poly([(0, 0), (x2, 0), (w, vc), (x2, h), (0, h), (x1, vc)]), (pos(dx, x1, 0), 0, pos(dx, x2, w), h))
        case .homePlate:
            let a = pin(0, 50000, 100000 * w / ss)
            let x1 = w - ss * a / 100000
            local = (poly([(0, 0), (x1, 0), (w, vc), (x1, h), (0, h)]), (0, 0, (x1 + w) / 2, h))
        case .wedgeRectCallout:
            let t = wedge(w: w, h: h)
            local = (poly([
                (0, 0), (t.x1, 0), (t.xt, t.yt), (t.x2, 0), (w, 0),
                (w, t.y1), (t.xr, t.yr), (w, t.y2), (w, h),
                (t.x2, h), (t.xb, t.yb), (t.x1, h), (0, h),
                (0, t.y2), (t.xl, t.yl), (0, t.y1)
            ]), (0, 0, w, h))
        case .wedgeRoundRectCallout:
            let t = wedge(w: w, h: h)
            let u1 = ss * 16667 / 100000
            let u2 = w - u1
            let v2 = h - u1
            let il = u1 * 29289 / 100000
            local = ([
                .move(0, u1), corner(0, u1, 0, 0, u1, 0),
                .line(t.x1, 0), .line(t.xt, t.yt), .line(t.x2, 0), .line(u2, 0), corner(u2, 0, w, 0, w, u1),
                .line(w, t.y1), .line(t.xr, t.yr), .line(w, t.y2), .line(w, v2), corner(w, v2, w, h, u2, h),
                .line(t.x2, h), .line(t.xb, t.yb), .line(t.x1, h), .line(u1, h), corner(u1, h, 0, h, 0, v2),
                .line(0, t.y2), .line(t.xl, t.yl), .line(0, t.y1), .close
            ], (il, il, w - il, h - il))
        case .star5:
            let a = 19098.0
            let swd2 = hc * 105146 / 100000
            let shd2 = vc * 110557 / 100000
            let svc = vc * 110557 / 100000
            let dx1 = swd2 * cos(18 * deg)
            let dx2 = swd2 * cos(54 * deg)
            let y1 = svc - shd2 * sin(18 * deg)
            let y2 = svc + shd2 * sin(54 * deg)
            let iwd2 = swd2 * a / 50000
            let ihd2 = shd2 * a / 50000
            let sdx1 = iwd2 * cos(18 * deg)
            let sdx2 = iwd2 * cos(54 * deg)
            let sy1 = svc - ihd2 * sin(54 * deg)
            let sy2 = svc + ihd2 * sin(18 * deg)
            let sy3 = svc + ihd2
            local = (poly([
                (hc - dx1, y1), (hc - sdx2, sy1), (hc, 0), (hc + sdx2, sy1), (hc + dx1, y1),
                (hc + sdx1, sy2), (hc + dx2, y2), (hc, sy3), (hc - dx2, y2), (hc - sdx1, sy2)
            ]), (hc - sdx1, sy1, hc + sdx1, sy3))
        case .plus:
            let x1 = ss / 4
            let x2 = w - x1
            let y2 = h - x1
            let d = w - h
            local = (poly([
                (0, x1), (x1, x1), (x1, 0), (x2, 0), (x2, x1), (w, x1),
                (w, y2), (x2, y2), (x2, h), (x1, h), (x1, y2), (0, y2)
            ]), (pos(d, 0, x1), pos(d, x1, 0), pos(d, w, x2), pos(d, y2, h)))
        case .donut:
            let dr = ss / 4
            let idx = hc * cos(45 * deg)
            let idy = vc * sin(45 * deg)
            local = (ellipseSegs(cx: hc, cy: vc, rx: hc, ry: vc) + ellipseSegs(cx: hc, cy: vc, rx: hc - dr, ry: vc - dr, reverse: true), (hc - idx, vc - idy, hc + idx, vc + idy))
        case .heart:
            let dx1 = w * 49 / 48
            let dx2 = w * 10 / 48
            let y1 = -h / 3
            let hd4 = h / 4
            local = ([
                .move(hc, hd4),
                .curve(hc + dx2, y1, hc + dx1, hd4, hc, h),
                .curve(hc - dx1, hd4, hc - dx2, y1, hc, hd4),
                .close
            ], (w / 6, hd4, 5 * w / 6, 2 * h / 3))
        }

        let translated = local.segs.map { seg -> SlidePathSeg in
            switch seg {
            case .move(let x, let y): .move(x + f.x, y + f.y)
            case .line(let x, let y): .line(x + f.x, y + f.y)
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                .curve(x1 + f.x, y1 + f.y, x2 + f.x, y2 + f.y, x + f.x, y + f.y)
            case .close: .close
            }
        }
        let (l, t, r, b) = local.text
        return SlideShapeGeom(segs: translated, text: SlideFrame(x: f.x + l, y: f.y + t, w: r - l, h: b - t))
    }

    public static func cgPath(from segs: [SlidePathSeg]) -> CGPath {
        let path = CGMutablePath()
        for seg in segs {
            switch seg {
            case .move(let x, let y): path.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): path.addLine(to: CGPoint(x: x, y: y))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    public static func svgPath(from segs: [SlidePathSeg]) -> String {
        func f(_ v: Double) -> String {
            let r = (v * 100).rounded() / 100
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        return segs.map { seg in
            switch seg {
            case .move(let x, let y): "M\(f(x)) \(f(y))"
            case .line(let x, let y): "L\(f(x)) \(f(y))"
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                "C\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2)) \(f(x)) \(f(y))"
            case .close: "Z"
            }
        }.joined()
    }
}
