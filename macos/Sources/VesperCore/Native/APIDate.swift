import Foundation

/// The API's timestamps: RFC 3339, with or without fractional seconds (Go writes both).
public enum APIDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    /// Nil for an empty or unparsable string. Go may write nanoseconds; ISO8601DateFormatter takes
    /// at most milliseconds, so longer fractions are trimmed first.
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let trimmed = trimFraction(string)
        return lock.withLock { fractional.date(from: trimmed) ?? whole.date(from: trimmed) }
    }

    /// Seconds since 1970, or 0 for an unparsable time (sorts first, like the web's Date.parse NaN guard).
    public static func epoch(_ string: String?) -> TimeInterval {
        parse(string)?.timeIntervalSince1970 ?? 0
    }

    static func trimFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        let digits = s.distance(from: s.index(after: dot), to: end)
        guard digits > 3 else { return s }
        return String(s[..<s.index(dot, offsetBy: 4)]) + s[end...]
    }

    /// "42m", "1h 5m", "3d": how long since `iso` (web lib/inbox.ts `waited`).
    public static func waited(_ iso: String, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince1970 - epoch(iso)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 != 0 ? "\(hours)h \(minutes % 60)m" : "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// An hour or more (web `longWait`): shown in amber.
    public static func longWait(_ iso: String, now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 - epoch(iso) >= 3600
    }

    /// "40s", "3m", "1h 12m": from `iso` to `end` or now (web lib/format.ts `duration`).
    public static func duration(since iso: String, until end: String? = nil, now: Date = Date()) -> String {
        let to = end.map(epoch) ?? now.timeIntervalSince1970
        let seconds = max(0, Int(to - epoch(iso)))
        let minutes = seconds / 60
        if minutes < 1 { return "\(seconds)s" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
