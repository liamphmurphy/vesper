import Foundation

// Port of desktop/src/routing.ts.

public enum NavigationKind: Sendable, Equatable {
    case vesper, playground, external, ignore
}

public let defaultPlaygroundPorts: [Int] = [8090, 8091, 8092, 8093, 8094]

private func effectivePort(_ url: URL) -> Int {
    if let p = url.port { return p }
    return url.scheme?.lowercased() == "https" ? 443 : 80
}

private func sameHost(_ a: String, _ b: String) -> Bool {
    BridgeOrigin.normalizedHost(a) == BridgeOrigin.normalizedHost(b)
}

/// - vesper: same origin as `serverURL`
/// - playground: matching host on a Playground port
/// - external: other http(s) and mailto URLs
/// - ignore: about:blank, javascript:, data: and anything unparsable
public func classifyNavigation(_ targetURL: String, serverURL: String, playgroundPorts: [Int] = defaultPlaygroundPorts) -> NavigationKind {
    if targetURL.isEmpty { return .ignore }
    guard let target = URL(string: targetURL), let server = URL(string: serverURL),
          let tScheme = target.scheme?.lowercased(), let sScheme = server.scheme?.lowercased() else { return .ignore }
    if tScheme == "mailto" { return .external }
    guard tScheme == "http" || tScheme == "https" else { return .ignore }
    guard let tHost = target.host, let sHost = server.host else { return .ignore }
    if tScheme == sScheme && tHost.lowercased() == sHost.lowercased() && effectivePort(target) == effectivePort(server) {
        return .vesper
    }
    if sameHost(tHost, sHost) && playgroundPorts.contains(effectivePort(target)) { return .playground }
    return .external
}

/// Strips a trailing " · Vesper", " - Vesper" or " — Vesper" so narrow tabs stay readable.
public func cleanTabTitle(_ rawTitle: String?) -> String {
    let normalized = (rawTitle ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    if normalized.isEmpty || normalized == "Vesper" { return "Vesper" }
    let stripped = normalized.replacing(/\s*(?:·|-|—)\s*Vesper$/.ignoresCase(), with: "")
        .trimmingCharacters(in: .whitespaces)
    return stripped.isEmpty ? "Vesper" : stripped
}

/// URLs of recently closed tabs, newest last.
public struct ClosedTabStack: Sendable {
    private var stack: [String] = []
    private let maxItems: Int

    public init(maxItems: Int = 25) { self.maxItems = maxItems }

    public mutating func push(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("file://") || trimmed == "about:blank" { return }
        if stack.last == trimmed { return }
        stack.append(trimmed)
        if stack.count > maxItems { stack.removeFirst() }
    }

    public mutating func pop() -> String? { stack.popLast() }
    public var size: Int { stack.count }
    public func peek() -> String? { stack.last }
}
