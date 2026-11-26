import Foundation

// MARK: - Profile Management Logic

public enum BrowserProfileLogic {
    public static let presetIcons: [String] = [
        "person.crop.circle",
        "briefcase.fill",
        "hammer.fill",
        "sparkles",
        "book.closed.fill",
        "gamecontroller.fill",
        "globe.americas.fill",
        "terminal.fill",
    ]

    /// Creates a new profile with a guaranteed-unique `dataStoreID` separate from all existing
    /// profiles and from the default Personal store.
    public static func makeProfile(
        name: String,
        icon: String = "briefcase.fill",
        color: BrowserProfileColor = .purple,
        existing: [BrowserProfile]
    ) -> BrowserProfile {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleaned.isEmpty ? "Profile \(existing.count + 1)" : cleaned
        let usedStores = Set(existing.map(\.dataStoreID)).union([BrowserProfile.defaultDataStoreID])
        var storeID = UUID()
        while usedStores.contains(storeID) {
            storeID = UUID()
        }
        return BrowserProfile(
            name: finalName,
            icon: icon.isEmpty ? "person.crop.circle" : icon,
            color: color,
            dataStoreID: storeID
        )
    }

    public static func canDeleteProfile(id: UUID, in profiles: [BrowserProfile]) -> Bool {
        profiles.count > 1 && profiles.contains(where: { $0.id == id })
    }
}

// MARK: - Tab Group, Reordering & Split View Logic

public struct BrowserSplitState: Sendable, Equatable {
    public var primaryTabId: UUID?
    public var secondaryTabId: UUID?
    public var ratio: Double

    public init(primaryTabId: UUID?, secondaryTabId: UUID?, ratio: Double = 0.5) {
        self.primaryTabId = primaryTabId
        self.secondaryTabId = secondaryTabId
        self.ratio = min(0.8, max(0.2, ratio))
    }

    public var isSplit: Bool {
        primaryTabId != nil && secondaryTabId != nil && primaryTabId != secondaryTabId
    }
}

public enum BrowserTabGroupLogic {
    /// Moves `sourceID` immediately before `targetID` in the array, returning the reordered array.
    public static func move<T: Identifiable>(_ sourceID: T.ID, before targetID: T.ID, in items: [T]) -> [T] {
        guard sourceID != targetID,
              let from = items.firstIndex(where: { $0.id == sourceID }),
              let to = items.firstIndex(where: { $0.id == targetID })
        else { return items }
        var copy = items
        let moved = copy.remove(at: from)
        let insertIndex = from < to ? to - 1 : to
        copy.insert(moved, at: insertIndex)
        return copy
    }

    /// Computes sidebar display order for tabs: pinned tabs first, then grouped tabs (in group order),
    /// then ungrouped regular tabs. Keeps `⌘⌃1`–`⌘⌃9` visually aligned with the sidebar.
    public static func displayOrder<T>(
        tabs: [T],
        groups: [BrowserTabGroup],
        isPinned: (T) -> Bool,
        groupId: (T) -> UUID?
    ) -> [T] {
        let pinned = tabs.filter(isPinned)
        let regular = tabs.filter { !isPinned($0) }
        var result: [T] = pinned
        let validGroupIDs = Set(groups.map(\.id))
        for group in groups {
            result.append(contentsOf: regular.filter { groupId($0) == group.id })
        }
        result.append(contentsOf: regular.filter {
            guard let gid = groupId($0) else { return true }
            return !validGroupIDs.contains(gid)
        })
        return result
    }

    /// Reconciles split view state after a tab is closed.
    /// - If the secondary tab closes, split view ends and primary stays active.
    /// - If the primary tab closes while split, the secondary tab is promoted to primary and split ends.
    public static func reconcileSplitAfterClose(
        closedTabId: UUID,
        state: BrowserSplitState,
        remainingTabIds: [UUID]
    ) -> BrowserSplitState {
        let remaining = Set(remainingTabIds)
        var next = state
        if next.secondaryTabId == closedTabId {
            next.secondaryTabId = nil
        } else if next.primaryTabId == closedTabId {
            if let sec = next.secondaryTabId, remaining.contains(sec) {
                next.primaryTabId = sec
                next.secondaryTabId = nil
            } else {
                next.primaryTabId = remainingTabIds.first
                next.secondaryTabId = nil
            }
        }
        if let p = next.primaryTabId, !remaining.contains(p) {
            next.primaryTabId = remainingTabIds.first
        }
        if let s = next.secondaryTabId, !remaining.contains(s) || s == next.primaryTabId {
            next.secondaryTabId = nil
        }
        return next
    }

    /// Opens `tabId` as the secondary split pane beside `currentPrimary`.
    public static func openInSplit(tabId: UUID, current: BrowserSplitState) -> BrowserSplitState {
        guard let primary = current.primaryTabId, primary != tabId else {
            return current
        }
        return BrowserSplitState(primaryTabId: primary, secondaryTabId: tabId, ratio: current.ratio)
    }

    /// Swaps the left (primary) and right (secondary) split panes.
    public static func swapPanes(_ current: BrowserSplitState) -> BrowserSplitState {
        guard current.isSplit else { return current }
        return BrowserSplitState(
            primaryTabId: current.secondaryTabId,
            secondaryTabId: current.primaryTabId,
            ratio: 1.0 - current.ratio
        )
    }
}

// MARK: - AutoFill & Credential Matching Logic

public struct BrowserCredential: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var host: String
    public var username: String
    public var password: String
    public var label: String
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        host: String,
        username: String,
        password: String,
        label: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.username = username
        self.password = password
        self.label = label
        self.updatedAt = updatedAt
    }
}

public struct BrowserPendingCredentialSave: Sendable, Equatable {
    public var host: String
    public var username: String
    public var password: String
    public var existingCredentialId: String?

    public init(host: String, username: String, password: String, existingCredentialId: String? = nil) {
        self.host = host
        self.username = username
        self.password = password
        self.existingCredentialId = existingCredentialId
    }

    public var isUpdate: Bool { existingCredentialId != nil }
}

public enum BrowserAutofillLogic {
    private static let multiPartTLDs: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk",
        "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "or.jp",
        "co.nz", "co.kr", "com.br", "com.mx", "com.sg", "com.hk",
    ]

    /// AutoFill only activates on HTTPS origins or loopback development servers (localhost / 127.0.0.1 / ::1)
    /// so credentials are never injected into unencrypted remote HTTP pages.
    public static func isSecureAutofillOrigin(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty
        else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return rawHost == "localhost" || rawHost == "127.0.0.1" || rawHost == "::1" || rawHost == "[::1]"
        }
        return false
    }

    /// Strict autofill guard: HTTPS pages must also report `hasOnlySecureContent == true` so
    /// mixed-content pages cannot receive credentials; loopback HTTP dev servers remain allowed.
    public static func canAutofill(urlString: String, hasOnlySecureContent: Bool) -> Bool {
        guard isSecureAutofillOrigin(urlString),
              let scheme = URL(string: urlString)?.scheme?.lowercased()
        else { return false }
        if scheme == "https" {
            return hasOnlySecureContent
        }
        return true
    }

    /// Parses standard Apple Passwords / Safari CSV exports (`Title,URL,Username,Password,Notes,OTPAuth`).
    public static func parseApplePasswordsCSV(_ csv: String) -> [BrowserCredential] {
        let rows = parseCSVRows(csv)
        guard let header = rows.first else { return [] }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let titleIdx = normalizedHeader.firstIndex(of: "title")
        let urlIdx = normalizedHeader.firstIndex(of: "url") ?? normalizedHeader.firstIndex(of: "website")
        let userIdx = normalizedHeader.firstIndex(of: "username") ?? normalizedHeader.firstIndex(of: "login")
        let passIdx = normalizedHeader.firstIndex(of: "password")
        guard let urlIdx, let userIdx, let passIdx else { return [] }

        var out: [BrowserCredential] = []
        var seen = Set<String>()
        for row in rows.dropFirst() {
            guard row.count > max(urlIdx, max(userIdx, passIdx)) else { continue }
            let rawURL = row[urlIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let username = row[userIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let password = row[passIdx]
            guard !rawURL.isEmpty, !username.isEmpty, !password.isEmpty,
                  let host = BrowserPageGuard.normalizeHost(rawURL)
            else { continue }
            let dedupeKey = "\(host)|\(username.lowercased())"
            guard seen.insert(dedupeKey).inserted else { continue }
            let title = titleIdx.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            out.append(BrowserCredential(
                host: host,
                username: username,
                password: password,
                label: (title?.isEmpty == false) ? title! : host
            ))
        }
        return out
    }

    private static func parseCSVRows(_ input: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    row.append(field)
                    field = ""
                } else if ch == "\r" {
                    if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field)
                    field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                } else if ch == "\n" {
                    row.append(field)
                    field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                } else {
                    field.append(ch)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        }
        return rows
    }

    /// Computes a conservative registrable domain (eTLD+1) for matching subdomains like
    /// `accounts.github.com` with `github.com`.
    public static func domainGroup(for rawHost: String) -> String {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return rawHost.lowercased() }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        // Keep IP addresses intact.
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            return host
        }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3, multiPartTLDs.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Returns credentials matching `urlString`, ranking exact-host matches ahead of sibling subdomains.
    public static func matchingCredentials(
        for urlString: String,
        in credentials: [BrowserCredential]
    ) -> [BrowserCredential] {
        guard isSecureAutofillOrigin(urlString),
              let pageHost = BrowserPageGuard.normalizeHost(urlString)
        else { return [] }

        let pageGroup = domainGroup(for: pageHost)
        var exact: [BrowserCredential] = []
        var related: [BrowserCredential] = []

        for cred in credentials {
            guard let credHost = BrowserPageGuard.normalizeHost(cred.host) else { continue }
            if credHost == pageHost {
                exact.append(cred)
            } else if domainGroup(for: credHost) == pageGroup {
                related.append(cred)
            }
        }
        exact.sort { $0.updatedAt > $1.updatedAt }
        related.sort { $0.updatedAt > $1.updatedAt }
        return exact + related
    }

    /// Evaluates whether the browser should prompt the person to save or update a submitted login.
    public static func evaluateSavePrompt(
        urlString: String,
        username: String,
        password: String,
        isPrivate: Bool,
        autofillEnabled: Bool,
        neverSaveHosts: [String],
        existing: [BrowserCredential]
    ) -> BrowserPendingCredentialSave? {
        guard autofillEnabled, !isPrivate, isSecureAutofillOrigin(urlString),
              let host = BrowserPageGuard.normalizeHost(urlString)
        else { return nil }

        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else { return nil }
        if neverSaveHosts.contains(where: { BrowserPageGuard.isCovered(host, by: $0) }) {
            return nil
        }

        if let match = existing.first(where: {
            BrowserPageGuard.normalizeHost($0.host) == host && $0.username.caseInsensitiveCompare(cleanUser) == .orderedSame
        }) {
            // Password unchanged: no prompt needed.
            if match.password == password { return nil }
            return BrowserPendingCredentialSave(
                host: host,
                username: cleanUser,
                password: password,
                existingCredentialId: match.id
            )
        }

        return BrowserPendingCredentialSave(
            host: host,
            username: cleanUser,
            password: password,
            existingCredentialId: nil
        )
    }

    /// Generates a cryptographically strong random password guaranteeing at least one character
    /// from each enabled class (uppercase, lowercase, digits, optional symbols).
    public static func generateStrongPassword(length: Int = 20, includeSymbols: Bool = true) -> String {
        let clamped = min(64, max(12, length))
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let lower = Array("abcdefghijkmnopqrstuvwxyz")
        let digits = Array("23456789")
        let symbols = Array("!@#$%^&*-_=+")

        var rng = SystemRandomNumberGenerator()
        var classes: [[Character]] = [upper, lower, digits]
        if includeSymbols { classes.append(symbols) }
        let allChars = classes.flatMap { $0 }

        var chars: [Character] = classes.map { $0.randomElement(using: &rng)! }
        while chars.count < clamped {
            chars.append(allChars.randomElement(using: &rng)!)
        }
        chars.shuffle(using: &rng)
        return String(chars)
    }
}

// MARK: - WebExtension Manifest Validation

public struct BrowserExtensionManifestSummary: Sendable, Equatable {
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var description: String
    public var permissions: [String]
    public var hostPermissions: [String]

    public init(
        name: String,
        version: String,
        manifestVersion: Int,
        description: String = "",
        permissions: [String] = [],
        hostPermissions: [String] = []
    ) {
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.description = description
        self.permissions = permissions
        self.hostPermissions = hostPermissions
    }
}

public enum BrowserExtensionValidationError: Error, LocalizedError, Equatable, Sendable {
    case missingManifest
    case invalidJSON
    case missingName
    case unsupportedManifestVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "No manifest.json found in the selected extension folder."
        case .invalidJSON:
            return "The extension's manifest.json isn't valid JSON."
        case .missingName:
            return "The extension's manifest.json is missing a name."
        case .unsupportedManifestVersion(let v):
            return "Manifest version \(v) isn't supported (expected 2 or 3)."
        }
    }
}

public enum BrowserExtensionLogic {
    /// Parses and validates a WebExtension `manifest.json` payload.
    public static func parseManifest(data: Data) throws -> BrowserExtensionManifestSummary {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserExtensionValidationError.invalidJSON
        }
        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else {
            throw BrowserExtensionValidationError.missingName
        }
        let mv: Int
        if let intMV = obj["manifest_version"] as? Int {
            mv = intMV
        } else if let dblMV = obj["manifest_version"] as? Double {
            mv = Int(dblMV)
        } else {
            throw BrowserExtensionValidationError.unsupportedManifestVersion(0)
        }
        guard mv == 2 || mv == 3 else {
            throw BrowserExtensionValidationError.unsupportedManifestVersion(mv)
        }
        let version = (obj["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1.0"
        let desc = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let perms = (obj["permissions"] as? [String]) ?? []
        let hostPerms = (obj["host_permissions"] as? [String]) ?? []
        return BrowserExtensionManifestSummary(
            name: rawName,
            version: version,
            manifestVersion: mv,
            description: desc,
            permissions: perms,
            hostPermissions: hostPerms
        )
    }

    /// Validates an unpacked extension directory containing `manifest.json`.
    public static func validateUnpackedDirectory(_ dir: URL) throws -> BrowserExtensionManifestSummary {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw BrowserExtensionValidationError.missingManifest
        }
        return try parseManifest(data: data)
    }
}
