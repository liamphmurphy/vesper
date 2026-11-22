import Foundation
import JavaScriptCore

/// Platform-neutral ELK graph input and layout output types (matching `elkjs` JSON schema).
public struct ELKPoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ELKPort: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var layoutOptions: [String: String]?

    public init(
        id: String,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        layoutOptions: [String: String]? = nil
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.layoutOptions = layoutOptions
    }
}

public struct ELKEdgeSection: Codable, Sendable, Equatable, Hashable {
    public var id: String?
    public var startPoint: ELKPoint
    public var endPoint: ELKPoint
    public var bendPoints: [ELKPoint]?

    public init(
        id: String? = nil,
        startPoint: ELKPoint,
        endPoint: ELKPoint,
        bendPoints: [ELKPoint]? = nil
    ) {
        self.id = id
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.bendPoints = bendPoints
    }

    /// All points along this section in order: start -> bendPoints -> end.
    public var polyline: [ELKPoint] {
        var pts = [startPoint]
        if let bendPoints { pts.append(contentsOf: bendPoints) }
        pts.append(endPoint)
        return pts
    }
}

public struct ELKEdge: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var sources: [String]
    public var targets: [String]
    public var sections: [ELKEdgeSection]?
    public var layoutOptions: [String: String]?

    public init(
        id: String,
        sources: [String],
        targets: [String],
        sections: [ELKEdgeSection]? = nil,
        layoutOptions: [String: String]? = nil
    ) {
        self.id = id
        self.sources = sources
        self.targets = targets
        self.sections = sections
        self.layoutOptions = layoutOptions
    }
}

public struct ELKNode: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var x: Double?
    public var y: Double?
    public var width: Double
    public var height: Double
    public var ports: [ELKPort]?
    public var children: [ELKNode]?
    public var edges: [ELKEdge]?
    public var layoutOptions: [String: String]?

    public init(
        id: String,
        x: Double? = nil,
        y: Double? = nil,
        width: Double,
        height: Double,
        ports: [ELKPort]? = nil,
        children: [ELKNode]? = nil,
        edges: [ELKEdge]? = nil,
        layoutOptions: [String: String]? = nil
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.ports = ports
        self.children = children
        self.edges = edges
        self.layoutOptions = layoutOptions
    }
}

public struct ELKGraph: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var layoutOptions: [String: String]?
    public var children: [ELKNode]
    public var edges: [ELKEdge]

    public init(
        id: String = "root",
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        layoutOptions: [String: String]? = ELKGraph.defaultLayeredOptions,
        children: [ELKNode],
        edges: [ELKEdge]
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.layoutOptions = layoutOptions
        self.children = children
        self.edges = edges
    }

    public static let defaultLayeredOptions: [String: String] = [
        "elk.algorithm": "layered",
        "elk.direction": "RIGHT",
        "elk.spacing.nodeNode": "28",
        "elk.layered.spacing.nodeNodeBetweenLayers": "48",
        "elk.edgeRouting": "ORTHOGONAL",
    ]
}

public enum ELKLayoutError: Error, Sendable, Equatable, LocalizedError {
    case bundleMissing(String)
    case contextInitFailed(String)
    case encodingFailed(String)
    case layoutFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundleMissing(let msg): "ELK bundle missing: \(msg)"
        case .contextInitFailed(let msg): "ELK JSContext init failed: \(msg)"
        case .encodingFailed(let msg): "ELK input encoding failed: \(msg)"
        case .layoutFailed(let msg): "ELK layout failed: \(msg)"
        case .decodingFailed(let msg): "ELK output decoding failed: \(msg)"
        }
    }
}

/// Runs bundled `elk.bundled.js` offline inside JavaScriptCore off the main thread.
/// Uses lightweight timer/microtask shims so `JSContext` executes `elk.layout(graph)` deterministically
/// with zero remote SwiftPM dependencies.
public actor ELKLayoutEngine {
    public static let shared = ELKLayoutEngine()

    private let scriptURL: URL?
    private var context: JSContext?
    public private(set) var loadError: String?

    public init(scriptURL: URL? = ELKLayoutEngine.bundledScript()) {
        self.scriptURL = scriptURL
    }

    /// Computes node coordinates (`x`, `y`) and routed edge sections for `graph`.
    public func layout(graph: ELKGraph) throws -> ELKGraph {
        let context = try loadedContext()
        let encoded: String
        do {
            let data = try JSONEncoder().encode(graph)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ELKLayoutError.encodingFailed("UTF-8 conversion failed")
            }
            encoded = text
        } catch let err as ELKLayoutError {
            throw err
        } catch {
            throw ELKLayoutError.encodingFailed(error.localizedDescription)
        }

        guard let runner = context.objectForKeyedSubscript("__vesperLayout"), runner.isObject else {
            throw ELKLayoutError.contextInitFailed("__vesperLayout bridge missing")
        }

        var resolvedJSON: String?
        var rejectedMessage: String?

        let onResolve: @convention(block) (String) -> Void = { json in
            resolvedJSON = json
        }
        let onReject: @convention(block) (String) -> Void = { message in
            rejectedMessage = message
        }

        context.exception = nil
        _ = runner.call(withArguments: [
            encoded,
            unsafeBitCast(onResolve, to: AnyObject.self),
            unsafeBitCast(onReject, to: AnyObject.self),
        ])

        if let exception = context.exception {
            let msg = exception.toString() ?? "Unknown JS exception"
            context.exception = nil
            throw ELKLayoutError.layoutFailed(msg)
        }
        if let rejectedMessage {
            throw ELKLayoutError.layoutFailed(rejectedMessage)
        }
        guard let resolvedJSON, let data = resolvedJSON.data(using: .utf8) else {
            throw ELKLayoutError.layoutFailed("ELK layout promise did not resolve synchronously")
        }

        do {
            return try JSONDecoder().decode(ELKGraph.self, from: data)
        } catch {
            throw ELKLayoutError.decodingFailed(error.localizedDescription)
        }
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        if let loadError { throw ELKLayoutError.contextInitFailed(loadError) }

        guard let scriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            let msg = scriptURL?.path ?? "not found"
            loadError = "ELK bundle missing (\(msg))"
            throw ELKLayoutError.bundleMissing(msg)
        }
        guard let ctx = JSContext() else {
            loadError = "Unable to allocate JSContext"
            throw ELKLayoutError.contextInitFailed("Unable to allocate JSContext")
        }

        // JSContext lacks browser/Node timer & global aliases that elkjs (GWT) expects.
        let shims = """
        var self = this;
        var window = this;
        var setTimeout = function(fn) { fn(); return 0; };
        var clearTimeout = function() {};
        var queueMicrotask = function(fn) { fn(); };
        """
        ctx.evaluateScript(shims)
        if let ex = ctx.exception {
            let msg = ex.toString() ?? "shim error"
            loadError = msg
            throw ELKLayoutError.contextInitFailed(msg)
        }

        ctx.evaluateScript(source, withSourceURL: scriptURL)
        if let ex = ctx.exception {
            let msg = ex.toString() ?? "elk.bundled.js evaluation error"
            loadError = msg
            throw ELKLayoutError.contextInitFailed(msg)
        }

        let bridge = """
        var __vesperELK = new ELK();
        function __vesperLayout(graphJson, onResolve, onReject) {
            try {
                var g = JSON.parse(graphJson);
                __vesperELK.layout(g).then(
                    function(res) { onResolve(JSON.stringify(res)); },
                    function(err) { onReject(String(err && err.message ? err.message : err)); }
                );
            } catch (e) {
                onReject(String(e && e.message ? e.message : e));
            }
        }
        """
        ctx.evaluateScript(bridge)
        if let ex = ctx.exception {
            let msg = ex.toString() ?? "bridge init error"
            loadError = msg
            throw ELKLayoutError.contextInitFailed(msg)
        }

        self.context = ctx
        return ctx
    }

    /// Locates `Resources/elk/elk.bundled.js` in `Vesper_VesperCore.bundle` without trapping on `Bundle.module`.
    public static func bundledScript() -> URL? {
        let name = "Vesper_VesperCore.bundle"
        var dirs: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0 }
        dirs += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for dir in dirs {
            let bundleURL = dir.appendingPathComponent(name)
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "elk.bundled", withExtension: "js", subdirectory: "elk") {
                return url
            }
            let flat = bundleURL.appendingPathComponent("elk/elk.bundled.js")
            if FileManager.default.fileExists(atPath: flat.path) {
                return flat
            }
        }
        return nil
    }
}
