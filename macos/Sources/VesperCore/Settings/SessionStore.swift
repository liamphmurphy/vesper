import Foundation

// session.json: the tabs and window bounds restored on launch (desktop/src/config.ts
// loadSession/saveSession). Same file the Electron app wrote, so tabs survive the switch.

public struct WindowBounds: Sendable, Equatable, Codable {
    public var x: Int?
    public var y: Int?
    public var width: Int
    public var height: Int
    public var isMaximized: Bool?

    public init(x: Int? = nil, y: Int? = nil, width: Int, height: Int, isMaximized: Bool? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.isMaximized = isMaximized
    }
}

public struct SessionState: Sendable, Equatable, Codable {
    public var tabs: [String]
    public var activeIndex: Int
    public var bounds: WindowBounds?

    public init(tabs: [String] = [], activeIndex: Int = 0, bounds: WindowBounds? = nil) {
        self.tabs = tabs; self.activeIndex = activeIndex; self.bounds = bounds
    }

    public static let empty = SessionState()
}

public enum SessionStore {
    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("session.json")
    }

    /// Never throws: anything unreadable or malformed yields the default (or drops the bad part).
    public static func load(from url: URL) -> SessionState {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .empty }

        var tabs: [String] = []
        if let raw = obj["tabs"] as? [Any] {
            tabs = raw.compactMap { item in
                guard let s = item as? String, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", u.host != nil else { return nil }
                return s
            }
        }

        var activeIndex = 0
        if let n = obj["activeIndex"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(), n.intValue >= 0 {
            activeIndex = min(n.intValue, max(0, tabs.count - 1))
        }

        var bounds: WindowBounds?
        if let b = obj["bounds"] as? [String: Any], let w = number(b["width"]), w >= 400, let h = number(b["height"]), h >= 300 {
            bounds = WindowBounds(
                x: number(b["x"]).map { Int($0.rounded()) }, y: number(b["y"]).map { Int($0.rounded()) },
                width: Int(w.rounded()), height: Int(h.rounded()), isMaximized: b["isMaximized"] as? Bool)
        }
        return SessionState(tabs: tabs, activeIndex: activeIndex, bounds: bounds)
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// Atomic write (temp file then rename), creating the directory.
    public static func save(_ state: SessionState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(state)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}
