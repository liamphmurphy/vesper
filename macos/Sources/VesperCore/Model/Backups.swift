import Foundation

// Port of desktop/src/backups.ts: Time Machine exclusion and scheduled exports to a folder.

public enum Backups {
    /// Data-directory folders Time Machine should skip. All are rebuilt or re-downloaded: per-run VM
    /// disks and cache generations (vm/), and the kernel and agent image (images/).
    public static func timeMachineTargets(dataDirectory: String) -> [String] {
        let base = dataDirectory.hasSuffix("/") && dataDirectory.count > 1 ? String(dataDirectory.dropLast()) : dataDirectory
        return ["\(base)/vm", "\(base)/images"]
    }

    /// Reads `tmutil isexcluded <path>`: "[Excluded]    /path" or "[Included]    /path".
    public static func parseIsExcluded(_ stdout: String) -> Bool? {
        if stdout.range(of: #"(?m)^\s*\[Excluded\]"#, options: .regularExpression) != nil { return true }
        if stdout.range(of: #"(?m)^\s*\[Included\]"#, options: .regularExpression) != nil { return false }
        return nil
    }

    static let exportPattern = #"^vesper-export-(\d{4})-(\d{2})-(\d{2})-(\d{4})\.(zip|vesper\.enc)\z"#

    /// "vesper-export-2026-11-17-1405.zip" (or `.vesper.enc` when encrypted), in local time, sortable by name.
    public static func exportFileName(_ now: Date, encrypted: Bool = false, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        func p(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let ext = encrypted ? "vesper.enc" : "zip"
        return "vesper-export-\(String(format: "%04d", c.year ?? 0))-\(p(c.month))-\(p(c.day))-\(p(c.hour))\(p(c.minute)).\(ext)"
    }

    /// Canonical export filename if `name` is Vesper's own export (`.zip` or `.vesper.enc`) or its
    /// evicted iCloud Drive placeholder (`.vesper-export-YYYY-MM-DD-HHMM.<ext>.icloud`), else nil.
    static func canonicalExportName(_ name: String) -> String? {
        let stripped: String
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            stripped = String(name.dropFirst().dropLast(".icloud".count))
        } else {
            stripped = name
        }
        guard stripped.range(of: exportPattern, options: .regularExpression) != nil else { return nil }
        return stripped
    }

    /// Exports to delete so only the newest `keep` remain. Considers Vesper's own export archives
    /// (`.zip` and `.vesper.enc`) and their evicted iCloud Drive placeholders (`.<name>.icloud`),
    /// ordered by export timestamp regardless of eviction state; anything else is left alone.
    public static func exportsToPrune(_ names: [String], keep: Int) -> [String] {
        let ours = names.compactMap { name -> (canonical: String, actual: String)? in
            guard let canonical = canonicalExportName(name) else { return nil }
            return (canonical, name)
        }
        .sorted { a, b in
            a.canonical != b.canonical ? a.canonical > b.canonical : a.actual > b.actual
        }
        return ours.dropFirst(max(1, keep)).map { $0.actual }
    }

    /// Milliseconds since the epoch, as the Electron app stored them.
    public static func isExportDue(lastAt: Double?, now: Double, everyHours: Int) -> Bool {
        guard let last = lastAt, last.isFinite, last != 0, last <= now else { return true }
        return now - last >= Double(everyHours) * 60 * 60 * 1000
    }
}
