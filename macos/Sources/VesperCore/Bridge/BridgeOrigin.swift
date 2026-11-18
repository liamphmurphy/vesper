import Foundation

/// Origin checks for the page bridge: scheme, host and port must match the Vesper server's.
/// 127.0.0.1, localhost and ::1 are treated as the same host (as routing.ts).
public enum BridgeOrigin {
    public static func defaultPort(forScheme scheme: String) -> Int {
        scheme.lowercased() == "https" ? 443 : 80
    }

    /// Lowercases and folds loopback names together.
    public static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "127.0.0.1" || h == "::1" { return "localhost" }
        return h
    }

    /// `port` 0 or nil means the scheme's default (WKSecurityOrigin reports 0 for it).
    public static func matches(scheme: String, host: String, port: Int?, base: URL) -> Bool {
        guard let baseScheme = base.scheme?.lowercased(), let baseHost = base.host else { return false }
        guard scheme.lowercased() == baseScheme else { return false }
        guard normalizedHost(host) == normalizedHost(baseHost) else { return false }
        let basePort = base.port ?? defaultPort(forScheme: baseScheme)
        let p = (port == nil || port == 0) ? defaultPort(forScheme: scheme) : port!
        return p == basePort
    }

    public static func matches(url: URL, base: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return false }
        return matches(scheme: scheme, host: host, port: url.port, base: base)
    }
}
