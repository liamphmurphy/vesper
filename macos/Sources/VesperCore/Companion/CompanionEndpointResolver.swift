import Foundation

/// A candidate HTTPS endpoint for reaching the paired Mac, tagged with its transport.
public struct CompanionCandidateEndpoint: Sendable, Equatable {
    public var url: URL
    public var transport: CompanionTransportKind

    public init(url: URL, transport: CompanionTransportKind) {
        self.url = url
        self.transport = transport
    }
}

/// Resolves the best reachable HTTPS endpoint for a paired Mac:
/// 1. Live Bonjour-discovered LAN host (handles DHCP IP changes on home Wi-Fi)
/// 2. Saved LAN hosts from pairing
/// 3. Tailscale MagicDNS / Tailscale IPv4 hosts (when away from home)
public enum CompanionEndpointResolver {
    public typealias HealthProbe = @Sendable (URL) async -> Bool

    /// Builds the deduplicated candidate list in priority order (LAN first, then Tailscale).
    public static func candidates(
        lanHosts: [String],
        tailscaleHosts: [String],
        port: Int,
        bonjourLANHosts: [String] = []
    ) -> [CompanionCandidateEndpoint] {
        var result: [CompanionCandidateEndpoint] = []
        var seen = Set<String>()

        func append(_ host: String, transport: CompanionTransportKind) {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            guard let url = makeHTTPSURL(host: trimmed, port: port) else { return }
            result.append(CompanionCandidateEndpoint(url: url, transport: transport))
        }

        for h in bonjourLANHosts { append(h, transport: .lan) }
        for h in lanHosts { append(h, transport: .lan) }
        for h in tailscaleHosts { append(h, transport: .tailscale) }
        return result
    }

    /// Probes candidates in priority order (LAN first, then Tailscale) and returns the first
    /// endpoint whose `/api/v1/health` responds 2xx.
    public static func resolve(
        lanHosts: [String],
        tailscaleHosts: [String],
        port: Int,
        bonjourLANHosts: [String] = [],
        probe: HealthProbe
    ) async -> CompanionCandidateEndpoint? {
        let list = candidates(
            lanHosts: lanHosts,
            tailscaleHosts: tailscaleHosts,
            port: port,
            bonjourLANHosts: bonjourLANHosts
        )
        for candidate in list {
            if Task.isCancelled { return nil }
            if await probe(candidate.url) {
                return candidate
            }
        }
        return nil
    }

    /// Default pinned-TLS health probe with a tight 2-second timeout so LAN→Tailscale failover
    /// feels instantaneous when leaving home Wi-Fi.
    public static func makeHealthProbe(fingerprintSHA256: String, timeout: TimeInterval = 2.0) -> HealthProbe {
        let session = CompanionTLSPinning.makePinnedSession(
            fingerprintSHA256: fingerprintSHA256,
            timeoutForRequest: timeout,
            timeoutForResource: timeout
        )
        return { baseURL in
            guard let url = URL(string: "/api/v1/health", relativeTo: baseURL)?.absoluteURL else { return false }
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = "GET"
            do {
                let (_, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { return false }
                return (200..<300).contains(http.statusCode)
            } catch {
                return false
            }
        }
    }

    static func makeHTTPSURL(host: String, port: Int) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.port = port
        return comps.url
    }
}
