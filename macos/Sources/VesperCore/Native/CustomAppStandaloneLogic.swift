import Foundation

/// Pure logic for standalone Custom App macOS windows and their Permissions popover.
public enum CustomAppStandaloneLogic {
    public static let defaultWindowWidth: Double = 960
    public static let defaultWindowHeight: Double = 700
    public static let minWindowWidth: Double = 480
    public static let minWindowHeight: Double = 360

    public static func standalonePath(slug: String) -> String {
        "/apps/\(slug)?standalone=1"
    }

    public static func workbenchPath(slug: String) -> String {
        "/apps/\(slug)"
    }

    public static func frameAutosaveName(slug: String) -> String {
        "VesperCustomAppWindow.\(slug)"
    }

    /// True when a navigation inside a standalone Custom App window belongs to this app itself.
    /// Any other Vesper route redirects to the main Vesper workbench window.
    public static func shouldStayInStandaloneWindow(url: URL, baseURL: URL, slug: String) -> Bool {
        guard BridgeOrigin.matches(url: url, base: baseURL) else { return false }
        return CustomAppOSPolicy.urlMatchesSlug(url, slug: slug)
    }

    public enum CapabilityGroup: String, Sendable, Equatable, CaseIterable {
        case os
        case bridge
        case external

        public var title: String {
            switch self {
            case .os: "macOS Capabilities"
            case .bridge: "App & Vesper Bridge"
            case .external: "MCP, Secrets & Nix"
            }
        }
    }

    public struct CapabilityEntry: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let hint: String
        public let group: CapabilityGroup
        public let mode: API.CustomAppCapabilityMode
        public let requested: API.CustomAppCapabilityMode?

        public init(
            key: String,
            label: String,
            hint: String,
            group: CapabilityGroup,
            mode: API.CustomAppCapabilityMode,
            requested: API.CustomAppCapabilityMode? = nil
        ) {
            self.key = key
            self.label = label
            self.hint = hint
            self.group = group
            self.mode = mode
            self.requested = requested
        }

        /// True when the manifest requested this capability (non-denied) and it has not been allowed yet.
        public var isPendingRequest: Bool {
            guard let requested, requested != .denied else { return false }
            return mode != .allowed
        }
    }

    public struct MountEntry: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let hostPath: String?
        public let description: String?

        public var isConfigured: Bool {
            guard let hostPath else { return false }
            return !hostPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public init(name: String, hostPath: String?, description: String?) {
            self.name = name
            self.hostPath = hostPath
            self.description = description
        }
    }

    public struct PermissionsSnapshot: Sendable, Equatable {
        public let osCapabilities: [CapabilityEntry]
        public let bridgeCapabilities: [CapabilityEntry]
        public let externalCapabilities: [CapabilityEntry]
        public let mounts: [MountEntry]

        public var allCapabilities: [CapabilityEntry] {
            osCapabilities + bridgeCapabilities + externalCapabilities
        }

        public var allowedCount: Int {
            allCapabilities.filter { $0.mode == .allowed }.count
        }

        public var askCount: Int {
            allCapabilities.filter { $0.mode == .requiresApproval }.count
        }

        public var pendingRequestCount: Int {
            let pendingCaps = allCapabilities.filter(\.isPendingRequest).count
            let pendingMounts = mounts.filter { !$0.isConfigured }.count
            return pendingCaps + pendingMounts
        }
    }

    private static let builtInBridgeKeys: [(key: String, label: String, hint: String)] = [
        ("vesper.api:read", "Vesper API · Read", "GET requests to Vesper REST APIs"),
        ("vesper.api:write", "Vesper API · Write", "POST, PATCH, PUT, DELETE requests to Vesper APIs"),
        ("app.http:outbound", "Outbound HTTPS", "Public HTTPS fetches and remote image proxy"),
        ("app.ws:outbound", "Outbound WebSockets", "Public WSS connections proxied for the app UI"),
        ("app.media:download", "Download videos", "Save direct video files locally in Vesper"),
        ("app.media:relay", "AirPlay / HLS relay", "Serve filtered HLS playlists on your local network"),
    ]

    public static func buildPermissions(from app: API.CustomAppDetail) -> PermissionsSnapshot {
        let granted = app.capabilities
        let requested = app.manifest.requestedCapabilities ?? [:]

        let osEntries = CustomAppOSCapability.allCases.map { cap in
            CapabilityEntry(
                key: cap.rawValue,
                label: cap.label,
                hint: cap.hint,
                group: .os,
                mode: granted[cap.rawValue] ?? .denied,
                requested: requested[cap.rawValue]
            )
        }

        let bridgeEntries = builtInBridgeKeys.map { spec in
            CapabilityEntry(
                key: spec.key,
                label: spec.label,
                hint: spec.hint,
                group: .bridge,
                mode: granted[spec.key] ?? .denied,
                requested: requested[spec.key]
            )
        }

        let builtInSet = Set(osEntries.map(\.key) + bridgeEntries.map(\.key))
        var extraKeys = Set<String>()
        for key in requested.keys where !key.hasPrefix("app.sql:") && !builtInSet.contains(key) {
            extraKeys.insert(key)
        }
        for key in granted.keys where !key.hasPrefix("app.sql:") && !builtInSet.contains(key) {
            extraKeys.insert(key)
        }

        let extraEntries = extraKeys.sorted().map { key -> CapabilityEntry in
            let (label, hint) = describeExternalCapability(key)
            return CapabilityEntry(
                key: key,
                label: label,
                hint: hint,
                group: .external,
                mode: granted[key] ?? .denied,
                requested: requested[key]
            )
        }

        let mountsMap = app.mounts ?? [:]
        var seenMounts = Set<String>()
        var mountEntries: [MountEntry] = []
        for req in app.manifest.requestedMounts ?? [] {
            guard !req.name.isEmpty, seenMounts.insert(req.name).inserted else { continue }
            mountEntries.append(MountEntry(
                name: req.name,
                hostPath: mountsMap[req.name],
                description: req.description
            ))
        }
        for name in mountsMap.keys.sorted() where seenMounts.insert(name).inserted {
            mountEntries.append(MountEntry(name: name, hostPath: mountsMap[name], description: nil))
        }

        return PermissionsSnapshot(
            osCapabilities: osEntries,
            bridgeCapabilities: bridgeEntries,
            externalCapabilities: extraEntries,
            mounts: mountEntries
        )
    }

    public struct VMStatus: Decodable, Sendable, Equatable {
        public let available: Bool
        public let state: String
        public let activeCalls: Int
        public let mountCount: Int
        public let allowPublic: Bool

        enum CodingKeys: String, CodingKey {
            case available
            case state
            case activeCalls = "active_calls"
            case mountCount = "mount_count"
            case allowPublic = "allow_public"
        }

        public init(available: Bool, state: String, activeCalls: Int = 0, mountCount: Int = 0, allowPublic: Bool = false) {
            self.available = available
            self.state = state
            self.activeCalls = activeCalls
            self.mountCount = mountCount
            self.allowPublic = allowPublic
        }

        public var stateLabel: String {
            switch state {
            case "running": return "Running"
            case "paused": return "Paused"
            default: return "Stopped"
            }
        }
    }

    private static func encodedSlug(_ slug: String) -> String {
        slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
    }

    public static func getVMStatusRequest(slug: String) -> APIRequest<VMStatus> {
        APIRequest(
            method: "GET",
            template: "/custom-apps/{slug}/vm",
            path: "/api/v1/custom-apps/\(encodedSlug(slug))/vm",
            decode: .json
        )
    }

    public static func stopVMRequest(slug: String) -> APIRequest<VMStatus> {
        APIRequest(
            method: "POST",
            template: "/custom-apps/{slug}/vm/stop",
            path: "/api/v1/custom-apps/\(encodedSlug(slug))/vm/stop",
            decode: .json
        )
    }

    public static func restartVMRequest(slug: String) -> APIRequest<VMStatus> {
        APIRequest(
            method: "POST",
            template: "/custom-apps/{slug}/vm/restart",
            path: "/api/v1/custom-apps/\(encodedSlug(slug))/vm/restart",
            decode: .json
        )
    }

    public static func notifyWindowClosedRequest(slug: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "POST",
            template: "/custom-apps/{slug}/vm/window-closed",
            path: "/api/v1/custom-apps/\(encodedSlug(slug))/vm/window-closed",
            decode: .empty
        )
    }

    public static func updatedCapabilities(
        _ current: API.CustomAppCapabilities,
        key: String,
        mode: API.CustomAppCapabilityMode
    ) -> API.CustomAppCapabilities {
        var next = current
        next[key] = mode
        return next
    }

    private static func describeExternalCapability(_ key: String) -> (label: String, hint: String) {
        if key.hasPrefix("nix:") {
            let pkg = String(key.dropFirst("nix:".count))
            return ("Nix · \(pkg)", "Run nixpkgs#\(pkg) in a background tool job")
        }
        if key.hasPrefix("secret:") {
            let handle = String(key.dropFirst("secret:".count))
            return ("Secret · \(handle)", "Authenticated secretFetch calls using this Vesper secret")
        }
        if key.hasPrefix("mcp:") {
            let rest = String(key.dropFirst("mcp:".count))
            return ("MCP · \(rest)", "Invoke connector MCP tools")
        }
        return (key, "Requested by app manifest")
    }
}
