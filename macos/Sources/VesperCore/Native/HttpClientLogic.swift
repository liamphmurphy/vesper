import Foundation

/// Pure domain logic for the native HTTP client (`VesperCore`).
public enum HttpClientLogic {
    public static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    public static let maxHighlightBytes = 200_000
    public static let defaultTimeoutMs = 30_000
    public static let minTimeoutMs = 100
    public static let maxTimeoutMs = 120_000

    private static let varRegex = try! NSRegularExpression(pattern: #"\{\{\s*([a-zA-Z0-9_.:-]+)\s*\}\}"#)

    // MARK: Methods & Drafts

    public static func shortMethodLabel(_ method: String) -> String {
        switch method.uppercased() {
        case "DELETE": "DEL"
        case "OPTIONS": "OPT"
        default: method.uppercased()
        }
    }

    public static func methodTone(_ method: String) -> Tone {
        switch method.uppercased() {
        case "GET": .done
        case "POST": .accent
        case "PUT", "PATCH": .human
        case "DELETE": .blocked
        default: .neutral
        }
    }

    public static func methodColorToken(_ method: String) -> String {
        switch method.uppercased() {
        case "GET": "state-done"
        case "POST": "accent"
        case "PUT", "PATCH": "state-human"
        case "DELETE": "state-blocked"
        default: "text-secondary"
        }
    }

    public static func toDraft(_ request: HttpRequest) -> HttpRequestDraft {
        HttpRequestDraft(
            folderId: request.folderId,
            name: request.name,
            method: request.method,
            url: request.url,
            params: request.params,
            headers: request.headers,
            auth: request.auth,
            bodyMode: request.bodyMode,
            body: request.body,
            bodyForm: request.bodyForm,
            timeoutMs: request.timeoutMs,
            followRedirects: request.followRedirects,
            sortOrder: request.sortOrder
        )
    }

    public static func isDirty(_ draft: HttpRequestDraft, comparedTo request: HttpRequest) -> Bool {
        draft != toDraft(request)
    }

    public static func newRequestDraft(folderId: String?) -> HttpRequestDraft {
        HttpRequestDraft(
            folderId: folderId,
            name: "New Request",
            method: "GET",
            url: "{{base_url}}/",
            params: [],
            headers: [],
            auth: .inherit,
            bodyMode: .none,
            body: "",
            bodyForm: [],
            timeoutMs: defaultTimeoutMs,
            followRedirects: true,
            sortOrder: 0
        )
    }

    public static func clampTimeoutMs(_ ms: Int) -> Int {
        if ms <= 0 { return defaultTimeoutMs }
        if ms < minTimeoutMs { return minTimeoutMs }
        if ms > maxTimeoutMs { return maxTimeoutMs }
        return ms
    }

    public static func runTimeoutSeconds(timeoutMs: Int) -> TimeInterval {
        max(30, Double(clampTimeoutMs(timeoutMs)) / 1000.0 + 15.0)
    }

    // MARK: Auth & Header Inheritance

    public static func authLabel(_ type: HttpAuthType) -> String {
        switch type {
        case .inherit: "Inherit from parent"
        case .none: "No auth"
        case .bearer: "Bearer Token"
        case .basic: "Basic Auth"
        case .apikey: "API Key"
        case .oauth2: "OAuth 2.0 (Client Credentials)"
        }
    }

    public static func describeAuth(_ auth: HttpAuthConfig) -> String {
        authLabel(auth.type)
    }

    public struct InheritedAuthResolution: Sendable, Equatable {
        public var label: String
        public var sourceName: String
        public var fromWorkspace: Bool
        public var auth: HttpAuthConfig

        public init(label: String, sourceName: String, fromWorkspace: Bool, auth: HttpAuthConfig) {
            self.label = label
            self.sourceName = sourceName
            self.fromWorkspace = fromWorkspace
            self.auth = auth
        }
    }

    /// Walks folder parents safely (cycle-protected) up to the workspace's default auth.
    public static func resolveInheritedAuth(bundle: HttpWorkspaceBundle, folderId: String?) -> InheritedAuthResolution {
        let byId = Dictionary(uniqueKeysWithValues: bundle.folders.map { ($0.id, $0) })
        var chain: [HttpFolder] = []
        var cur = folderId
        var seen = Set<String>()
        while let id = cur, !seen.contains(id) {
            seen.insert(id)
            guard let folder = byId[id] else { break }
            chain.append(folder)
            cur = folder.parentFolderId
        }
        for folder in chain where folder.defaultAuth.type != .inherit {
            let summary = describeAuth(folder.defaultAuth)
            return InheritedAuthResolution(
                label: "Folder \"\(folder.name)\" (\(summary))",
                sourceName: folder.name,
                fromWorkspace: false,
                auth: folder.defaultAuth
            )
        }
        let wsSummary = describeAuth(bundle.workspace.defaultAuth)
        return InheritedAuthResolution(
            label: "Workspace \"\(bundle.workspace.name)\" (\(wsSummary))",
            sourceName: bundle.workspace.name,
            fromWorkspace: true,
            auth: bundle.workspace.defaultAuth
        )
    }

    /// Counts effective enabled headers inherited from the workspace and ancestor folders, matching
    /// the server's case-insensitive override rules (`ResolveInheritance` in runner.go).
    public static func inheritedEnabledHeaderCount(bundle: HttpWorkspaceBundle, folderId: String?) -> Int {
        let byId = Dictionary(uniqueKeysWithValues: bundle.folders.map { ($0.id, $0) })
        var chain: [HttpFolder] = []
        var cur = folderId
        var seen = Set<String>()
        while let id = cur, !seen.contains(id) {
            seen.insert(id)
            guard let folder = byId[id] else { break }
            chain.append(folder)
            cur = folder.parentFolderId
        }
        chain.reverse()

        var merged: [String: HttpKeyValue] = [:]
        func apply(_ list: [HttpKeyValue]) {
            for kv in list {
                let k = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { continue }
                merged[k.lowercased()] = HttpKeyValue(key: k, value: kv.value, enabled: kv.enabled)
            }
        }
        apply(bundle.workspace.defaultHeaders)
        for folder in chain {
            apply(folder.defaultHeaders)
        }
        return merged.values.filter(\.enabled).count
    }

    // MARK: Body Preview & Formatting

    public struct HttpBodyPreview: Sendable, Equatable {
        public var formatted: String
        public var detectedKind: String
        public var shikiLanguage: String?
        public var isPrettyFormatted: Bool

        public init(formatted: String, detectedKind: String, shikiLanguage: String?, isPrettyFormatted: Bool) {
            self.formatted = formatted
            self.detectedKind = detectedKind
            self.shikiLanguage = shikiLanguage
            self.isPrettyFormatted = isPrettyFormatted
        }
    }

    /// Pretty-prints valid JSON objects or arrays. Returns nil for invalid JSON or top-level primitives.
    public static func formatJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let formatted = String(data: prettyData, encoding: .utf8)
        else { return nil }
        return formatted
    }

    public static func contentType(from headers: [String: [String]]) -> String? {
        for (key, values) in headers where key.caseInsensitiveCompare("Content-Type") == .orderedSame {
            if let first = values.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
                return first
            }
        }
        return nil
    }

    public static func formatBodyPreview(_ raw: String, contentType: String? = nil) -> HttpBodyPreview {
        let mime = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if mime.contains("json") {
            if let pretty = formatJSON(raw) {
                return HttpBodyPreview(formatted: pretty, detectedKind: "json", shikiLanguage: "json", isPrettyFormatted: true)
            }
            return HttpBodyPreview(formatted: raw, detectedKind: "json", shikiLanguage: "json", isPrettyFormatted: false)
        }
        if mime.contains("html") {
            return HttpBodyPreview(formatted: raw, detectedKind: "html", shikiLanguage: "html", isPrettyFormatted: false)
        }
        if mime.contains("xml") || mime.contains("svg") {
            // Shiki bundles "html" (not "xml"), which highlights XML/SVG tags cleanly.
            return HttpBodyPreview(formatted: raw, detectedKind: "xml", shikiLanguage: "html", isPrettyFormatted: false)
        }
        if mime.contains("yaml") || mime.contains("yml") {
            return HttpBodyPreview(formatted: raw, detectedKind: "yaml", shikiLanguage: "yaml", isPrettyFormatted: false)
        }
        if mime.contains("javascript") || mime.contains("ecmascript") {
            return HttpBodyPreview(formatted: raw, detectedKind: "javascript", shikiLanguage: "javascript", isPrettyFormatted: false)
        }
        if mime.contains("css") {
            return HttpBodyPreview(formatted: raw, detectedKind: "css", shikiLanguage: "css", isPrettyFormatted: false)
        }
        if mime.contains("markdown") {
            return HttpBodyPreview(formatted: raw, detectedKind: "markdown", shikiLanguage: "markdown", isPrettyFormatted: false)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HttpBodyPreview(formatted: raw, detectedKind: "text", shikiLanguage: nil, isPrettyFormatted: false)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let pretty = formatJSON(raw) {
                return HttpBodyPreview(formatted: pretty, detectedKind: "json", shikiLanguage: "json", isPrettyFormatted: true)
            }
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
            return HttpBodyPreview(formatted: raw, detectedKind: "html", shikiLanguage: "html", isPrettyFormatted: false)
        }
        if lower.hasPrefix("<?xml") || (trimmed.hasPrefix("<") && (trimmed.contains("</") || trimmed.contains("/>"))) {
            return HttpBodyPreview(formatted: raw, detectedKind: "xml", shikiLanguage: "html", isPrettyFormatted: false)
        }
        return HttpBodyPreview(formatted: raw, detectedKind: "text", shikiLanguage: nil, isPrettyFormatted: false)
    }

    // MARK: Formatting & Status

    public static func formatBytes(_ bytes: Int) -> String {
        let clamped = max(0, bytes)
        if clamped < 1024 { return "\(clamped) B" }
        if clamped < 1024 * 1024 { return String(format: "%.1f KB", Double(clamped) / 1024.0) }
        return String(format: "%.2f MB", Double(clamped) / (1024.0 * 1024.0))
    }

    public static func statusTone(statusCode: Int, error: String?) -> String {
        if let error, !error.isEmpty { return "blocked" }
        if statusCode <= 0 { return "neutral" }
        if statusCode < 300 { return "done" }
        if statusCode < 400 { return "human" }
        return "blocked"
    }

    public static func statusBadgeText(statusCode: Int, statusText: String, error: String?) -> String {
        if let error, !error.isEmpty { return "ERROR" }
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return statusCode > 0 ? String(statusCode) : "—"
    }

    public static func envColorToken(_ color: HttpEnvColor) -> String {
        switch color {
        case .green: "state-done"
        case .amber: "state-human"
        case .red: "state-blocked"
        case .blue, .purple: "accent"
        case .gray: "text-tertiary"
        }
    }

    public static func defaultEnvColor(forName name: String) -> HttpEnvColor {
        let lower = name.lowercased()
        if lower.contains("prod") && !lower.contains("non") { return .red }
        if lower.contains("stag") { return .amber }
        return .green
    }

    // MARK: Tree & Selection

    public struct HttpTreeRow: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case folder(HttpFolder, isCollapsed: Bool, childCount: Int)
            case request(HttpRequest)
        }

        public var id: String
        public var depth: Int
        public var kind: Kind

        public init(id: String, depth: Int, kind: Kind) {
            self.id = id
            self.depth = depth
            self.kind = kind
        }
    }

    public static func matchesFilter(_ request: HttpRequest, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        return request.name.lowercased().contains(trimmed)
            || request.url.lowercased().contains(trimmed)
            || request.method.lowercased().contains(trimmed)
    }

    public static func visibleTreeRows(
        bundle: HttpWorkspaceBundle,
        filter: String,
        collapsedFolders: Set<String>
    ) -> [HttpTreeRow] {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmedFilter.isEmpty
        let folderIds = Set(bundle.folders.map(\.id))

        let sortedFolders = bundle.folders.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            return cmp == .orderedSame ? a.id < b.id : cmp == .orderedAscending
        }
        let sortedRequests = bundle.requests.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            return cmp == .orderedSame ? a.id < b.id : cmp == .orderedAscending
        }

        var foldersByParent: [String?: [HttpFolder]] = [:]
        for folder in sortedFolders {
            let key: String? = folder.parentFolderId.flatMap { folderIds.contains($0) ? $0 : nil }
            foldersByParent[key, default: []].append(folder)
        }

        var requestsByFolder: [String?: [HttpRequest]] = [:]
        for req in sortedRequests {
            let key: String? = req.folderId.flatMap { folderIds.contains($0) ? $0 : nil }
            requestsByFolder[key, default: []].append(req)
        }

        var visitedFolders = Set<String>()

        func build(parentId: String?, depth: Int) -> [HttpTreeRow] {
            var rows: [HttpTreeRow] = []
            for folder in foldersByParent[parentId] ?? [] {
                guard !visitedFolders.contains(folder.id) else { continue }
                visitedFolders.insert(folder.id)

                let directReqCount = requestsByFolder[folder.id]?.count ?? 0
                let directFolderCount = foldersByParent[folder.id]?.count ?? 0
                let childCount = directReqCount + directFolderCount
                let descendantRows = build(parentId: folder.id, depth: depth + 1)

                if isFiltering {
                    let folderMatches = folder.name.localizedCaseInsensitiveContains(trimmedFilter)
                    guard folderMatches || !descendantRows.isEmpty else { continue }
                    rows.append(HttpTreeRow(
                        id: "folder:\(folder.id)",
                        depth: depth,
                        kind: .folder(folder, isCollapsed: false, childCount: childCount)
                    ))
                    rows.append(contentsOf: descendantRows)
                } else {
                    let isCollapsed = collapsedFolders.contains(folder.id)
                    rows.append(HttpTreeRow(
                        id: "folder:\(folder.id)",
                        depth: depth,
                        kind: .folder(folder, isCollapsed: isCollapsed, childCount: childCount)
                    ))
                    if !isCollapsed {
                        rows.append(contentsOf: descendantRows)
                    }
                }
            }

            for req in requestsByFolder[parentId] ?? [] {
                guard !isFiltering || matchesFilter(req, query: trimmedFilter) else { continue }
                rows.append(HttpTreeRow(id: "req:\(req.id)", depth: depth, kind: .request(req)))
            }
            return rows
        }

        return build(parentId: nil, depth: 0)
    }

    public static func effectiveWorkspaceId(
        workspaces: [HttpWorkspace],
        selectedId: String?,
        rememberedId: String?
    ) -> String? {
        if let selectedId, workspaces.contains(where: { $0.id == selectedId }) { return selectedId }
        if let rememberedId, workspaces.contains(where: { $0.id == rememberedId }) { return rememberedId }
        return workspaces.first?.id
    }

    public static func effectiveRequest(bundle: HttpWorkspaceBundle?, selectedRequestId: String?) -> HttpRequest? {
        guard let bundle else { return nil }
        if let selectedRequestId, let match = bundle.requests.first(where: { $0.id == selectedRequestId }) {
            return match
        }
        return bundle.requests.first
    }

    // MARK: Variable Interpolation Preview

    public struct VariableResolution: Sendable, Equatable {
        public var resolved: String
        public var unresolvedVariables: [String]
        public var secretReferences: [String]
        public var substitutedVariables: [String: String]

        public init(
            resolved: String,
            unresolvedVariables: [String] = [],
            secretReferences: [String] = [],
            substitutedVariables: [String: String] = [:]
        ) {
            self.resolved = resolved
            self.unresolvedVariables = unresolvedVariables
            self.secretReferences = secretReferences
            self.substitutedVariables = substitutedVariables
        }
    }

    public static func activeVariables(
        workspace: HttpWorkspace,
        activeEnvironment: HttpEnvironment?
    ) -> (plain: [String: String], secrets: [String: String]) {
        var plain: [String: String] = [:]
        var secrets: [String: String] = [:]

        func apply(_ list: [HttpEnvVar]) {
            for item in list where item.enabled {
                let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                let handle = item.secretHandle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !handle.isEmpty {
                    secrets[key] = handle
                    plain.removeValue(forKey: key)
                } else {
                    plain[key] = item.value
                    secrets.removeValue(forKey: key)
                }
            }
        }

        apply(workspace.defaultVars)
        if let activeEnvironment {
            apply(activeEnvironment.variables)
        }
        return (plain, secrets)
    }

    public static func interpolatePreview(
        _ raw: String,
        workspace: HttpWorkspace,
        activeEnvironment: HttpEnvironment?
    ) -> VariableResolution {
        guard raw.contains("{{") else {
            return VariableResolution(resolved: raw)
        }
        let vars = activeVariables(workspace: workspace, activeEnvironment: activeEnvironment)
        let ns = raw as NSString
        let matches = varRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return VariableResolution(resolved: raw)
        }

        var output = ""
        var cursor = 0
        var unresolved: [String] = []
        var unresolvedSeen = Set<String>()
        var secretRefs: [String] = []
        var secretSeen = Set<String>()
        var substituted: [String: String] = [:]

        for match in matches {
            let fullRange = match.range(at: 0)
            let nameRange = match.range(at: 1)
            if fullRange.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let fullMatch = ns.substring(with: fullRange)
            let name = ns.substring(with: nameRange)

            if name.hasPrefix("secret:") {
                let handle = String(name.dropFirst("secret:".count))
                output += "•••(secret:\(handle))"
                if !handle.isEmpty && secretSeen.insert(handle).inserted {
                    secretRefs.append(handle)
                }
            } else if let handle = vars.secrets[name] {
                output += "•••(secret:\(handle))"
                if secretSeen.insert(handle).inserted {
                    secretRefs.append(handle)
                }
            } else if let value = vars.plain[name] {
                output += value
                substituted[name] = value
            } else {
                output += fullMatch
                if unresolvedSeen.insert(name).inserted {
                    unresolved.append(name)
                }
            }
            cursor = fullRange.location + fullRange.length
        }

        if cursor < ns.length {
            output += ns.substring(from: cursor)
        }

        return VariableResolution(
            resolved: output,
            unresolvedVariables: unresolved,
            secretReferences: secretRefs,
            substitutedVariables: substituted
        )
    }
}
