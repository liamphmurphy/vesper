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

    static let exportPattern = #"^vesper-export-(\d{4})-(\d{2})-(\d{2})-(\d{4})\.zip\z"#

    /// "vesper-export-2026-11-17-1405.zip" (local time), sortable by name.
    public static func exportFileName(_ now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        func p(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return "vesper-export-\(String(format: "%04d", c.year ?? 0))-\(p(c.month))-\(p(c.day))-\(p(c.hour))\(p(c.minute)).zip"
    }

    /// Exports to delete so only the newest `keep` remain. Only files with Vesper's own export name
    /// are considered; anything else in the folder is left alone.
    public static func exportsToPrune(_ names: [String], keep: Int) -> [String] {
        let ours = names.filter { $0.range(of: exportPattern, options: .regularExpression) != nil }.sorted(by: >)
        return Array(ours.dropFirst(max(1, keep)))
    }

    /// Milliseconds since the epoch, as the Electron app stored them.
    public static func isExportDue(lastAt: Double?, now: Double, everyHours: Int) -> Bool {
        guard let last = lastAt, last.isFinite, last != 0, last <= now else { return true }
        return now - last >= Double(everyHours) * 60 * 60 * 1000
    }
}
