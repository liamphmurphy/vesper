import Foundation

/// A screen the Mac app draws natively instead of the web view. Each native-screen ticket adds its
/// case and route; the placeholder only exists to prove the path end to end.
public enum NativeScreen: String, Sendable, CaseIterable {
    case debugPlaceholder
    case inbox
    case work
    case runDetail
    case library
    case pdf
    /// /native-debug/markdown: every markdown feature through `MarkdownView` (debug only).
    case markdownDebug
    /// /native-debug/scenes: all 59 activity scenes and the pooled persona character view (debug only).
    case scenesDebug
    /// /native-debug/embeds: chat embeds (math, mermaid, SVG, apps) in a lazy list (debug only).
    case embedsDebug
    case dev
    case http
    case learn
    case learnCourse
    case tickets
    case ticketNew
    case ticketDetail
    case epics
    case epicDetail
    case scheduled
    case reports
    case knowledge
    case knowledgeGraph
    case knowledgePage
    case workflows
    case workflowEditor
    case workflowRun
    case chat
    case chatDetail
    case rootLanding
    case setup
    case appsHome
    case appsRedirect
    case spaceNew
    case spaceDetail
    case agentDetail

    /// Screens sharing one SwiftUI root host so navigating between them preserves sidebar & chrome state.
    public var hostGroup: NativeScreen {
        switch self {
        case .knowledge, .knowledgeGraph, .knowledgePage: .knowledge
        case .chat, .chatDetail: .chat
        default: self
        }
    }

    /// The sidebar area this screen belongs to, as web/lib/navigator.ts's currentArea() has it for
    /// the same paths: tools and app screens are under Apps, Inbox and the PDF viewer under none.
    /// The shell marks it itself rather than waiting for the hidden page to report its route.
    public var area: AreaId? {
        switch self {
        case .chat, .chatDetail, .rootLanding, .spaceNew, .spaceDetail: .chat
        case .work, .runDetail, .tickets, .ticketNew, .ticketDetail, .epics, .epicDetail, .agentDetail: .work
        case .knowledge, .knowledgeGraph, .knowledgePage: .knowledge
        case .library: .library
        case .workflows, .workflowEditor, .workflowRun, .scheduled, .learn, .learnCourse, .reports, .http, .dev, .appsHome, .appsRedirect: .apps
        case .inbox, .pdf, .setup, .debugPlaceholder, .markdownDebug, .scenesDebug, .embedsDebug: nil
        }
    }
}

/// A path resolved to a native screen, with its path parameters and query items (decoded).
public struct NativeRouteMatch: Sendable, Equatable {
    public var screen: NativeScreen
    public var path: String
    public var params: [String: String]
    public var query: [String: String]

    public init(screen: NativeScreen, path: String, params: [String: String] = [:], query: [String: String] = [:]) {
        self.screen = screen
        self.path = path
        self.params = params
        self.query = query
    }
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
        NativeRoute("/native-debug/markdown", .markdownDebug),
        NativeRoute("/native-debug/scenes", .scenesDebug),
        NativeRoute("/native-debug/embeds", .embedsDebug),
        NativeRoute("/native-debug/:id", .debugPlaceholder),
        NativeRoute("/inbox", .inbox),
        // Work's Runs view (/work and bare /runs) and Run detail (/runs/:id).
        NativeRoute("/work", .work),
        NativeRoute("/runs", .work),
        NativeRoute("/runs/:id", .runDetail),
        NativeRoute("/library", .library),
        NativeRoute("/pdf", .pdf),
        // The Dev workspace terminal (SwiftTerm on the workspace's PTY socket).
        NativeRoute("/dev", .dev),
        // Native HTTP client workbench.
        NativeRoute("/http", .http),
        // Guided Learning modules and course study/build screens.
        NativeRoute("/learn", .learn),
        NativeRoute("/learn/:id", .learnCourse),
        // Tickets list/board, new-ticket composer, and ticket detail.
        NativeRoute("/tickets", .tickets),
        NativeRoute("/board", .tickets),
        NativeRoute("/tickets/new", .ticketNew),
        NativeRoute("/tickets/:key", .ticketDetail),
        // Epics, Agent detail, Scheduled tasks, and Reports (Costs & Highlights).
        NativeRoute("/epics", .epics),
        NativeRoute("/epics/:id", .epicDetail),
        NativeRoute("/agents/:handle", .agentDetail),
        NativeRoute("/scheduled", .scheduled),
        NativeRoute("/reports", .reports),
        NativeRoute("/costs", .reports),
        // Knowledge explorer, home, search, connect, graph and pages (specific routes before :id).
        NativeRoute("/knowledge", .knowledge),
        NativeRoute("/knowledge/graph", .knowledgeGraph),
        NativeRoute("/knowledge/connect", .knowledge),
        NativeRoute("/knowledge/:id", .knowledgePage),
        NativeRoute("/knowledge/:id/*", .knowledgePage),
        NativeRoute("/wiki", .knowledge),
        NativeRoute("/wiki/*", .knowledgePage),
        // Workflows list, live workflow runs (specific route before :id), and workflow editor.
        NativeRoute("/workflows", .workflows),
        NativeRoute("/workflows/runs/:id", .workflowRun),
        NativeRoute("/workflows/:id", .workflowEditor),
        // Chat landing, Spaces, and conversation detail.
        NativeRoute("/chat", .chat),
        NativeRoute("/chat/:id", .chatDetail),
        NativeRoute("/spaces", .spaceNew),
        NativeRoute("/spaces/new", .spaceNew),
        NativeRoute("/spaces/:id", .spaceDetail),
        // Root landing, onboarding setup, Custom Apps home, and legacy /apps/docs|slides|designs redirects.
        NativeRoute("/", .rootLanding),
        NativeRoute("/setup", .setup),
        NativeRoute("/apps", .appsHome),
        NativeRoute("/apps/docs", .appsRedirect),
        NativeRoute("/apps/slides", .appsRedirect),
        NativeRoute("/apps/designs", .appsRedirect),
    ]

    /// The app's registry. Debug-only screens are enabled only when `debug` is set.
    public static func standard(debug: Bool) -> NativeRouteRegistry {
        var enabled = Set(NativeScreen.allCases)
        if !debug { enabled.subtract([.debugPlaceholder, .markdownDebug, .scenesDebug, .embedsDebug]) }
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
