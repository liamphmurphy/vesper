import Foundation

/// Errors raised while decoding a pairing QR URI or pairing with a Mac.
public enum CompanionPairingError: Error, Equatable, Sendable {
    case invalidURI
    case unsupportedVersion(Int)
    case missingData
    case invalidFingerprint
    case noEndpoints
    case pairingFailed(String)

    public var userMessage: String {
        switch self {
        case .invalidURI:
            return "Not a valid Vesper pairing QR code."
        case .unsupportedVersion(let v):
            return "Pairing QR version \(v) isn't supported by this app."
        case .missingData:
            return "Pairing QR code is incomplete."
        case .invalidFingerprint:
            return "Pairing QR code has an invalid TLS certificate fingerprint."
        case .noEndpoints:
            return "No LAN or Tailscale addresses were found in the pairing code."
        case .pairingFailed(let msg):
            return msg
        }
    }
}

/// JSON payload encoded inside `vesper-pair://v1?data=<base64url-json>`.
public struct CompanionPairingPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var name: String
    public var port: Int
    public var certSHA256: String
    public var code: String
    public var lanHosts: [String]
    public var tailscaleHosts: [String]
    public var bonjourService: String

    enum CodingKeys: String, CodingKey {
        case v, name, port, code
        case certSHA256 = "cert_sha256"
        case lanHosts = "lan_hosts"
        case tailscaleHosts = "tailscale_hosts"
        case bonjourService = "bonjour_service"
    }

    public init(
        v: Int = 1,
        name: String,
        port: Int,
        certSHA256: String,
        code: String,
        lanHosts: [String],
        tailscaleHosts: [String],
        bonjourService: String = "_vesper._tcp"
    ) {
        self.v = v
        self.name = name
        self.port = port
        self.certSHA256 = certSHA256
        self.code = code
        self.lanHosts = lanHosts
        self.tailscaleHosts = tailscaleHosts
        self.bonjourService = bonjourService
    }

    public static func decode(uri: String) throws -> CompanionPairingPayload {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "vesper-pair",
              comps.host?.lowercased() == "v1",
              let encoded = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              !encoded.isEmpty
        else {
            throw CompanionPairingError.invalidURI
        }
        guard let raw = Self.base64URLDecode(encoded) else {
            throw CompanionPairingError.invalidURI
        }
        let payload: CompanionPairingPayload
        do {
            payload = try JSONDecoder().decode(CompanionPairingPayload.self, from: raw)
        } catch {
            throw CompanionPairingError.missingData
        }
        guard payload.v == 1 else {
            throw CompanionPairingError.unsupportedVersion(payload.v)
        }
        let normalizedFP = payload.certSHA256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedFP.count == 64, normalizedFP.allSatisfy({ $0.isHexDigit }) else {
            throw CompanionPairingError.invalidFingerprint
        }
        guard payload.port > 0, payload.port <= 65535, !payload.code.isEmpty else {
            throw CompanionPairingError.missingData
        }
        if payload.lanHosts.isEmpty && payload.tailscaleHosts.isEmpty {
            throw CompanionPairingError.noEndpoints
        }
        return CompanionPairingPayload(
            v: payload.v,
            name: payload.name.isEmpty ? "Mac" : payload.name,
            port: payload.port,
            certSHA256: normalizedFP,
            code: payload.code,
            lanHosts: payload.lanHosts,
            tailscaleHosts: payload.tailscaleHosts,
            bonjourService: payload.bonjourService.isEmpty ? "_vesper._tcp" : payload.bonjourService
        )
    }

    public func encodeURI() throws -> String {
        let raw = try JSONEncoder().encode(self)
        let encoded = Self.base64URLEncode(raw)
        return "vesper-pair://v1?data=\(encoded)"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64 += String(repeating: "=", count: pad) }
        return Data(base64Encoded: b64)
    }
}

/// Persisted metadata for a paired Mac (the bearer token itself lives in Keychain).
public struct CompanionPairedHost: Codable, Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var hostName: String
    public var port: Int
    public var certSHA256: String
    public var lanHosts: [String]
    public var tailscaleHosts: [String]
    public var bonjourService: String

    public init(
        deviceId: String,
        deviceName: String,
        hostName: String,
        port: Int,
        certSHA256: String,
        lanHosts: [String],
        tailscaleHosts: [String],
        bonjourService: String = "_vesper._tcp"
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.hostName = hostName
        self.port = port
        self.certSHA256 = certSHA256
        self.lanHosts = lanHosts
        self.tailscaleHosts = tailscaleHosts
        self.bonjourService = bonjourService
    }
}

public enum CompanionTransportKind: String, Sendable, Equatable, Codable {
    case lan
    case tailscale

    public var displayName: String {
        switch self {
        case .lan: return "Local Wi-Fi"
        case .tailscale: return "Tailscale"
        }
    }
}

public enum CompanionConnectionState: Sendable, Equatable {
    case unpaired
    case connecting
    case connected(CompanionTransportKind, URL)
    case unreachable(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Server API DTOs

public struct CompanionDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var createdAt: String
    public var lastUsedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, platform
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

public struct CompanionStatusResponse: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var port: Int
    public var hostName: String
    public var bonjourService: String
    public var certFingerprint: String
    public var lanAddresses: [String]
    public var tailscaleAddresses: [String]
    public var tailscaleDNS: String?
    public var devices: [CompanionDeviceInfo]

    enum CodingKeys: String, CodingKey {
        case enabled, port, devices
        case hostName = "host_name"
        case bonjourService = "bonjour_service"
        case certFingerprint = "cert_fingerprint"
        case lanAddresses = "lan_addresses"
        case tailscaleAddresses = "tailscale_addresses"
        case tailscaleDNS = "tailscale_dns"
    }
}

public struct CompanionPairingCodeResponse: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: String
    public var payloadURI: String
    public var payload: CompanionPairingPayload

    enum CodingKeys: String, CodingKey {
        case code, payload
        case expiresAt = "expires_at"
        case payloadURI = "payload_uri"
    }
}

public struct CompanionPairResponse: Codable, Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceToken: String
    public var hostName: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case deviceToken = "device_token"
        case hostName = "host_name"
    }
}
