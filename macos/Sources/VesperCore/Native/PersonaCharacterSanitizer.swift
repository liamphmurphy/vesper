import Foundation

// MARK: - Character State & Rig Vocabulary (web/lib/persona-character.ts)

public enum CharacterMotion: String, CaseIterable, Sendable, Equatable, Hashable {
    case none
    case breathe
    case float
    case blink
    case glance
    case tilt
    case nod
    case sway
    case wag
    case wagFast = "wag-fast"
    case tap
    case type
    case bounce
    case wave
    case scan
    case orbit
    case spark
    case pulse
    case shadow
}

public enum CharacterShowToken: String, CaseIterable, Sendable, Equatable, Hashable {
    case idle
    case working
    case thinking
    case reading
    case coding
    case creating
    case needsYou = "needs-you"
}

public enum CharacterSpeed: String, CaseIterable, Sendable, Equatable, Hashable {
    case slow
    case normal
    case fast

    public var multiplierString: String {
        switch self {
        case .slow: "1.5"
        case .normal: "1"
        case .fast: "0.65"
        }
    }
}

public enum CharacterState: String, CaseIterable, Sendable, Equatable, Hashable {
    case staticState = "static"
    case idle
    case working
    case thinking
    case reading
    case coding
    case creating
    case needsYou = "needs_you"

    public static let previewStates: [(state: CharacterState, label: String)] = [
        (.idle, "Idle"),
        (.thinking, "Thinking"),
        (.reading, "Reading"),
        (.coding, "Coding"),
        (.creating, "Creating"),
        (.needsYou, "Needs you"),
    ]

    var isWorkState: Bool {
        switch self {
        case .working, .thinking, .reading, .coding, .creating: true
        case .staticState, .idle, .needsYou: false
        }
    }

    var showToken: CharacterShowToken {
        switch self {
        case .staticState, .idle: .idle
        case .working: .working
        case .thinking: .thinking
        case .reading: .reading
        case .coding: .coding
        case .creating: .creating
        case .needsYou: .needsYou
        }
    }

    var motionAttributeName: String {
        switch self {
        case .idle: "data-motion-idle"
        case .working: "data-motion-working"
        case .thinking: "data-motion-thinking"
        case .reading: "data-motion-reading"
        case .coding: "data-motion-coding"
        case .creating: "data-motion-creating"
        case .needsYou: "data-motion-needs-you"
        case .staticState: ""
        }
    }
}

public enum PersonaDockState: String, Sendable, Equatable {
    case working
    case replied
    case needsYou = "needs_you"
}

public struct ResolvedCharacterNodeStyle: Sendable, Equatable {
    public var motion: CharacterMotion?
    public var hidden: Bool
    public var transformOrigin: String?
    public var animationDelay: String?
    public var speedMultiplier: String?

    public init(
        motion: CharacterMotion? = nil,
        hidden: Bool = false,
        transformOrigin: String? = nil,
        animationDelay: String? = nil,
        speedMultiplier: String? = nil
    ) {
        self.motion = motion
        self.hidden = hidden
        self.transformOrigin = transformOrigin
        self.animationDelay = animationDelay
        self.speedMultiplier = speedMultiplier
    }
}

public struct SanitizedSVGNode: Sendable, Equatable {
    public var tag: String
    public var attrs: [String: String]
    public var children: [SanitizedSVGNode]
    public var text: String?
    public var path: String

    public init(
        tag: String,
        attrs: [String: String] = [:],
        children: [SanitizedSVGNode] = [],
        text: String? = nil,
        path: String = ""
    ) {
        self.tag = tag
        self.attrs = attrs
        self.children = children
        self.text = text
        self.path = path
    }
}

public struct SanitizedSVGResult: Sendable, Equatable {
    public var tree: SanitizedSVGNode?
    public var skipped: Int

    public init(tree: SanitizedSVGNode?, skipped: Int) {
        self.tree = tree
        self.skipped = skipped
    }
}

// MARK: - Sanitizer, State Mapper & CSP HTML Serializer

public enum PersonaCharacterSanitizer {
    public static let svgNamespace = "http://www.w3.org/2000/svg"
    public static let xlinkNamespace = "http://www.w3.org/1999/xlink"

    private static let allowedElements: Set<String> = [
        "svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "path", "text", "tspan", "title", "desc", "defs", "linearGradient",
        "radialGradient", "stop", "clipPath", "mask", "pattern", "symbol",
        "use", "marker",
    ]

    private static let textyElements: Set<String> = ["text", "tspan", "title", "desc"]

    private static let allowedBaseAttributes: Set<String> = [
        "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy",
        "width", "height", "d", "points", "transform", "viewBox", "preserveAspectRatio",
        "fill", "stroke", "opacity", "stroke-width", "stroke-dasharray", "stroke-linecap",
        "stroke-linejoin", "fill-opacity", "stroke-opacity", "fill-rule", "clip-rule",
        "font-family", "font-size", "font-weight", "font-style", "text-anchor",
        "dominant-baseline", "letter-spacing", "offset", "stop-color", "stop-opacity",
        "gradientUnits", "gradientTransform", "spreadMethod", "dx", "dy", "id",
        "clip-path", "mask", "marker-start", "marker-mid", "marker-end", "patternUnits",
        "patternTransform", "clipPathUnits", "maskUnits", "markerWidth", "markerHeight",
        "refX", "refY", "orient", "data-vid", "href", "rotate", "display", "visibility",
    ]

    private static let allowedCharacterAttributes: Set<String> = [
        "stroke-dashoffset", "stroke-miterlimit", "aria-hidden", "data-part",
        "data-motion", "data-motion-idle", "data-motion-working",
        "data-motion-thinking", "data-motion-reading", "data-motion-coding",
        "data-motion-creating", "data-motion-needs-you", "data-show",
        "data-pivot", "data-delay", "data-speed",
    ]

    private static let characterMotionAttributes: Set<String> = [
        "data-motion", "data-motion-idle", "data-motion-working",
        "data-motion-thinking", "data-motion-reading", "data-motion-coding",
        "data-motion-creating", "data-motion-needs-you",
    ]

    // MARK: - Status / Dock Mapping

    /// Exhaustive map from every `ActivitySceneKind` (`ChatStatusKind`) to `CharacterState`.
    public static func characterStateForStatus(
        _ kind: ActivitySceneKind,
        awaiting: Bool = false,
        stopping: Bool = false
    ) -> CharacterState {
        if stopping { return .staticState }
        if awaiting { return .needsYou }
        switch kind {
        case .thinking, .nextStep, .memory, .memorySave, .inbox, .choices, .subagent, .learning:
            return .thinking
        case .readingCode, .searchingCode, .wiki, .ticketLookup, .chatHistory, .repoSearch,
             .web, .webPage, .savedLinks, .research, .library, .projects, .imageView,
             .designView, .repoHistory, .finance, .runs, .schedule:
            return .reading
        case .writingCode, .tests, .build, .install, .terminal, .github, .commit, .push,
             .pullRequest, .repoAttach, .playground, .customApp, .database, .http, .workflow:
            return .coding
        case .writingReply, .canvas, .canvasComment, .design, .image, .video, .videoRender,
             .audioRender, .chart, .diagram, .app, .pdf, .persona, .space, .tickets, .financeSort:
            return .creating
        case .connector, .secret:
            return .needsYou
        }
    }

    public static func characterStateForDock(_ state: PersonaDockState?) -> CharacterState {
        switch state {
        case .needsYou: .needsYou
        case .working: .working
        case .replied, nil: .idle
        }
    }

    // MARK: - Attribute Parsers

    public static func parseCharacterPivot(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite,
              x >= 0, x <= 64, y >= 0, y <= 64 else {
            return nil
        }
        return "\(formatJSNumber(x))px \(formatJSNumber(y))px"
    }

    public static func parseCharacterDelay(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix("s") { s.removeLast() }
        guard !s.isEmpty, let n = Double(s), n.isFinite, n >= -4, n <= 4 else { return nil }
        return "\(formatJSNumber(n))s"
    }

    public static func isValidCharacterShow(_ raw: String) -> Bool {
        let tokens = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { CharacterShowToken(rawValue: $0) != nil }
    }

    public static func resolveCharacterNodeStyle(
        _ attrs: [String: String],
        state: CharacterState
    ) -> ResolvedCharacterNodeStyle {
        var hidden = false
        if let showRaw = attrs["data-show"], !showRaw.isEmpty {
            let tokens = showRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            let token = state.showToken.rawValue
            let matches = tokens.contains(token) || (state.isWorkState && tokens.contains("working"))
            if !matches { hidden = true }
        }

        var chosen: String?
        if state != .staticState && !hidden {
            if state == .idle {
                chosen = attrs["data-motion-idle"]
            } else if state == .working {
                chosen = attrs["data-motion-working"]
            } else if state == .needsYou {
                chosen = attrs["data-motion-needs-you"] ?? attrs["data-motion-working"]
            } else {
                chosen = attrs[state.motionAttributeName] ?? attrs["data-motion-working"]
            }
            if chosen == nil {
                chosen = attrs["data-motion"]
            }
        }

        let motion: CharacterMotion? = if let chosen, chosen != "none",
                                          let parsed = CharacterMotion(rawValue: chosen) {
            parsed
        } else {
            nil
        }

        let pivot = parseCharacterPivot(attrs["data-pivot"])
        var delay: String?
        var speedMult: String?
        if motion != nil {
            delay = parseCharacterDelay(attrs["data-delay"])
            if let rawSpeed = attrs["data-speed"],
               let speed = CharacterSpeed(rawValue: rawSpeed),
               speed != .normal {
                speedMult = speed.multiplierString
            }
        }

        return ResolvedCharacterNodeStyle(
            motion: motion,
            hidden: hidden,
            transformOrigin: pivot,
            animationDelay: delay,
            speedMultiplier: speedMult
        )
    }

    public static func detectCharacterStates(_ svg: String) -> Set<CharacterState> {
        var out = Set<CharacterState>()
        let motionAttrs: [(String, CharacterState)] = [
            ("data-motion-idle", .idle),
            ("data-motion-working", .working),
            ("data-motion-thinking", .thinking),
            ("data-motion-reading", .reading),
            ("data-motion-coding", .coding),
            ("data-motion-creating", .creating),
            ("data-motion-needs-you", .needsYou),
        ]
        for (attr, state) in motionAttrs {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: attr))\\s*="
            if svg.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                out.insert(state)
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\\bdata-show\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]) {
            let nsRange = NSRange(svg.startIndex..<svg.endIndex, in: svg)
            for match in regex.matches(in: svg, range: nsRange) {
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: svg) else { continue }
                let value = String(svg[r])
                for tok in value.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace) {
                    if tok == "needs-you" {
                        out.insert(.needsYou)
                    } else if tok == "idle" || tok == "working" || tok == "thinking" || tok == "reading" || tok == "coding" || tok == "creating",
                              let state = CharacterState(rawValue: String(tok)) {
                        out.insert(state)
                    }
                }
            }
        }
        return out
    }

    // MARK: - XMLParser Whitelist Sanitizer (`character: true`)

    public static func sanitizeCharacterSVG(_ svg: String, prefix: String = "pc-") -> SanitizedSVGResult {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SanitizedSVGResult(tree: nil, skipped: 0) }
        // Reject DTDs / entity declarations upfront to block XXE and entity expansion.
        if trimmed.range(of: "<!(?:DOCTYPE|ENTITY)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return SanitizedSVGResult(tree: nil, skipped: 0)
        }
        guard let data = trimmed.data(using: .utf8) else {
            return SanitizedSVGResult(tree: nil, skipped: 0)
        }
        let delegate = CharacterXMLSanitizerDelegate(prefix: prefix)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.aborted, let root = delegate.root else {
            return SanitizedSVGResult(tree: nil, skipped: delegate.skipped)
        }
        return SanitizedSVGResult(tree: root, skipped: delegate.skipped)
    }

    // MARK: - Self-Contained CSP HTML Output

    public static func safeHexColor(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidHex6(trimmed) ? trimmed : "#64748b"
    }

    /// Renders a self-contained HTML document with strict CSP (`default-src 'none'; style-src 'unsafe-inline'`)
    /// and the exact `.persona-character` keyframes from `web/app/globals.css`: the page WebKit used to
    /// animate characters in the app. `PersonaCharacterRig` draws it natively, and
    /// `PersonaCharacterWebKitParityTests` loads this page as the reference it must match.
    public static func renderHTML(
        svg: String,
        color: String,
        state: CharacterState,
        clipped: Bool = false,
        reduceMotion: Bool = false
    ) -> String? {
        let sanitized = sanitizeCharacterSVG(svg, prefix: "pc-")
        guard let tree = sanitized.tree else { return nil }
        let safeColor = safeHexColor(color)
        let effectiveState: CharacterState = reduceMotion ? .staticState : state
        let renderedSVG = serializeNode(tree, state: effectiveState)

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none';">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
        .persona-character { display: grid; place-items: center; width: 100%; height: 100%; color: \(safeColor); }
        \(characterCSS)
        .persona-character[data-pc-reduced-motion="true"] svg * { animation: none !important; transition: none !important; }
        </style>
        </head>
        <body>
        <span aria-hidden="true" class="persona-character" data-pc-state="\(escapeXML(effectiveState.rawValue))"\(clipped ? " data-pc-clipped=\"true\"" : "")\(reduceMotion ? " data-pc-reduced-motion=\"true\"" : "")>\(renderedSVG)</span>
        </body>
        </html>
        """
    }

    private static func serializeNode(_ node: SanitizedSVGNode, state: CharacterState) -> String {
        if node.tag == "#text" {
            return escapeXML(node.text ?? "")
        }
        let isRoot = node.path.isEmpty
        var attrs = node.attrs
        var extraStyleParts: [String] = []

        if isRoot {
            attrs["xmlns"] = svgNamespace
            attrs["viewBox"] = "0 0 64 64"
            attrs.removeValue(forKey: "width")
            attrs.removeValue(forKey: "height")
            attrs["aria-hidden"] = "true"
        } else {
            let resolved = resolveCharacterNodeStyle(attrs, state: state)
            if let motion = resolved.motion {
                attrs["data-pc-motion"] = motion.rawValue
            }
            if resolved.hidden {
                attrs["data-pc-hidden"] = "true"
                extraStyleParts.append("opacity:0")
                extraStyleParts.append("pointer-events:none")
            }
            if let origin = resolved.transformOrigin {
                extraStyleParts.append("transform-origin:\(origin)")
            }
            if let delay = resolved.animationDelay {
                extraStyleParts.append("animation-delay:\(delay)")
            }
            if let speed = resolved.speedMultiplier {
                extraStyleParts.append("--pc-speed:\(speed)")
            }
        }

        var parts = ["<\(node.tag)"]
        for key in attrs.keys.sorted() {
            if let val = attrs[key] {
                parts.append(" \(key)=\"\(escapeXML(val))\"")
            }
        }
        if !extraStyleParts.isEmpty {
            parts.append(" style=\"\(escapeXML(extraStyleParts.joined(separator: ";")))\"")
        }
        if node.children.isEmpty {
            parts.append("/>")
        } else {
            parts.append(">")
            for child in node.children {
                parts.append(serializeNode(child, state: state))
            }
            parts.append("</\(node.tag)>")
        }
        return parts.joined()
    }

    // MARK: - Helpers & Validation

    static func cleanAttributeValue(
        key: String,
        raw: String,
        prefix: String
    ) -> String? {
        let strippedControl = String(raw.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar.value > 0x1F
        }).lowercased()
        if strippedControl.contains("javascript:") { return nil }

        if key == "id" {
            return isValidSVGIdentifier(raw) ? prefix + raw : nil
        }
        if key == "href" {
            guard raw.hasPrefix("#") else { return nil }
            let target = String(raw.dropFirst())
            return isValidSVGIdentifier(target) ? "#\(prefix)\(target)" : nil
        }
        if raw.range(of: "url(", options: .caseInsensitive) != nil {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = extractURLFragment(trimmed) {
                return "url(#\(prefix)\(id))"
            }
            return nil
        }
        if characterMotionAttributes.contains(key) {
            return CharacterMotion(rawValue: raw) != nil ? raw : nil
        }
        if key == "data-part" {
            return isValidPartName(raw) ? raw : nil
        }
        if key == "data-show" {
            return isValidCharacterShow(raw) ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        if key == "data-pivot" {
            return parseCharacterPivot(raw) != nil ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        if key == "data-delay" {
            return parseCharacterDelay(raw) != nil ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        if key == "data-speed" {
            return CharacterSpeed(rawValue: raw) != nil ? raw : nil
        }
        return raw
    }

    private static func isValidHex6(_ s: String) -> Bool {
        guard s.count == 7, s.first == "#" else { return false }
        return s.dropFirst().unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x46)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }

    private static func isValidSVGIdentifier(_ raw: String) -> Bool {
        guard let first = raw.unicodeScalars.first else { return false }
        let firstOK = (first.value >= 0x41 && first.value <= 0x5A)
            || (first.value >= 0x61 && first.value <= 0x7A)
            || first.value == 0x5F
        guard firstOK else { return false }
        return raw.unicodeScalars.allSatisfy { s in
            (s.value >= 0x41 && s.value <= 0x5A)
                || (s.value >= 0x61 && s.value <= 0x7A)
                || (s.value >= 0x30 && s.value <= 0x39)
                || s.value == 0x5F || s.value == 0x2E || s.value == 0x3A || s.value == 0x2D
        }
    }

    private static func isValidPartName(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 32 else { return false }
        return raw.unicodeScalars.allSatisfy { s in
            (s.value >= 0x61 && s.value <= 0x7A)
                || (s.value >= 0x30 && s.value <= 0x39)
                || s.value == 0x2D
        }
    }

    private static func extractURLFragment(_ trimmed: String) -> String? {
        guard trimmed.lowercased().hasPrefix("url("), trimmed.hasSuffix(")") else { return nil }
        let inner = String(trimmed.dropFirst(4).dropLast(1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix("#") else { return nil }
        let id = String(inner.dropFirst())
        return isValidSVGIdentifier(id) ? id : nil
    }

    private static func formatJSNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.6g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }

    private static let characterCSS = """
    .persona-character svg { display: block; width: 100%; height: 100%; overflow: visible; }
    .persona-character[data-pc-clipped="true"] svg { overflow: hidden; }
    .persona-character svg * {
      transform-box: view-box;
      transform-origin: 32px 34px;
      transition: opacity 180ms ease;
    }
    .persona-character[data-pc-state="static"] svg * { animation: none !important; }
    .persona-character [data-pc-motion="breathe"] { animation: pc-breathe calc(4.2s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="float"] { animation: pc-float calc(3.8s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="blink"] { animation: pc-blink calc(5.5s * var(--pc-speed, 1)) infinite; }
    .persona-character [data-pc-motion="glance"] { animation: pc-glance calc(2.6s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="tilt"] { animation: pc-tilt calc(3.2s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="nod"] { animation: pc-nod calc(1.8s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="sway"] { animation: pc-sway calc(3.4s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="wag"] { animation: pc-wag calc(2.4s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="wag-fast"] { animation: pc-wag-fast calc(0.65s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="tap"] { animation: pc-tap calc(0.7s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="type"] { animation: pc-type calc(0.42s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="bounce"] { animation: pc-bounce calc(0.95s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="wave"] { animation: pc-wave calc(1.1s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="scan"] { animation: pc-scan calc(1.7s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="orbit"] { animation: pc-orbit calc(2.4s * var(--pc-speed, 1)) linear infinite; }
    .persona-character [data-pc-motion="spark"] { animation: pc-spark calc(1.2s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="pulse"] { animation: pc-pulse calc(1.8s * var(--pc-speed, 1)) ease-in-out infinite; }
    .persona-character [data-pc-motion="shadow"] { animation: pc-shadow calc(4.2s * var(--pc-speed, 1)) ease-in-out infinite; }
    @keyframes pc-breathe { 50% { transform: translateY(-1.2px) scaleY(1.02); } }
    @keyframes pc-float { 50% { transform: translateY(-3px) rotate(1.5deg); } }
    @keyframes pc-blink { 0%, 44%, 48%, 100% { transform: scaleY(1); opacity: 1; } 46% { transform: scaleY(0.12); opacity: 0.25; } }
    @keyframes pc-glance { 0%, 100% { transform: translateX(0); } 25% { transform: translateX(-2px); } 70% { transform: translateX(2px); } }
    @keyframes pc-tilt { 0%, 100% { transform: rotate(0deg); } 40%, 60% { transform: rotate(-7deg) translateY(-1px); } }
    @keyframes pc-nod { 0%, 100% { transform: translateY(0) rotate(0deg); } 35% { transform: translateY(1.8px) rotate(4deg); } 65% { transform: translateY(-0.5px) rotate(-1deg); } }
    @keyframes pc-sway { 0%, 100% { transform: rotate(0deg); } 35% { transform: rotate(-4deg); } 75% { transform: rotate(4deg); } }
    @keyframes pc-wag { 0%, 100% { transform: rotate(-6deg); } 50% { transform: rotate(8deg); } }
    @keyframes pc-wag-fast { 0%, 100% { transform: rotate(-14deg); } 50% { transform: rotate(16deg); } }
    @keyframes pc-tap { 25%, 75% { transform: translateY(-2px) rotate(-2deg); } 50% { transform: translateY(0) rotate(2deg); } }
    @keyframes pc-type { 0%, 100% { transform: translateY(0); } 25% { transform: translateY(-1.6px) rotate(-1.5deg); } 75% { transform: translateY(-1.2px) rotate(1.5deg); } }
    @keyframes pc-bounce { 0%, 100% { transform: translateY(0) scale(1); } 45% { transform: translateY(-3.5px) scale(1.03); } }
    @keyframes pc-wave { 0%, 100% { transform: rotate(0deg); } 25% { transform: rotate(-14deg); } 65% { transform: rotate(10deg); } }
    @keyframes pc-scan { 0%, 100% { transform: translateX(-2.5px); } 50% { transform: translateX(2.5px); } }
    @keyframes pc-orbit { to { transform: rotate(360deg); } }
    @keyframes pc-spark { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.35; transform: scale(0.75) rotate(15deg); } }
    @keyframes pc-pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.65; transform: scale(1.07); } }
    @keyframes pc-shadow { 50% { opacity: 0.3; transform: scaleX(0.84); } }
    @media (prefers-reduced-motion: reduce) {
      .persona-character *, .persona-character svg * { animation: none !important; transition: none !important; }
    }
    """

    // MARK: - XMLParser Delegate

    private final class CharacterXMLSanitizerDelegate: NSObject, XMLParserDelegate {
        private let prefix: String
        private var stack: [Frame] = []
        private var prefixStack: [[String: String]] = [[:]]
        private var pendingPrefixMappings: [String: String] = [:]
        private var skipDepth = 0

        var root: SanitizedSVGNode?
        var skipped = 0
        var aborted = false

        private struct Frame {
            var tag: String
            var attrs: [String: String]
            var path: String
            var rawChildCount: Int
            var children: [SanitizedSVGNode]
        }

        init(prefix: String) {
            self.prefix = prefix
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            pendingPrefixMappings[prefix] = namespaceURI
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            // Cleaned up when popping prefixStack in didEndElement.
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            var scope = prefixStack.last ?? [:]
            for (k, v) in pendingPrefixMappings { scope[k] = v }
            pendingPrefixMappings.removeAll(keepingCapacity: true)
            prefixStack.append(scope)

            if skipDepth > 0 {
                skipDepth += 1
                skipped += 1
                return
            }

            let isRoot = stack.isEmpty && root == nil
            if isRoot {
                guard elementName == "svg", namespaceURI == PersonaCharacterSanitizer.svgNamespace else {
                    aborted = true
                    parser.abortParsing()
                    return
                }
                let attrs = cleanAttrs(attributeDict, prefixMap: scope)
                stack.append(Frame(tag: "svg", attrs: attrs, path: "", rawChildCount: 0, children: []))
                return
            }

            guard let parentIndex = stack.indices.last else {
                skipDepth = 1
                skipped += 1
                return
            }

            let childIndex = stack[parentIndex].rawChildCount
            stack[parentIndex].rawChildCount += 1
            let parentPath = stack[parentIndex].path
            let path = parentPath.isEmpty ? "\(childIndex)" : "\(parentPath).\(childIndex)"

            guard namespaceURI == PersonaCharacterSanitizer.svgNamespace,
                  PersonaCharacterSanitizer.allowedElements.contains(elementName),
                  elementName != "image",
                  elementName != "svg" else {
                skipDepth = 1
                skipped += 1
                return
            }

            let attrs = cleanAttrs(attributeDict, prefixMap: scope)
            stack.append(Frame(tag: elementName, attrs: attrs, path: path, rawChildCount: 0, children: []))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0, !string.isEmpty,
                  let lastIdx = stack.indices.last,
                  PersonaCharacterSanitizer.textyElements.contains(stack[lastIdx].tag) else {
                return
            }
            let childIdx = stack[lastIdx].rawChildCount
            if let prev = stack[lastIdx].children.last, prev.tag == "#text" {
                stack[lastIdx].children[stack[lastIdx].children.count - 1].text = (prev.text ?? "") + string
            } else {
                stack[lastIdx].rawChildCount += 1
                let parentPath = stack[lastIdx].path
                let path = parentPath.isEmpty ? "\(childIdx)" : "\(parentPath).\(childIdx)"
                stack[lastIdx].children.append(SanitizedSVGNode(tag: "#text", text: string, path: path))
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
            self.parser(parser, foundCharacters: text)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if prefixStack.count > 1 { prefixStack.removeLast() }
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            guard let frame = stack.popLast() else { return }
            let node = SanitizedSVGNode(tag: frame.tag, attrs: frame.attrs, children: frame.children, path: frame.path)
            if let parentIdx = stack.indices.last {
                stack[parentIdx].children.append(node)
            } else {
                root = node
            }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            aborted = true
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            aborted = true
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            aborted = true
            parser.abortParsing()
            return nil
        }

        private func cleanAttrs(_ raw: [String: String], prefixMap: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            var hasPlainHref = false

            // Deterministic iteration order.
            for (rawKey, rawVal) in raw.sorted(by: { $0.key < $1.key }) {
                let resolvedKey: String
                let isNamespaced: Bool
                if let colon = rawKey.firstIndex(of: ":") {
                    let attrPrefix = String(rawKey[..<colon])
                    let local = String(rawKey[rawKey.index(after: colon)...])
                    guard prefixMap[attrPrefix] == PersonaCharacterSanitizer.xlinkNamespace, local == "href" else {
                        continue
                    }
                    resolvedKey = "href"
                    isNamespaced = true
                } else {
                    resolvedKey = rawKey
                    isNamespaced = false
                }

                guard PersonaCharacterSanitizer.allowedBaseAttributes.contains(resolvedKey)
                    || PersonaCharacterSanitizer.allowedCharacterAttributes.contains(resolvedKey) else {
                    continue
                }
                if isNamespaced && hasPlainHref { continue }
                if !isNamespaced && resolvedKey == "href" {
                    out.removeValue(forKey: "href")
                    hasPlainHref = true
                }
                if let clean = PersonaCharacterSanitizer.cleanAttributeValue(key: resolvedKey, raw: rawVal, prefix: prefix) {
                    out[resolvedKey] = clean
                }
            }
            return out
        }
    }
}
