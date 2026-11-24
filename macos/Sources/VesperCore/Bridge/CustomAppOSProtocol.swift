import Foundation

/// Constants and strict bounds for the narrow Custom App macOS OS capability bridge.
public enum CustomAppOSLimits {
    public static let protocolVersion = 1
    public static let handlerName = "vesperCustomAppOS"
    public static let eventName = "vesper-custom-app-os"

    public static let maxRequestIdChars = 128
    public static let maxNotifyTitleChars = 120
    public static let maxNotifySubtitleChars = 120
    public static let maxNotifyBodyChars = 500
    public static let maxClipboardBytes = 1_000_000
    public static let maxPickerTitleChars = 120
    public static let maxPickerExtensions = 20
    public static let maxPickedFiles = 5
    public static let maxPickedFileBytes = 2 * 1024 * 1024
    public static let maxPickedTotalBytes = 5 * 1024 * 1024
    public static let maxInlineTextBytes = 512 * 1024
}

public enum CustomAppOSCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case notifications = "os.notifications"
    case clipboard = "os.clipboard"
    case filePicker = "os.file_picker"

    public var label: String {
        switch self {
        case .notifications: "macOS · Notifications"
        case .clipboard: "macOS · Clipboard"
        case .filePicker: "macOS · File picker"
        }
    }

    public var hint: String {
        switch self {
        case .notifications: "Post native macOS Notification Center alerts"
        case .clipboard: "Read and write plain text on the macOS clipboard"
        case .filePicker: "Open a macOS file dialog to import selected files"
        }
    }
}

public enum CustomAppOSAction: String, Codable, Sendable, Hashable {
    case notify = "notify"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case filePicker = "filePicker"

    public var capability: CustomAppOSCapability {
        switch self {
        case .notify: .notifications
        case .clipboardRead, .clipboardWrite: .clipboard
        case .filePicker: .filePicker
        }
    }
}

public enum CustomAppOSRequestError: Error, Sendable, Equatable {
    case malformed(String)
}

/// Decoded and sanitized request from the trusted Vesper Custom App host page to the native OS bridge.
public struct CustomAppOSRequest: Sendable, Equatable {
    public var requestId: String
    public var slug: String
    public var action: CustomAppOSAction
    public var approved: Bool
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var silent: Bool
    public var text: String?
    public var multiple: Bool
    public var extensions: [String]

    public init(
        requestId: String,
        slug: String,
        action: CustomAppOSAction,
        approved: Bool = false,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        silent: Bool = false,
        text: String? = nil,
        multiple: Bool = false,
        extensions: [String] = []
    ) {
        self.requestId = requestId
        self.slug = slug
        self.action = action
        self.approved = approved
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.silent = silent
        self.text = text
        self.multiple = multiple
        self.extensions = extensions
    }

    private struct Wire: Decodable {
        var v: Int
        var requestId: String
        var slug: String
        var action: String
        var approved: Bool?
        var title: String?
        var subtitle: String?
        var body: String?
        var silent: Bool?
        var text: String?
        var multiple: Bool?
        var extensions: [String]?
    }

    public static func decode(fromJSONObject object: Any) throws -> CustomAppOSRequest {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CustomAppOSRequestError.malformed("not a JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw CustomAppOSRequestError.malformed("invalid request fields")
        }
        guard wire.v == CustomAppOSLimits.protocolVersion else {
            throw CustomAppOSRequestError.malformed("unsupported protocol version \(wire.v)")
        }
        let reqId = wire.requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reqId.isEmpty, reqId.count <= CustomAppOSLimits.maxRequestIdChars else {
            throw CustomAppOSRequestError.malformed("invalid requestId")
        }
        let slug = wire.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppsHomeLogic.validateSlug(slug) == nil else {
            throw CustomAppOSRequestError.malformed("invalid custom app slug")
        }
        guard let action = CustomAppOSAction(rawValue: wire.action) else {
            throw CustomAppOSRequestError.malformed("unknown OS action \(wire.action)")
        }
        let approved = wire.approved == true

        switch action {
        case .notify:
            let title = (wire.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CustomAppOSRequestError.malformed("notification title is required")
            }
            let clampedTitle = String(title.prefix(CustomAppOSLimits.maxNotifyTitleChars))
            let subtitle = wire.subtitle.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CustomAppOSLimits.maxNotifySubtitleChars)) }
            let body = wire.body.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CustomAppOSLimits.maxNotifyBodyChars)) }
            return CustomAppOSRequest(
                requestId: reqId,
                slug: slug,
                action: action,
                approved: approved,
                title: clampedTitle,
                subtitle: subtitle?.isEmpty == true ? nil : subtitle,
                body: body?.isEmpty == true ? nil : body,
                silent: wire.silent == true
            )
        case .clipboardRead:
            return CustomAppOSRequest(
                requestId: reqId,
                slug: slug,
                action: action,
                approved: approved
            )
        case .clipboardWrite:
            guard let text = wire.text else {
                throw CustomAppOSRequestError.malformed("clipboard text is required")
            }
            guard text.utf8.count <= CustomAppOSLimits.maxClipboardBytes else {
                throw CustomAppOSRequestError.malformed("clipboard text exceeds \(CustomAppOSLimits.maxClipboardBytes) bytes")
            }
            return CustomAppOSRequest(
                requestId: reqId,
                slug: slug,
                action: action,
                approved: approved,
                text: text
            )
        case .filePicker:
            let title = wire.title.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CustomAppOSLimits.maxPickerTitleChars)) }
            let extensions = CustomAppOSPolicy.sanitizeExtensions(wire.extensions ?? [])
            return CustomAppOSRequest(
                requestId: reqId,
                slug: slug,
                action: action,
                approved: approved,
                title: title?.isEmpty == true ? nil : title,
                multiple: wire.multiple == true,
                extensions: extensions
            )
        }
    }
}

public struct CustomAppOSResponse: Codable, Sendable, Equatable {
    public var v: Int
    public var requestId: String
    public var ok: Bool
    public var data: JSONValue?
    public var error: String?
    public var approvalRequired: Bool?
    public var capability: String?
    public var summary: String?

    public init(
        v: Int = CustomAppOSLimits.protocolVersion,
        requestId: String,
        ok: Bool,
        data: JSONValue? = nil,
        error: String? = nil,
        approvalRequired: Bool? = nil,
        capability: String? = nil,
        summary: String? = nil
    ) {
        self.v = v
        self.requestId = requestId
        self.ok = ok
        self.data = data
        self.error = error
        self.approvalRequired = approvalRequired
        self.capability = capability
        self.summary = summary
    }

    public static func success(requestId: String, data: JSONValue) -> CustomAppOSResponse {
        CustomAppOSResponse(requestId: requestId, ok: true, data: data)
    }

    public static func failure(requestId: String, error: String) -> CustomAppOSResponse {
        CustomAppOSResponse(requestId: requestId, ok: false, error: error)
    }

    public static func approvalRequired(requestId: String, capability: CustomAppOSCapability, summary: String) -> CustomAppOSResponse {
        CustomAppOSResponse(
            requestId: requestId,
            ok: false,
            error: "capability \(capability.rawValue) requires approval",
            approvalRequired: true,
            capability: capability.rawValue,
            summary: summary
        )
    }

    public func toJSONObject() throws -> Any {
        let encoded = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: encoded)
    }
}

public enum CustomAppOSDecision: Sendable, Equatable {
    case allow
    case requireApproval(capability: CustomAppOSCapability, summary: String)
    case deny(message: String)
}

/// Pure permission and boundary enforcement for native macOS Custom App capabilities.
public enum CustomAppOSPolicy {
    /// Extracts the custom app slug from an `/apps/<slug>` URL path, rejecting reserved slugs or nested paths.
    public static func customAppSlug(from url: URL?) -> String? {
        guard let url else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2, segments[0] == "apps" else { return nil }
        let raw = segments[1].removingPercentEncoding ?? segments[1]
        guard AppsHomeLogic.validateSlug(raw) == nil else { return nil }
        return raw
    }

    /// Confirms that the requesting web view's current URL is actually `/apps/<slug>`.
    public static func urlMatchesSlug(_ url: URL?, slug: String) -> Bool {
        guard AppsHomeLogic.validateSlug(slug) == nil else { return false }
        return customAppSlug(from: url) == slug
    }

    /// Effective mode for an OS capability; defaults closed to `.denied`.
    public static func effectiveMode(
        capabilities: API.CustomAppCapabilities,
        capability: CustomAppOSCapability
    ) -> API.CustomAppCapabilityMode {
        capabilities[capability.rawValue] ?? .denied
    }

    /// Server-authoritative capability check. `.denied` (and unknown modes) always fail closed, even when `approved == true`.
    public static func evaluate(
        slug: String,
        capabilities: API.CustomAppCapabilities,
        request: CustomAppOSRequest
    ) -> CustomAppOSDecision {
        let cap = request.action.capability
        let mode = effectiveMode(capabilities: capabilities, capability: cap)
        switch mode {
        case .allowed:
            return .allow
        case .requiresApproval:
            if request.approved {
                return .allow
            }
            return .requireApproval(capability: cap, summary: approvalSummary(for: request))
        case .denied:
            return .deny(message: "capability \(cap.rawValue) is denied for custom app \"\(slug)\"")
        default:
            return .deny(message: "capability \(cap.rawValue) is denied for custom app \"\(slug)\"")
        }
    }

    public static func approvalSummary(for request: CustomAppOSRequest) -> String {
        switch request.action {
        case .notify:
            let title = request.title ?? "Notification"
            return "Send macOS notification: \u{201C}\(title)\u{201D}"
        case .clipboardRead:
            return "Read plain text from the macOS clipboard"
        case .clipboardWrite:
            return "Copy text to the macOS clipboard"
        case .filePicker:
            return request.multiple ? "Choose files using the macOS file picker" : "Choose a file using the macOS file picker"
        }
    }

    public static func sanitizeExtensions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = trimmed.drop(while: { $0 == "." }).lowercased()
            guard stripped.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil else { continue }
            if seen.insert(stripped).inserted {
                out.append(stripped)
                if out.count >= CustomAppOSLimits.maxPickerExtensions { break }
            }
        }
        return out
    }

    /// Serializes one picked file with bounded inline UTF-8 text (never exposing host filesystem paths).
    public static func encodePickedFile(name: String, data: Data, contentType: String) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(name),
            "size": .int(data.count),
            "contentType": .string(contentType.isEmpty ? "application/octet-stream" : contentType),
            "base64": .string(data.base64EncodedString()),
        ]
        if data.count <= CustomAppOSLimits.maxInlineTextBytes,
           !data.contains(0),
           let text = String(data: data, encoding: .utf8) {
            dict["text"] = .string(text)
        }
        return .object(dict)
    }
}
