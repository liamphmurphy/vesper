import Foundation

/// Display formats for API timestamps (web lib/format.ts), in the viewer's locale and time zone.
extension APIDate {
    /// Timeline style (web `timelineTime`): "just now", "12m ago", "10:48" today, "Oct 31, 09:12"
    /// within a month, "Oct 30" before that.
    public static func timeline(_ iso: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = parse(iso) else { return "" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 3600 { return elapsed < 60 ? "just now" : "\(Int(elapsed / 60))m ago" }
        let time = format(date, "HH:mm", calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let day = format(date, "MMM d", calendar: calendar, locale: locale)
        return elapsed < 30 * 86400 ? "\(day), \(time)" : day
    }

    /// List-row style (web `shortAgo`): "now", "12m", "5h", "Fri", "Oct 30".
    public static func shortAgo(_ iso: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = parse(iso) else { return "" }
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h" }
        if elapsed < 6 * 86400 { return format(date, "EEE", calendar: calendar, locale: locale) }
        return format(date, "MMM d", calendar: calendar, locale: locale)
    }

    private static func format(_ date: Date, _ template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
