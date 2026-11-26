import Foundation

// MARK: - Security, Privacy & Proxy Configuration Models

public enum BrowserPermissionKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case camera
    case microphone
    case geolocation
    case downloads

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .geolocation: return "Location"
        case .downloads: return "Downloads"
        }
    }

    public var icon: String {
        switch self {
        case .camera: return "video"
        case .microphone: return "mic"
        case .geolocation: return "location"
        case .downloads: return "arrow.down.circle"
        }
    }
}

public enum BrowserPermissionSetting: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case ask
    case allow
    case deny

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
}

public enum BrowserProxyMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case none
    case httpConnect
    case socks5

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "System Default"
        case .httpConnect: return "HTTP CONNECT"
        case .socks5: return "SOCKS5"
        }
    }
}

public struct BrowserProxyConfig: Codable, Sendable, Equatable, Hashable {
    public var mode: BrowserProxyMode
    public var host: String
    public var port: Int
    public var applyToPrivateTabs: Bool

    public init(
        mode: BrowserProxyMode = .none,
        host: String = "",
        port: Int = 1080,
        applyToPrivateTabs: Bool = true
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.applyToPrivateTabs = applyToPrivateTabs
    }

    public static let none = BrowserProxyConfig()

    public var isConfigured: Bool {
        mode != .none
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case host
        case port
        case applyToPrivateTabs = "apply_to_private_tabs"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(BrowserProxyMode.self, forKey: .mode) ?? .none
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 1080
        applyToPrivateTabs = try c.decodeIfPresent(Bool.self, forKey: .applyToPrivateTabs) ?? true
    }
}

public struct BrowserSecurityConfig: Codable, Sendable, Equatable, Hashable {
    /// Strict HTTPS-Only mode upgrades all non-local HTTP navigations to HTTPS with a fallback prompt.
    /// (WebKit's `upgradeKnownHostsToHTTPS` is always enabled regardless of this toggle.)
    public var httpsOnlyMode: Bool
    /// Enables WebKit Lockdown Mode (`WKWebpagePreferences.isLockdownModeEnabled`) by default.
    public var lockdownModeEnabled: Bool
    /// Strips known cross-site tracking query parameters (`fbclid`, `gclid`, `utm_*`, etc.).
    public var stripTrackingParameters: Bool
    /// Requires Touch ID / macOS user verification before autofilling or copying saved credentials.
    public var requireTouchIDForAutofill: Bool
    /// Prompts before downloading files from a host without an `allow` permission (always warns on risky files).
    public var confirmDownloads: Bool
    /// Blocks web-initiated top-level `data:` navigations to prevent originless phishing pages.
    public var blockTopLevelDataNavigations: Bool

    public init(
        httpsOnlyMode: Bool = false,
        lockdownModeEnabled: Bool = false,
        stripTrackingParameters: Bool = true,
        requireTouchIDForAutofill: Bool = false,
        confirmDownloads: Bool = true,
        blockTopLevelDataNavigations: Bool = true
    ) {
        self.httpsOnlyMode = httpsOnlyMode
        self.lockdownModeEnabled = lockdownModeEnabled
        self.stripTrackingParameters = stripTrackingParameters
        self.requireTouchIDForAutofill = requireTouchIDForAutofill
        self.confirmDownloads = confirmDownloads
        self.blockTopLevelDataNavigations = blockTopLevelDataNavigations
    }

    public static let `default` = BrowserSecurityConfig()

    enum CodingKeys: String, CodingKey {
        case httpsOnlyMode = "https_only_mode"
        case lockdownModeEnabled = "lockdown_mode_enabled"
        case stripTrackingParameters = "strip_tracking_parameters"
        case requireTouchIDForAutofill = "require_touch_id_for_autofill"
        case confirmDownloads = "confirm_downloads"
        case blockTopLevelDataNavigations = "block_top_level_data_navigations"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        httpsOnlyMode = try c.decodeIfPresent(Bool.self, forKey: .httpsOnlyMode) ?? false
        lockdownModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockdownModeEnabled) ?? false
        stripTrackingParameters = try c.decodeIfPresent(Bool.self, forKey: .stripTrackingParameters) ?? true
        requireTouchIDForAutofill = try c.decodeIfPresent(Bool.self, forKey: .requireTouchIDForAutofill) ?? false
        confirmDownloads = try c.decodeIfPresent(Bool.self, forKey: .confirmDownloads) ?? true
        blockTopLevelDataNavigations = try c.decodeIfPresent(Bool.self, forKey: .blockTopLevelDataNavigations) ?? true
    }
}

// MARK: - Connection Security & Certificate Summary

public enum BrowserConnectionSecurity: Sendable, Equatable {
    case internalPage
    case secure
    case mixedContent
    case localHTTP
    case insecureHTTP
    case tlsError(String)

    public var isWarning: Bool {
        switch self {
        case .mixedContent, .insecureHTTP, .tlsError: return true
        case .internalPage, .secure, .localHTTP: return false
        }
    }

    public var label: String {
        switch self {
        case .internalPage: return "Internal Page"
        case .secure: return "Connection is Secure"
        case .mixedContent: return "Mixed Content (Partially Encrypted)"
        case .localHTTP: return "Local Network (HTTP)"
        case .insecureHTTP: return "Not Secure (Unencrypted HTTP)"
        case .tlsError: return "Certificate Error"
        }
    }
}

public struct BrowserCertificateSummary: Sendable, Equatable {
    public var subject: String
    public var issuer: String
    public var validFrom: Date?
    public var validUntil: Date?
    public var chainCount: Int
    public var isTrusted: Bool

    public init(
        subject: String,
        issuer: String = "",
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        chainCount: Int = 1,
        isTrusted: Bool = true
    ) {
        self.subject = subject
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.chainCount = chainCount
        self.isTrusted = isTrusted
    }
}

// MARK: - IDN / Punycode Homograph Guard

public struct BrowserHostSecurityDisplay: Sendable, Equatable {
    public var displayHost: String
    public var isSuspiciousIDN: Bool
    public var warningReason: String?

    public init(displayHost: String, isSuspiciousIDN: Bool = false, warningReason: String? = nil) {
        self.displayHost = displayHost
        self.isSuspiciousIDN = isSuspiciousIDN
        self.warningReason = warningReason
    }
}

public enum BrowserIDNGuard {
    /// Zero-width, format, and bidirectional override scalars used to spoof hostnames.
    private static func isDangerousControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x200B...0x200F).contains(v)
            || (0x202A...0x202E).contains(v)
            || (0x2060...0x2069).contains(v)
            || v == 0xFEFF
            || v == 0x00AD
    }

    private enum ScriptBucket {
        case latin
        case cyrillic
        case greek
        case otherNonASCII
        case neutral
    }

    private static func bucket(for scalar: Unicode.Scalar) -> ScriptBucket {
        let v = scalar.value
        if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
            || (0x00C0...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v)
        {
            return .latin
        }
        if (0x0400...0x052F).contains(v) { return .cyrillic }
        if (0x0370...0x03FF).contains(v) || (0x1F00...0x1FFF).contains(v) { return .greek }
        if v < 0x0080 { return .neutral }
        return .otherNonASCII
    }

    /// Cyrillic/Greek scalars commonly substituted for ASCII Latin letters in homograph spoofing.
    private static let latinConfusableScalars: Set<UInt32> = [
        // Cyrillic lookalikes: а, с, е, і, ј, о, р, ѕ, х, у, ԁ, ԝ
        0x0430, 0x0441, 0x0435, 0x0456, 0x0458, 0x043E, 0x0440, 0x0455, 0x0445, 0x0443, 0x0501, 0x051D,
        0x0410, 0x0421, 0x0415, 0x0406, 0x0408, 0x041E, 0x0420, 0x0405, 0x0425, 0x0423,
        // Greek lookalikes: α, ε, ι, ο, ρ, υ, ν, κ
        0x03B1, 0x03B5, 0x03B9, 0x03BF, 0x03C1, 0x03C5, 0x03BD, 0x03BA,
        0x0391, 0x0392, 0x0395, 0x0396, 0x0397, 0x0399, 0x039A, 0x039C, 0x039D, 0x039F, 0x03A1, 0x03A4, 0x03A7,
    ]

    public static func inspect(urlString: String) -> BrowserHostSecurityDisplay {
        guard let url = URL(string: urlString), let rawHost = url.host, !rawHost.isEmpty else {
            return BrowserHostSecurityDisplay(displayHost: "")
        }
        return inspect(host: rawHost)
    }

    public static func inspect(host rawHost: String) -> BrowserHostSecurityDisplay {
        let lower = rawHost.lowercased()
        let display = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        let labels = display.split(separator: ".").map(String.init)

        // 1. Check invisible / bidi-override spoofing characters.
        if display.unicodeScalars.contains(where: isDangerousControlScalar) {
            return BrowserHostSecurityDisplay(
                displayHost: display,
                isSuspiciousIDN: true,
                warningReason: "Domain contains hidden or bidirectional control characters."
            )
        }

        // 2. Check explicit punycode labels (`xn--`).
        if labels.contains(where: { $0.hasPrefix("xn--") }) {
            return BrowserHostSecurityDisplay(
                displayHost: display,
                isSuspiciousIDN: true,
                warningReason: "Internationalized domain shown in punycode (xn--) to prevent lookalike spoofing."
            )
        }

        // 3. Check mixed-script labels (e.g. Latin + Cyrillic or Greek) and whole-label lookalikes.
        for label in labels {
            var hasLatin = false
            var hasCyrillic = false
            var hasGreek = false
            var nonASCIICount = 0
            var confusableCount = 0

            for scalar in label.unicodeScalars {
                switch bucket(for: scalar) {
                case .latin:
                    hasLatin = true
                    if scalar.value >= 0x0080 { nonASCIICount += 1 }
                case .cyrillic:
                    hasCyrillic = true
                    nonASCIICount += 1
                case .greek:
                    hasGreek = true
                    nonASCIICount += 1
                case .otherNonASCII:
                    nonASCIICount += 1
                case .neutral:
                    break
                }
                if latinConfusableScalars.contains(scalar.value) {
                    confusableCount += 1
                }
            }

            if hasLatin && (hasCyrillic || hasGreek) {
                return BrowserHostSecurityDisplay(
                    displayHost: display,
                    isSuspiciousIDN: true,
                    warningReason: "Domain mixes Latin and Cyrillic/Greek characters (possible homograph spoof)."
                )
            }
            if (hasCyrillic || hasGreek) && nonASCIICount > 0 && confusableCount == nonASCIICount {
                return BrowserHostSecurityDisplay(
                    displayHost: display,
                    isSuspiciousIDN: true,
                    warningReason: "Domain consists entirely of lookalike Cyrillic/Greek characters."
                )
            }
        }

        return BrowserHostSecurityDisplay(displayHost: display, isSuspiciousIDN: false, warningReason: nil)
    }
}

// MARK: - Link Tracking Parameter Stripping

public enum BrowserTrackingParamStripper {
    /// High-confidence cross-site tracking parameters safe to strip without breaking OAuth/session flows.
    public static let exactTrackingParams: Set<String> = [
        "fbclid", "gclid", "gbraid", "wbraid", "dclid", "yclid", "msclkid",
        "mc_eid", "mc_cid", "igshid", "igsh",
        "_hsenc", "_hsmi", "hsctatracking", "mkt_tok",
        "vero_id", "vero_conv", "oly_enc_id", "oly_anon_id",
        "rb_clickid", "s_cid", "wickedid",
        "twclid", "ttclid", "li_fat_id", "scid", "epik",
        "spm", "ref_src", "ref_url", "yclid", "_openstat",
        "pk_campaign", "pk_kwd", "pk_source", "pk_medium", "pk_content",
        "mtm_campaign", "mtm_kwd", "mtm_source", "mtm_medium", "mtm_content",
        "icid", "ncid", "sr_share", "guccounter", "guce_referrer", "guce_referrer_sig",
    ]

    public static let trackingPrefixes: [String] = [
        "utm_",
    ]

    public static func isTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        if exactTrackingParams.contains(lower) { return true }
        return trackingPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    public static func strip(from url: URL) -> (url: URL, removedCount: Int) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty
        else {
            return (url, 0)
        }

        let kept = items.filter { !isTrackingParameter($0.name) }
        let removed = items.count - kept.count
        guard removed > 0 else { return (url, 0) }

        comps.queryItems = kept.isEmpty ? nil : kept
        guard let cleaned = comps.url else { return (url, 0) }
        return (cleaned, removed)
    }
}

// MARK: - HTTPS-Only, Navigation & Connection Guards

public enum BrowserHTTPSGuard {
    public static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 || octets[0] == 127 { return true }
            if octets[0] == 192 && octets[1] == 168 { return true }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
            if octets[0] == 169 && octets[1] == 254 { return true }
        }
        return false
    }

    /// Returns an `https://` URL when `httpsOnlyEnabled` is active and `url` is a remote `http://`
    /// URL whose host is not in `exceptions`. Returns `nil` when no upgrade is needed.
    public static func upgradedHTTPSURL(
        for url: URL,
        httpsOnlyEnabled: Bool,
        exceptions: [String]
    ) -> URL? {
        guard httpsOnlyEnabled,
              url.scheme?.lowercased() == "http",
              let rawHost = url.host, !rawHost.isEmpty,
              !isLocalOrPrivateHost(rawHost)
        else { return nil }

        if let normalized = BrowserPageGuard.normalizeHost(rawHost),
           exceptions.contains(where: { BrowserPageGuard.isCovered(normalized, by: $0) })
        {
            return nil
        }

        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "https"
        // Drop explicit port 80 so HTTPS uses 443 cleanly.
        if comps?.port == 80 { comps?.port = nil }
        return comps?.url
    }

    /// Blocks web-initiated top-level `data:` navigations (classic originless phishing vector).
    public static func shouldBlockNavigation(
        url: URL,
        isMainFrame: Bool,
        blockTopLevelData: Bool
    ) -> Bool {
        guard blockTopLevelData, isMainFrame else { return false }
        return url.scheme?.lowercased() == "data"
    }

    public static func connectionSecurity(
        urlString: String,
        hasOnlySecureContent: Bool,
        tlsError: String?
    ) -> BrowserConnectionSecurity {
        if let tlsError, !tlsError.isEmpty {
            return .tlsError(tlsError)
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return .internalPage
        }
        switch scheme {
        case "https":
            return hasOnlySecureContent ? .secure : .mixedContent
        case "http":
            if let host = url.host, isLocalOrPrivateHost(host) {
                return .localHTTP
            }
            return .insecureHTTP
        default:
            return .internalPage
        }
    }

    public static func isLockdownActive(
        for urlString: String,
        globalEnabled: Bool,
        enabledHosts: [String],
        disabledHosts: [String]
    ) -> Bool {
        guard let host = BrowserPageGuard.normalizeHost(urlString) else { return globalEnabled }
        if globalEnabled {
            return !disabledHosts.contains(where: { BrowserPageGuard.isCovered(host, by: $0) })
        }
        return enabledHosts.contains(where: { BrowserPageGuard.isCovered(host, by: $0) })
    }

    public static func isJavaScriptAllowed(
        for urlString: String,
        disabledHosts: [String]
    ) -> Bool {
        guard let host = BrowserPageGuard.normalizeHost(urlString) else { return true }
        return !disabledHosts.contains(where: { BrowserPageGuard.isCovered(host, by: $0) })
    }

    /// Returns `true` for NSError codes representing TLS/SSL certificate or handshake failures.
    public static func isTLSError(domain: String, code: Int) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        let tlsCodes: Set<Int> = [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
        ]
        return tlsCodes.contains(code)
    }
}

// MARK: - Download Safety Guard

public enum BrowserDownloadGuard {
    public static let riskyExtensions: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "command", "sh", "zsh", "bash", "csh",
        "mobileconfig", "jar", "jnlp", "exe", "msi", "scr", "bat", "cmd",
        "iso", "img", "scpt", "applescript", "workflow", "action", "terminal",
        "inetloc", "webloc", "pkgproj", "kext", "dylib",
    ]

    public static func isRiskyFilename(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return riskyExtensions.contains(ext)
    }

    public static func riskWarning(for filename: String) -> String? {
        guard isRiskyFilename(filename) else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        return "This file (.\(ext)) can run code or install software on your Mac. macOS Gatekeeper quarantine will be applied."
    }
}

// MARK: - Safari User-Agent Alignment

public enum BrowserUserAgent {
    /// Builds a standard macOS Safari User-Agent aligned with the host macOS Safari version
    /// (keeping `Intel Mac OS X 10_15_7` frozen per WebKit's standard UA freeze policy).
    public static func safariUserAgent(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let safariVersion: String
        switch osVersion.majorVersion {
        case 26...:
            safariVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        case 15:
            safariVersion = "18.\(max(0, osVersion.minorVersion))"
        case 14:
            safariVersion = "17.\(max(0, osVersion.minorVersion))"
        default:
            safariVersion = "26.0"
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }
}
