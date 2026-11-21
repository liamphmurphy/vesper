import Foundation

/// A screen the Mac app draws natively instead of the web view. Each native-screen ticket adds its
/// case and route; the placeholder only exists to prove the path end to end.
public enum NativeScreen: String, Sendable, CaseIterable {
    case debugPlaceholder
    case inbox
    case work
    case library
    case pdf
}

/// A path resolved to a native screen, with its path parameters and query items (decoded).
public struct NativeRouteMatch: Sendable, Equatable {
    public var screen: NativeScreen
    public var path: String
    public var params: [String: String]
    public var query: [String: String]
}

/// One path pattern: literal segments, `:name` captures one segment, a trailing `*` captures the rest
/// (as `params["*"]`).
public struct NativeRoute: Sendable, Equatable {
    public var pattern: String
    public var screen: NativeScreen

    public init(_ pattern: String, _ screen: NativeScreen) {
        self.pattern = pattern
        self.screen = screen
    }
}

/// Which in-app paths a tab draws natively. Routes resolve in order; a screen that isn't enabled
/// resolves to nil, so the web view keeps it. Screens move over one at a time by adding a route.
public struct NativeRouteRegistry: Sendable {
    public var routes: [NativeRoute]
    public var enabled: Set<NativeScreen>

    public init(routes: [NativeRoute], enabled: Set<NativeScreen>) {
        self.routes = routes
        self.enabled = enabled
    }

    /// Every native route in the app. Order matters: put specific patterns before general ones.
    public static let allRoutes: [NativeRoute] = [
        NativeRoute("/native-debug", .debugPlaceholder),
        NativeRoute("/native-debug/:id", .debugPlaceholder),
        NativeRoute("/inbox", .inbox),
        // Work's Runs view; bare /runs was an alias of it (a run's own page stays on the web).
        NativeRoute("/work", .work),
        NativeRoute("/runs", .work),
        NativeRoute("/library", .library),
        NativeRoute("/pdf", .pdf),
    ]

    /// The app's registry. Debug-only screens are enabled only when `debug` is set.
    public static func standard(debug: Bool) -> NativeRouteRegistry {
        var enabled = Set(NativeScreen.allCases)
        if !debug { enabled.remove(.debugPlaceholder) }
        return NativeRouteRegistry(routes: allRoutes, enabled: enabled)
    }

    /// The native screen for an in-app path ("/tickets/PAY-1?tab=runs#x"), or nil for the web view.
    public func resolve(_ href: String) -> NativeRouteMatch? {
        guard href.hasPrefix("/"), !href.hasPrefix("//") else { return nil }
        let noFragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        let parts = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let segments = path.split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] where query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
        }
        for route in routes where enabled.contains(route.screen) {
            if let params = Self.match(route.pattern, segments) {
                return NativeRouteMatch(screen: route.screen, path: path, params: params, query: query)
            }
        }
        return nil
    }

    static func match(_ pattern: String, _ segments: [String]) -> [String: String]? {
        let pieces = pattern.split(separator: "/").map(String.init)
        var params: [String: String] = [:]
        for (i, piece) in pieces.enumerated() {
            if piece == "*" && i == pieces.count - 1 {
                params["*"] = segments.dropFirst(i).map { $0.removingPercentEncoding ?? $0 }.joined(separator: "/")
                return params
            }
            guard i < segments.count else { return nil }
            let segment = segments[i].removingPercentEncoding ?? segments[i]
            if piece.hasPrefix(":") {
                guard !segment.isEmpty else { return nil }
                params[String(piece.dropFirst())] = segment
            } else if piece != segment {
                return nil
            }
        }
        return pieces.count == segments.count ? params : nil
    }
}
