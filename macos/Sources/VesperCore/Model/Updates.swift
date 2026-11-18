import Foundation

// Port of desktop/src/updates.ts. The app is signed ad hoc / self-signed and not notarised, so the
// supported path is: check a release feed (opt-in), tell the person a newer build exists, and open
// its download page. The data directory lives outside the bundle, so it survives replacing the app.

public struct ParsedVersion: Sendable, Equatable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var pre: String
}

public struct UpdateInfo: Sendable, Equatable {
    public var version: String
    /// The release page to open; always https on github.com or the feed's own host.
    public var url: String
    public var name: String
}

public enum VersionTransition: Equatable, Sendable { case firstRun, same, upgrade, downgrade }

public enum Updates {
    public static func parseVersion(_ raw: String?) -> ParsedVersion? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-([0-9A-Za-z.-]{1,64}))?(?:\+[0-9A-Za-z.-]+)?\z"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))
        else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: t).map { String(t[$0]) }
        }
        return ParsedVersion(major: Int(group(1)!)!, minor: Int(group(2)!)!, patch: Int(group(3)!)!, pre: group(4) ?? "")
    }

    /// Semver-style compare; a pre-release sorts before its release. Unparseable versions compare equal.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        guard let pa = parseVersion(a), let pb = parseVersion(b) else { return 0 }
        for (x, y) in [(pa.major, pb.major), (pa.minor, pb.minor), (pa.patch, pb.patch)] where x != y { return x < y ? -1 : 1 }
        if pa.pre == pb.pre { return 0 }
        if pa.pre.isEmpty { return 1 }
        if pb.pre.isEmpty { return -1 }
        // JavaScript compares strings by UTF-16 code units.
        return pa.pre.utf16.lexicographicallyPrecedes(pb.pre.utf16) ? -1 : 1
    }

    /// Reads a GitHub "latest release" response. Drafts and pre-releases are ignored; the page URL
    /// must be https on github.com or on the feed's host.
    public static func pickUpdate(currentVersion: String, feedURL: String, release: Any?) -> UpdateInfo? {
        guard let r = release as? [String: Any], (r["draft"] as? Bool) != true, (r["prerelease"] as? Bool) != true else { return nil }
        let tag = r["tag_name"] as? String ?? ""
        guard let version = parseVersion(tag), compareVersions(tag, currentVersion) > 0 else { return nil }
        let page = r["html_url"] as? String ?? ""
        guard let pageURL = URL(string: page), let pageHost = pageURL.host?.lowercased(),
              let feedHost = URL(string: feedURL)?.host?.lowercased()
        else { return nil }
        let hostOK = pageHost == "github.com" || pageHost == feedHost
        guard pageURL.scheme?.lowercased() == "https", hostOK else { return nil }
        let rawName = (r["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? tag : String(rawName.prefix(100))
        return UpdateInfo(
            version: "\(version.major).\(version.minor).\(version.patch)\(version.pre.isEmpty ? "" : "-\(version.pre)")",
            url: pageURL.absoluteString,
            name: name
        )
    }

    /// Compares this build with the one that last opened the data directory. A downgrade can leave
    /// the database at a newer schema than this build knows; the app warns before starting the stack.
    public static func versionTransition(lastVersion: String?, currentVersion: String) -> VersionTransition {
        guard let last = lastVersion, parseVersion(last) != nil else { return .firstRun }
        let c = compareVersions(currentVersion, last)
        return c == 0 ? .same : c > 0 ? .upgrade : .downgrade
    }

    /// Checks at most once a day. Times are milliseconds since the epoch.
    public static func isCheckDue(lastCheckedAt: Double?, now: Double, intervalMs: Double = 24 * 60 * 60 * 1000) -> Bool {
        guard let last = lastCheckedAt, last.isFinite, last != 0 else { return true }
        return now - last >= intervalMs || last > now
    }

    /// The GitHub repository that publishes Vesper releases.
    public static let releaseRepo = "liamphmurphy/vesper"

    /// The download URL of a file attached to this version's release, e.g. agent-base.erofs for
    /// v0.2.0. Nil for a version that isn't plain semver (a dev build) or a name that isn't a plain file name.
    public static func releaseAssetUrl(version: String, assetName: String, repo: String = releaseRepo) -> String? {
        guard parseVersion(version) != nil,
              assetName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z"#, options: .regularExpression) != nil,
              repo.range(of: #"^[\w.-]+/[\w.-]+\z"#, options: .regularExpression) != nil
        else { return nil }
        let tag = version.hasPrefix("v") ? version : "v\(version)"
        return "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"
    }
}
