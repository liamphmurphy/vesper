import Foundation

/// Pure calendar grid, ISO day formatting, and inbox capture filing helpers for Knowledge's Calendar & Inbox inspector.
public enum KnowledgeCalendarLogic {
    public static let dayHeaders = ["M", "T", "W", "T", "F", "S", "S"]

    /// Monday-first month grid (`[[Int?]]`) for a 1-indexed month (`1...12`), matching `web/lib/knowledge.ts`.
    public static func monthGrid(year: Int, month: Int) -> [[Int?]] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let first = cal.date(from: comps),
              let dayRange = cal.range(of: .day, in: .month, for: first) else {
            return []
        }
        // Gregorian weekday: 1 = Sunday, 2 = Monday, ..., 7 = Saturday -> Monday = 0 ... Sunday = 6
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday + 5) % 7
        var cells: [Int?] = Array(repeating: nil, count: lead) + dayRange.map { Optional($0) }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        var weeks: [[Int?]] = []
        var idx = 0
        while idx < cells.count {
            weeks.append(Array(cells[idx..<min(idx + 7, cells.count)]))
            idx += 7
        }
        return weeks
    }

    public static func isoDay(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func isoDay(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return isoDay(year: comps.year ?? 1970, month: comps.month ?? 1, day: comps.day ?? 1)
    }

    /// Shifts a 1-indexed `(year, month)` pair by `delta` months (positive or negative).
    public static func shiftedMonth(year: Int, month: Int, delta: Int) -> (year: Int, month: Int) {
        let total = (year * 12 + (month - 1)) + delta
        let nextYear = total >= 0 ? total / 12 : ((total - 11) / 12)
        let nextMonth = ((total % 12) + 12) % 12 + 1
        return (nextYear, nextMonth)
    }

    public static func monthTitle(year: Int, month: Int, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = cal.date(from: comps) else { return "\(year)-\(month)" }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = locale
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: date)
    }

    public static func sanitizedFolder(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
