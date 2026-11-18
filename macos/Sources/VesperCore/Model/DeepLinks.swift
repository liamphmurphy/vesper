import Foundation

// Port of desktop/src/deeplink.ts: vesper:// links, strictly validated. Only these shapes pass:
//   run/<uuid> ticket/<KEY-1> epic/<uuid> page/<uuid> chat/<uuid> inbox capture

public let vesperScheme = "vesper"

public enum DeepLinkTarget: Sendable, Equatable {
    case navigate(path: String)
    case capture
}

public enum DeepLinkResult: Sendable, Equatable {
    case ok(DeepLinkTarget)
    case rejected(String)
}

public enum DeepLinks {
    static let maxLength = 200


    private static func isUUID(_ s: String) -> Bool { s.wholeMatch(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) != nil }
    private static func isTicket(_ s: String) -> Bool { s.wholeMatch(of: /[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}/) != nil }

    private static let idRoutes: [(host: String, prefix: String, valid: @Sendable (String) -> Bool)] = [
        ("run", "/runs/", isUUID), ("ticket", "/tickets/", isTicket), ("epic", "/epics/", isUUID),
        ("page", "/knowledge/", isUUID), ("chat", "/chat/", isUUID),
    ]

    public static func parse(_ raw: String) -> DeepLinkResult {
        if raw.count > maxLength { return .rejected("too long") }
        for scalar in raw.unicodeScalars where scalar.properties.isWhitespace || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7f {
            return .rejected("invalid characters")
        }
        if raw.contains("?") || raw.contains("#") { return .rejected("query or fragment") }
        let lower = raw.lowercased()
        let prefix = "\(vesperScheme):"
        guard lower.hasPrefix(prefix) else { return .rejected(raw.contains(":") ? "wrong scheme" : "malformed") }
        let rest = String(raw.dropFirst(prefix.count))
        guard rest.hasPrefix("//") else { return .rejected("missing target") }
        let afterSlashes = rest.dropFirst(2)
        let hostPart: Substring
        let pathPart: Substring
        if let slash = afterSlashes.firstIndex(of: "/") {
            hostPart = afterSlashes[..<slash]
            pathPart = afterSlashes[slash...]
        } else {
            hostPart = afterSlashes
            pathPart = ""
        }
        if hostPart.contains("@") || hostPart.contains(":") { return .rejected("credentials or port") }
        let host = hostPart.lowercased()
        if host.isEmpty { return .rejected("missing target") }
        let segments = pathPart.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if host == "inbox" && segments.isEmpty { return .ok(.navigate(path: "/inbox")) }
        if host == "capture" && segments.isEmpty { return .ok(.capture) }
        guard let route = idRoutes.first(where: { $0.host == host }) else { return .rejected("unknown target \"\(host)\"") }
        guard segments.count == 1 else { return .rejected("expected exactly one id") }
        guard let id = segments[0].removingPercentEncoding else { return .rejected("bad encoding") }
        guard route.valid(id) else { return .rejected("invalid \(host) id") }
        return .ok(.navigate(path: route.prefix + id))
    }

    /// Turns an in-app href into a vesper:// link when it has a supported shape, else nil.
    public static func hrefToVesperLink(_ href: String) -> String? {
        guard href.hasPrefix("/"), !href.hasPrefix("//") else { return nil }
        let clean = href.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? href
        if clean == "/inbox" { return "\(vesperScheme)://inbox" }
        for route in idRoutes where clean.hasPrefix(route.prefix) {
            let id = String(clean.dropFirst(route.prefix.count))
            if route.valid(id) { return "\(vesperScheme)://\(route.host)/\(id)" }
        }
        return nil
    }

    /// A vesper:// link out of an argument list, if any.
    public static func findLink(in arguments: [String]) -> String? {
        arguments.first { $0.lowercased().hasPrefix("\(vesperScheme)://") }
    }
}
