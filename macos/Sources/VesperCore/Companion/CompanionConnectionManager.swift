import Foundation
import Observation

/// Coordinates pairing, TLS pinning, automatic LAN ↔ Tailscale failover, and live SSE updates
/// for the iPhone companion app.
@MainActor
@Observable
public final class CompanionConnectionManager {
    public private(set) var state: CompanionConnectionState = .unpaired
    public private(set) var pairedHost: CompanionPairedHost?
    public private(set) var apiClient: APIClient?
    public private(set) var eventStream: EventStream?
    public private(set) var lastError: String?

    private let store: CompanionCredentialStore
    private let bonjour = CompanionBonjourBrowser()
    private let probeOverride: CompanionEndpointResolver.HealthProbe?

    public init(
        store: CompanionCredentialStore = KeychainCompanionStore(),
        probeOverride: CompanionEndpointResolver.HealthProbe? = nil
    ) {
        self.store = store
        self.probeOverride = probeOverride
        if let host = store.loadHost(), store.loadToken() != nil {
            self.pairedHost = host
            self.state = .connecting
        } else {
            self.state = .unpaired
        }
    }

    /// Starts Bonjour discovery and attempts to connect to the paired Mac if one is saved.
    public func start() async {
        guard let host = store.loadHost(), store.loadToken() != nil else {
            state = .unpaired
            return
        }
        pairedHost = host
        bonjour.start(serviceType: host.bonjourService)
        await reconnect()
    }

    /// Redeems a scanned `vesper-pair://v1?data=...` URI, persists the device token in Keychain,
    /// and establishes a pinned-TLS connection.
    public func pair(uri: String, deviceName: String) async throws {
        lastError = nil
        let payload = try CompanionPairingPayload.decode(uri: uri)
        state = .connecting

        let probe = probeOverride ?? CompanionEndpointResolver.makeHealthProbe(fingerprintSHA256: payload.certSHA256)
        guard let endpoint = await CompanionEndpointResolver.resolve(
            lanHosts: payload.lanHosts,
            tailscaleHosts: payload.tailscaleHosts,
            port: payload.port,
            bonjourLANHosts: bonjour.currentHosts,
            probe: probe
        ) else {
            let msg = "Couldn't reach \(payload.name) on local Wi-Fi or Tailscale. Make sure Vesper is open on your Mac and both devices are on the same network or Tailscale."
            state = .unpaired
            lastError = msg
            throw CompanionPairingError.pairingFailed(msg)
        }

        let session = CompanionTLSPinning.makePinnedSession(fingerprintSHA256: payload.certSHA256)
        guard let pairURL = URL(string: "/api/v1/companion/pair", relativeTo: endpoint.url)?.absoluteURL else {
            throw CompanionPairingError.invalidURI
        }
        var req = URLRequest(url: pairURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "code": payload.code,
            "device_name": deviceName,
            "platform": "ios",
        ]
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CompanionPairingError.pairingFailed("Unexpected response from Mac.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = APIClient.errorMessage(status: http.statusCode, body: data)
            state = .unpaired
            lastError = msg
            throw CompanionPairingError.pairingFailed(msg)
        }

        let pairResp = try JSONDecoder().decode(CompanionPairResponse.self, from: data)
        let host = CompanionPairedHost(
            deviceId: pairResp.deviceId,
            deviceName: pairResp.deviceName,
            hostName: pairResp.hostName.isEmpty ? payload.name : pairResp.hostName,
            port: payload.port,
            certSHA256: payload.certSHA256,
            lanHosts: payload.lanHosts,
            tailscaleHosts: payload.tailscaleHosts,
            bonjourService: payload.bonjourService
        )
        try store.saveToken(pairResp.deviceToken)
        try store.saveHost(host)
        pairedHost = host
        bonjour.start(serviceType: host.bonjourService)
        activateConnection(host: host, token: pairResp.deviceToken, endpoint: endpoint)
    }

    /// Re-resolves the best reachable transport (LAN first, then Tailscale) and rebuilds the
    /// pinned-TLS `APIClient` and SSE `EventStream`.
    public func reconnect() async {
        guard let host = store.loadHost(), let token = store.loadToken() else {
            state = .unpaired
            return
        }
        pairedHost = host
        state = .connecting
        lastError = nil

        let probe = probeOverride ?? CompanionEndpointResolver.makeHealthProbe(fingerprintSHA256: host.certSHA256)
        guard let endpoint = await CompanionEndpointResolver.resolve(
            lanHosts: host.lanHosts,
            tailscaleHosts: host.tailscaleHosts,
            port: host.port,
            bonjourLANHosts: bonjour.currentHosts,
            probe: probe
        ) else {
            eventStream?.stop()
            eventStream = nil
            apiClient = nil
            let msg = "\(host.hostName) appears to be asleep or unreachable on Wi-Fi and Tailscale."
            lastError = msg
            state = .unreachable(msg)
            return
        }

        activateConnection(host: host, token: token, endpoint: endpoint)
    }

    /// Clears saved credentials and returns to `.unpaired`.
    public func unpair() {
        eventStream?.stop()
        eventStream = nil
        apiClient = nil
        bonjour.stop()
        try? store.deleteToken()
        try? store.deleteHost()
        pairedHost = nil
        lastError = nil
        state = .unpaired
    }

    private func activateConnection(
        host: CompanionPairedHost,
        token: String,
        endpoint: CompanionCandidateEndpoint
    ) {
        let apiSession = CompanionTLSPinning.makePinnedSession(
            fingerprintSHA256: host.certSHA256,
            timeoutForRequest: 20,
            timeoutForResource: 120
        )
        let sseSession = CompanionTLSPinning.makePinnedSession(
            fingerprintSHA256: host.certSHA256,
            timeoutForRequest: 3600,
            timeoutForResource: 24 * 3600
        )
        let client = APIClient(
            baseURL: endpoint.url,
            auth: .bearer(token),
            transport: APIClient.transport(session: apiSession)
        )
        let stream = EventStream(
            reconnectDelay: .seconds(5),
            connector: SSE.urlSessionConnector(session: sseSession)
        )
        eventStream?.stop()
        apiClient = client
        eventStream = stream
        stream.start(client: client)
        state = .connected(endpoint.transport, endpoint.url)
    }
}
