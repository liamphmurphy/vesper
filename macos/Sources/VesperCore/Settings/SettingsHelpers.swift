import Foundation

// MARK: - Memory helpers (`web/lib/memory-ui.ts`)

public struct MemoryImportParseResult: Sendable, Equatable {
    public var entries: [API.MemoryImportEntry]
    public var skipped: Int
    public var error: String?

    public init(entries: [API.MemoryImportEntry], skipped: Int, error: String? = nil) {
        self.entries = entries
        self.skipped = skipped
        self.error = error
    }
}

public enum MemoryUIHelpers {
    public static let memoryTypes: [String] = ["preference", "fact", "project", "person", "work", "life", "other"]
    public static let personaMemoryTypes: [String] = memoryTypes + ["moment"]
    public static let importMax = 200

    public static let importPrompt = """
    I'm moving to a new personal assistant called Vesper and want to bring over what you know about me. List everything you remember about me from our conversations and your saved memory: my preferences, facts about me, the people in my life, my work and projects, and anything else a personal assistant should know. Leave out passwords, API keys, tokens and other secrets.

    Reply with only one JSON code block in exactly this shape, one object per distinct thing:

    ```json
    {"memories": [
      {"title": "Prefers metric units", "summary": "Uses kilometres and Celsius, not miles or Fahrenheit.", "body": "", "type": "preference", "tags": ["units"]}
    ]}
    ```

    Rules:
    - title: a short name, under 80 characters.
    - summary: one sentence saying what to remember.
    - body: extra detail only when the summary isn't enough, otherwise "".
    - type: one of preference, fact, project, person, work, life, other.
    - tags: 1 to 4 lowercase keywords.
    - Keep unrelated things in separate entries. Don't invent anything.
    """

    public static func typeLabel(_ t: String) -> String {
        guard let first = t.first else { return "Other" }
        return first.uppercased() + t.dropFirst()
    }

    /// `"a, B ,a,,c"` -> `["a", "b", "c"]`: lowercase, trimmed, `#` stripped, deduped, <=40 chars, max 12.
    public static func parseTags(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: ",", omittingEmptySubsequences: false) {
            var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while v.hasPrefix("#") { v.removeFirst() }
            v = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !v.isEmpty, v.count <= 40, !out.contains(v) {
                out.append(v)
            }
        }
        return Array(out.prefix(12))
    }

    public static func exportMarkdown(memories: [API.Memory], exportedAt: String) -> String {
        var lines = ["# Assistant memory", "", "Exported \(exportedAt). \(memories.count) entries.", ""]
        for m in memories {
            let retiredSuffix = m.supersededBy != nil ? " (retired)" : ""
            lines.append("## \(m.title)\(retiredSuffix)")
            lines.append("")
            if !m.summary.isEmpty {
                lines.append(m.summary)
                lines.append("")
            }
            if !m.body.isEmpty && m.body != m.summary {
                lines.append(m.body)
                lines.append("")
            }
            lines.append("- Type: \(m.type)")
            if let personaId = m.personaId, !personaId.isEmpty {
                lines.append("- Persona's own memory: \(personaId)")
            }
            if !m.tags.isEmpty {
                lines.append("- Tags: \(m.tags.joined(separator: ", "))")
            }
            lines.append("- Source: \(m.source.isEmpty ? "unknown" : m.source)")
            lines.append("- Created: \(m.createdAt)")
            lines.append("- Updated: \(m.updatedAt)")
            if let superseded = m.supersededBy, !superseded.isEmpty {
                lines.append("- Superseded by: \(superseded)")
            }
            lines.append("- Id: \(m.id)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func parseImport(_ text: String) -> MemoryImportParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return MemoryImportParseResult(entries: [], skipped: 0) }
        guard let json = findJSON(trimmed), (json is [Any] || json is [String: Any]) else {
            return MemoryImportParseResult(
                entries: [],
                skipped: 0,
                error: "Couldn't find JSON in that text. Paste the whole reply, including the code block."
            )
        }
        let list: [Any]?
        if let arr = json as? [Any] {
            list = arr
        } else if let obj = json as? [String: Any], let arr = obj["memories"] as? [Any] {
            list = arr
        } else {
            list = nil
        }
        guard let list else {
            return MemoryImportParseResult(entries: [], skipped: 0, error: "That JSON has no memories list.")
        }
        if list.count > importMax {
            return MemoryImportParseResult(entries: [], skipped: 0, error: "That's \(list.count) memories. Import at most \(importMax) at a time.")
        }

        var entries: [API.MemoryImportEntry] = []
        var skipped = 0
        for item in list {
            guard let dict = item as? [String: Any] else {
                skipped += 1
                continue
            }
            if let superseded = dict["superseded_by"] as? String, !superseded.isEmpty {
                skipped += 1
                continue
            }
            if let personaId = dict["persona_id"] as? String, !personaId.isEmpty {
                skipped += 1
                continue
            }
            let rawSummary = (dict["summary"] as? String ?? "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(rawSummary.prefix(300))
            let rawTitle = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titleSource = rawTitle.isEmpty ? summary : rawTitle
            let title = String(titleSource.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                skipped += 1
                continue
            }
            let tags: [String]
            if let arr = dict["tags"] as? [Any] {
                tags = parseTags(arr.compactMap { $0 as? String }.joined(separator: ","))
            } else if let str = dict["tags"] as? String {
                tags = parseTags(str)
            } else {
                tags = []
            }
            let rawType = (dict["type"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let type = memoryTypes.contains(rawType) ? rawType : "other"
            let body = String(((dict["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))

            entries.append(API.MemoryImportEntry(body: body, summary: summary, tags: tags, title: title, type: type))
        }
        return MemoryImportParseResult(entries: entries, skipped: skipped)
    }

    private static func tryJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findJSON(_ text: String) -> Any? {
        if let whole = tryJSON(text) { return whole }
        if let range = text.range(of: #"```[a-zA-Z]*[ \t]*\r?\n?([\s\S]*?)```"#, options: .regularExpression) {
            let block = String(text[range])
            if let innerStart = block.firstIndex(where: { $0 == "{" || $0 == "[" }),
               let innerEnd = block.lastIndex(where: { $0 == "}" || $0 == "]" }),
               innerEnd >= innerStart {
                if let parsed = tryJSON(String(block[innerStart...innerEnd])) { return parsed }
            }
        }
        if let a = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }),
           end > a {
            return tryJSON(String(text[a...end]))
        }
        return nil
    }
}

// MARK: - Persona helpers (`web/lib/persona-ui.ts`)

public struct PersonaToneInfo: Sendable, Equatable, Identifiable {
    public let value: API.PersonaTone
    public let label: String
    public let hint: String
    public let sample: [String]
    public var id: String { value.rawValue }
}

public struct PersonaContrastWarning: Sendable, Equatable {
    public let ratio: String
    public let suggestion: String
}

public enum PersonaUIHelpers {
    public static let nameMax = 60
    public static let instructionsMax = 2000
    public static let maxPersonas = 40
    public static let avatarMaxBytes = 1_048_576
    public static let avatarHint = "PNG, JPG or WebP · up to 1 MB · shown as a circle."
    public static let builtinColor = "#9b8cff"
    public static let chatBg = "#18181b"
    public static let maxRepos = 10
    public static let repoMaxLength = 500
    public static let credentialsHint = "Don’t put a token in the URL. Store it in Settings → Credentials & API Secrets instead."
    public static let repoFormatHint = "Use https://host/owner/repo, ssh://git@host/owner/repo or git@host:owner/repo."

    public static let presetColors: [String] = [
        "#8b8fff", "#4fd1c5", "#6fcf97", "#f0bf4c", "#f0a04c", "#f48a87", "#f472b6", "#7cbefd",
    ]

    public static let tones: [PersonaToneInfo] = [
        PersonaToneInfo(value: .neutral, label: "Neutral", hint: "Plain and balanced: the Assistant's usual voice.", sample: ["Four runs shipped this week.", "The billing rewrite is the one to watch:", "Acme's pricing move puts August at risk."]),
        PersonaToneInfo(value: .friendly, label: "Friendly", hint: "Warm and encouraging, still to the point.", sample: ["Nice week: four runs shipped!", "One to keep an eye on is the billing rewrite,", "since Acme's pricing move puts August at risk."]),
        PersonaToneInfo(value: .concise, label: "Concise", hint: "Short replies that lead with the answer.", sample: ["4 runs shipped.", "Risk: billing rewrite.", "Acme's pricing puts August at risk."]),
        PersonaToneInfo(value: .formal, label: "Formal", hint: "Polished and professional, no slang.", sample: ["Four runs were completed this week.", "The billing rewrite carries the most risk:", "Acme's pricing change endangers the August date."]),
        PersonaToneInfo(value: .playful, label: "Playful", hint: "Upbeat and light, the odd emoji, still accurate.", sample: ["Woohoo, four runs shipped this week!", "Billing rewrite is the one to watch:", "Acme's pricing move puts August at risk."]),
    ]

    public static func toneLabel(_ tone: API.PersonaTone) -> String {
        tones.first(where: { $0.value == tone })?.label ?? tone.rawValue
    }

    public static func parseHex(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = s.hasPrefix("#") ? s : "#\(s)"
        return PaletteTokens.isOpaqueHex(v) ? v.lowercased() : nil
    }

    public static func unusedPreset(in personas: [API.Persona]) -> String {
        let used = Set(personas.map { $0.color.lowercased() })
        return presetColors.first(where: { !used.contains($0) }) ?? presetColors[0]
    }

    public static func contrastWarning(hex: String, against bg: String = chatBg) -> PersonaContrastWarning? {
        guard PaletteTokens.isOpaqueHex(hex), PaletteTokens.isOpaqueHex(bg) else { return nil }
        let ratio = PaletteTokens.contrast(hex, bg)
        if ratio >= 4.5 { return nil }
        let floored = floor(ratio * 10) / 10
        let ratioLabel = String(format: "%.1f:1", floored)
        return PersonaContrastWarning(ratio: ratioLabel, suggestion: PaletteTokens.readable(hex, against: [bg], minimum: 4.5))
    }

    public static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ch = trimmed.first else { return "?" }
        return String(ch).uppercased()
    }

    public static func sortPersonas(_ personas: [API.Persona]) -> [API.Persona] {
        personas.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault && !b.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    public static func deleteConsequence(chatCount: Int) -> String {
        if chatCount == 0 { return "It has no conversations." }
        if chatCount == 1 { return "Its conversation is kept and continues with the built-in Assistant." }
        return "Its \(chatCount) conversations are kept and continue with the built-in Assistant."
    }

    public enum RepoCheckResult: Equatable {
        case ok(String)
        case error(String)
    }

    public static func checkRepoURL(_ input: String) -> RepoCheckResult {
        let url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return .error("Enter a repository URL.") }
        if url.count > repoMaxLength { return .error("Up to \(repoMaxLength) characters.") }
        if url.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .error(repoFormatHint) }
        if url.range(of: #"^https://[^/]*@"#, options: [.regularExpression, .caseInsensitive]) != nil ||
           url.range(of: #"^ssh://[^/@]*:[^/@]*@"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .error(credentialsHint)
        }
        if url.range(of: #"^https://[^/@\s]+/[^/\s]+/[^\s]+$"#, options: [.regularExpression, .caseInsensitive]) != nil ||
           url.range(of: #"^ssh://(?:[^/@\s]+@)?[^/@\s]+/[^/\s]+/[^\s]+$"#, options: [.regularExpression, .caseInsensitive]) != nil ||
           url.range(of: #"^[A-Za-z0-9._-]+@[^/@\s:]+:[^/\s][^\s]*/[^\s]+$"#, options: .regularExpression) != nil {
            return .ok(url)
        }
        return .error(repoFormatHint)
    }

    public static func addRepo(to repos: [String], input: String) -> Result<[String], RepoAddError> {
        switch checkRepoURL(input) {
        case .error(let msg):
            return .failure(RepoAddError(message: msg))
        case .ok(let url):
            if repos.count >= maxRepos { return .failure(RepoAddError(message: "Up to \(maxRepos) repositories.")) }
            if repos.contains(where: { $0.lowercased() == url.lowercased() }) {
                return .failure(RepoAddError(message: "Already in the list."))
            }
            return .success(repos + [url])
        }
    }

    public struct RepoAddError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func validateAvatarData(_ data: Data, fileName: String, contentType: String? = nil) -> String? {
        if data.isEmpty { return "\(fileName): couldn't read this image." }
        if let contentType, !contentType.isEmpty {
            let allowed = ["image/png", "image/jpeg", "image/webp"]
            if !allowed.contains(contentType.lowercased()) {
                return "\(fileName): type not supported. Use PNG, JPG or WebP."
            }
        }
        if data.count > avatarMaxBytes {
            return "\(fileName) is too large. The limit is 1 MB."
        }
        return nil
    }
}

// MARK: - Provider & API Secrets helpers (`web/lib/settings.ts` & `web/lib/secrets-ui.ts`)

public struct ProviderConnection: Sendable, Equatable, Identifiable {
    public let name: String
    public let label: String
    public let symbolName: String
    public let unlocks: [String]
    public let without: String
    public let required: Bool
    public let signIn: API.SignInProvider?

    public var id: String { name }
}

public enum ProviderConnectionState: Equatable, Sendable {
    case set(API.SecretInfo)
    case projects([String])
    case unset
}

public enum SignInViewState: Equatable, Sendable {
    case starting
    case open(url: String, code: String, pasteBack: Bool)
    case verifying
    case done
    case failed(message: String)
}

public enum ProviderSecretsHelpers {
    public static let connections: [ProviderConnection] = [
        ProviderConnection(
            name: "harness:anthropic",
            label: "Anthropic",
            symbolName: "key",
            unlocks: ["Claude Code"],
            without: "Claude Code runs fail at start.",
            required: true,
            signIn: .claude
        ),
        ProviderConnection(
            name: "harness:openai",
            label: "OpenAI",
            symbolName: "key",
            unlocks: ["Codex"],
            without: "Codex runs fail at start.",
            required: true,
            signIn: .codex
        ),
        ProviderConnection(
            name: "harness:google",
            label: "Google (Antigravity)",
            symbolName: "key",
            unlocks: ["Antigravity"],
            without: "Optional. Antigravity runs and its image generation stay off.",
            required: false,
            signIn: .antigravity
        ),
        ProviderConnection(
            name: "git:ssh",
            label: "GitHub SSH key",
            symbolName: "key",
            unlocks: ["Clone & push over SSH"],
            without: "Runs can’t clone or push space repositories.",
            required: false,
            signIn: nil
        ),
        ProviderConnection(
            name: "git:pat",
            label: "GitHub token",
            symbolName: "chevron.left.forwardslash.chevron.right",
            unlocks: ["gh pull requests"],
            without: "Optional with SSH. Without it agents push but can’t open PRs.",
            required: false,
            signIn: .github
        ),
    ]

    private static let connectionNames = Set(connections.map(\.name))

    public static let signInSteps: [API.SignInProvider: String] = [
        .claude: "Sign in to Claude, then paste the code it shows below.",
        .codex: "Sign in to ChatGPT and enter this code.",
        .antigravity: "Sign in with Google, then paste the authorization code or callback URL below.",
        .github: "Sign in to GitHub and enter this code. Vesper stores the token as git:pat.",
    ]

    public static func connectionState(_ secrets: [API.SecretInfo], name: String) -> ProviderConnectionState {
        let own = secrets.filter { $0.name == name }
        if let ws = own.first(where: { $0.project == nil }) {
            return .set(ws)
        }
        let projectNames = own.compactMap { $0.project?.name }
        if !projectNames.isEmpty {
            return .projects(projectNames)
        }
        return .unset
    }

    public static func missingConnections(_ secrets: [API.SecretInfo]) -> [ProviderConnection] {
        connections.filter { c in
            guard c.required else { return false }
            if case .set = connectionState(secrets, name: c.name) { return false }
            return true
        }
    }

    public static func otherSecrets(_ secrets: [API.SecretInfo]) -> [API.SecretInfo] {
        secrets.filter { !connectionNames.contains($0.name) || $0.project != nil }
    }

    public static func savedMessage(name: String) -> String {
        guard let c = connections.first(where: { $0.name == name }) else {
            return "\(name) saved."
        }
        let verb = c.unlocks.count > 1 ? "are" : "is"
        return "\(name) saved. \(c.unlocks.joined(separator: " and ")) \(verb) now available."
    }

    public static func signInView(_ s: API.SignIn) -> SignInViewState {
        switch s.status {
        case .done:
            return .done
        case .failed:
            return .failed(message: s.error.isEmpty ? "The sign-in didn’t finish." : s.error)
        case .cancelled:
            return .failed(message: "The sign-in was cancelled.")
        case .verifying:
            return .verifying
        default:
            break
        }
        if s.url.isEmpty { return .starting }
        if s.status == .running && s.userCode.isEmpty && !s.needsCode { return .verifying }
        return .open(url: s.url, code: s.userCode, pasteBack: s.needsCode)
    }
}

public enum SettingsBadgeTone: Sendable, Equatable {
    case done, human, blocked, neutral
}

public struct APISecretOAuthPreset: Sendable, Equatable, Identifiable {
    public let value: String
    public let label: String
    public let authorizeUrl: String
    public let tokenUrl: String
    public let hosts: [String]
    public let scopesHint: String
    public let scopesRequired: Bool
    public var id: String { value }
}

public enum APISecretsHelpers {
    public static let placements: [(value: API.ApiSecretPlacement, label: String)] = [
        (.bearer, "Bearer token"),
        (.header, "Custom header"),
        (.query, "Query param"),
        (.basic, "Basic auth"),
    ]

    public static let policies: [(value: API.ApiSecretPolicy, label: String)] = [
        (.allow, "Allow"),
        (.ask, "Ask"),
        (.off, "Off"),
    ]

    public static let readMethods = "GET, HEAD"
    public static let writeMethods = "POST, PUT, PATCH, DELETE"

    public static let oauthPresets: [APISecretOAuthPreset] = [
        APISecretOAuthPreset(
            value: "google",
            label: "Google",
            authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenUrl: "https://oauth2.googleapis.com/token",
            hosts: ["www.googleapis.com"],
            scopesHint: "https://www.googleapis.com/auth/drive.readonly",
            scopesRequired: true
        ),
        APISecretOAuthPreset(
            value: "custom",
            label: "Other provider",
            authorizeUrl: "",
            tokenUrl: "",
            hosts: [],
            scopesHint: "read write",
            scopesRequired: false
        ),
    ]

    public static func sentAs(placement: API.ApiSecretPlacement, key: String, handle: String) -> String {
        let ph = "‹\(handle.isEmpty ? "secret" : handle)›"
        switch placement {
        case .bearer: return "Authorization: Bearer \(ph)"
        case .header: return "\(key.isEmpty ? "X-Api-Key" : key): \(ph)"
        case .query: return "?\(key.isEmpty ? "api_key" : key)=\(ph)"
        case .basic: return "Authorization: Basic \(ph)"
        default: return "\(placement.rawValue): \(ph)"
        }
    }

    public static func placementLabel(placement: API.ApiSecretPlacement, key: String) -> String {
        switch placement {
        case .bearer: return "Authorization: Bearer"
        case .header: return "\(key) header"
        case .query: return "\(key) query parameter"
        case .basic: return "Basic auth"
        default: return placement.rawValue
        }
    }

    public static func handleFor(name: String) -> String {
        var h = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"^-+|-+$"#, with: "", options: .regularExpression)
        if let first = h.first, first.isNumber {
            h = "s-\(h)"
        }
        if h.count > 36 {
            h = String(h.prefix(36)).replacingOccurrences(of: #"-+$"#, with: "", options: .regularExpression)
        }
        return h
    }

    public static func hostOf(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = h.range(of: "://") {
            h = String(h[scheme.upperBound...])
        }
        if let cut = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            h = String(h[..<cut])
        }
        if let at = h.lastIndex(of: "@") {
            h = String(h[h.index(after: at)...])
        }
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return nil }
            h = String(h[h.index(after: h.startIndex)..<close])
        } else {
            let colons = h.filter { $0 == ":" }.count
            if colons == 1, let colon = h.firstIndex(of: ":") {
                h = String(h[..<colon])
            }
        }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        if h.range(of: "^(\(label)\\.)*\(label)$", options: .regularExpression) != nil ||
           h.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil ||
           h.contains(":") {
            return h
        }
        return nil
    }

    public static func jwtExpiry(_ value: String) -> Date? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let mod = b64.count % 4
        if mod != 0 { b64 += String(repeating: "=", count: 4 - mod) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expNum = obj["exp"] as? NSNumber,
              CFGetTypeID(expNum) != CFBooleanGetTypeID(),
              expNum.doubleValue > 0
        else { return nil }
        return Date(timeIntervalSince1970: expNum.doubleValue)
    }

    public static func expiryPill(_ expiresAt: String?, now: Date = Date()) -> (label: String, tone: SettingsBadgeTone)? {
        guard let expiresAt, let date = parseISODate(expiresAt) else { return nil }
        let left = date.timeIntervalSince(now)
        let day: TimeInterval = 86_400
        if left <= 0 { return ("Expired", .blocked) }
        if left < day {
            let hours = max(1, Int((left / 3600).rounded()))
            return ("\(hours)h left", .human)
        }
        if left < 14 * day {
            let days = Int((left / day).rounded())
            return ("\(days)d left", .human)
        }
        return ("Active", .done)
    }

    public static func expiryText(_ expiresAt: Date?, now: Date = Date()) -> String {
        guard let expiresAt else { return "No expiry found" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let verb = expiresAt <= now ? "Expired" : "Expires"
        return "\(verb) \(formatter.string(from: expiresAt))"
    }

    public static func splitScopes(_ raw: String) -> [String] {
        var out: [String] = []
        for piece in raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !out.contains(trimmed) {
                out.append(trimmed)
            }
        }
        return out
    }

    public static func oauthStatus(_ oauth: API.ApiSecretOAuth?) -> (label: String, tone: SettingsBadgeTone, action: String)? {
        guard let oauth else { return nil }
        if oauth.signedInAt == nil || oauth.signedInAt?.isEmpty == true {
            return ("Not signed in", .human, "Sign in")
        }
        if !oauth.error.isEmpty {
            return ("Sign in again", .blocked, "Sign in again")
        }
        return ("Signed in", .done, "Sign in again")
    }

    static func parseISODate(_ raw: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }
}

// MARK: - Workspace Setup & Image Engine helpers (`web/lib/setup.ts` & `web/lib/image-engine.ts`)

public struct SetupChecklistItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let href: String
    public let linkLabel: String
    public let done: Bool
    public let detail: String
}

public struct ImageEngineChoice: Sendable, Equatable, Identifiable {
    public let value: API.ImageEngineSettings.Engine
    public let label: String
    public let detail: String
    public var id: String { value.rawValue }
}

public enum WorkspaceSetupHelpers {
    public static func imageEngineChoices(_ options: [API.ImageEngineSettings.OptionsItem]) -> [ImageEngineChoice] {
        let connected = options.filter(\.available)
        let autoDetail = connected.isEmpty
            ? "No image engine is connected yet. Connect Codex, Antigravity, or Gemini API first."
            : "Use the first connected: \(connected.map(\.label).joined(separator: ", then "))."
        var out = [ImageEngineChoice(value: .auto, label: "Auto", detail: autoDetail)]
        for opt in options {
            let detail: String
            if opt.available {
                if let model = opt.model, !model.isEmpty {
                    detail = "Connected · \(model)"
                } else {
                    detail = "Connected"
                }
            } else if let reason = opt.reason, !reason.isEmpty {
                detail = "Not connected: \(reason)"
            } else {
                detail = "Not connected"
            }
            out.append(ImageEngineChoice(
                value: API.ImageEngineSettings.Engine(rawValue: opt.engine.rawValue),
                label: opt.label,
                detail: detail
            ))
        }
        return out
    }

    public static func activeImageEngineSummary(_ settings: API.ImageEngineSettings) -> String {
        if settings.engine == .auto {
            if let first = settings.options.first(where: \.available) {
                return "Using Auto (\(first.label))"
            }
            return "Not configured"
        }
        if let chosen = settings.options.first(where: { $0.engine.rawValue == settings.engine.rawValue }) {
            return chosen.available ? "Using \(chosen.label)" : "\(chosen.label) (not configured)"
        }
        return "Not configured"
    }

    public static func harnessHealth(_ groups: [API.ChatHarnessModels]) -> (ready: Bool, checking: Bool, reasons: [String]) {
        let down = groups.filter { !$0.available }
        let reasons = down.map { "\($0.label): \($0.unavailableReason ?? "not configured")" }
        return (
            ready: groups.contains(where: \.available),
            checking: groups.contains(where: { $0.checking == true }),
            reasons: reasons
        )
    }

    public static func checklist(
        reposCount: Int,
        firstWorkSpaceId: String?,
        harnessSecretSet: Bool,
        harnessModels: [API.ChatHarnessModels],
        runner: API.RunnerStatus?
    ) -> [SetupChecklistItem] {
        let health = harnessHealth(harnessModels)
        let secretDone = harnessSecretSet || health.ready
        let onlineRunners = runner?.runners ?? []
        let backends = Array(NSOrderedSet(array: onlineRunners.map(\.backend.rawValue))).compactMap { $0 as? String }.joined(separator: ", ")
        let slots = onlineRunners.reduce(0) { $0 + $1.maxConcurrent }
        let runnerOnline = runner?.online ?? false

        return [
            SetupChecklistItem(
                id: "repo",
                label: "Connect a repository to a space",
                href: firstWorkSpaceId.map { "/spaces/\($0)" } ?? "/spaces/new?work=1",
                linkLabel: "Spaces",
                done: reposCount > 0,
                detail: reposCount > 0
                    ? "\(reposCount) \(reposCount == 1 ? "space has" : "spaces have") a repository"
                    : "Without one, coding chats start in an empty workspace and can’t push."
            ),
            SetupChecklistItem(
                id: "secret",
                label: "Add at least one provider credential",
                href: "/settings#secrets",
                linkLabel: "Provider credentials",
                done: secretDone,
                detail: secretDone ? "A harness can run agents" : (health.reasons.isEmpty ? "No harness is available." : health.reasons.joined(separator: " · "))
            ),
            SetupChecklistItem(
                id: "runner",
                label: "Check the runner backend",
                href: "/settings#runners",
                linkLabel: "Runner backends",
                done: runnerOnline,
                detail: runnerOnline
                    ? "\(onlineRunners.count) \(onlineRunners.count == 1 ? "runner" : "runners") online · \(backends) · \(slots) \(slots == 1 ? "slot" : "slots")"
                    : (runner?.starting == true ? "Runner is starting…" : "No runner online. Active chats wait until a runner connects.")
            ),
        ]
    }
}

// MARK: - Dev Workspace helpers (`web/lib/dev-workspace.ts`)

public enum DevWorkspaceHelpers {
    public static func statusTone(_ state: API.DevWorkspace.State) -> SettingsBadgeTone {
        switch state {
        case .ready: return .done
        case .starting: return .human
        case .error: return .blocked
        default: return .neutral
        }
    }

    public static func statusLabel(enabled: Bool, state: API.DevWorkspace.State, step: String?) -> String {
        if !enabled && state == .stopped { return "Stopped (not configured)" }
        if state == .starting {
            if let step, !step.isEmpty { return "Starting · \(step)" }
            return "Starting…"
        }
        if state == .ready { return "Ready" }
        if state == .error { return "Error" }
        return "Stopped"
    }

    public static func filterRepos(_ repos: [API.DevWorkspaceRepo], query: String) -> [API.DevWorkspaceRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return repos }
        return repos.filter {
            $0.repoUrl.lowercased().contains(q) || $0.directory.lowercased().contains(q)
        }
    }
}
