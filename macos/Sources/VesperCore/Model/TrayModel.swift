import Foundation

// Port of desktop/src/tray-model.ts: the menu bar menu as data, so its content is unit tested and
// the app only maps it onto NSMenu.

public enum TrayAction: Equatable, Sendable {
    case open
    case openHref(String)
    case quickCapture
    case screenshot
    case pauseRuns
    case resumeRuns
    case restartStack
    case showLogs
    case preferences
    case quit
}

public enum TrayMenuItem: Equatable, Sendable {
    case header(String)
    case item(label: String, action: TrayAction, enabled: Bool = true, accelerator: String? = nil)
    case separator

    /// The visible text, nil for a separator.
    public var label: String? {
        switch self {
        case .header(let l): return l
        case .item(let l, _, _, _): return l
        case .separator: return nil
        }
    }

    public var action: TrayAction? {
        if case .item(_, let a, _, _) = self { return a }
        return nil
    }
}

public struct ShortcutSetting: Sendable, Equatable {
    public var enabled: Bool
    public var shortcut: String
    public init(enabled: Bool, shortcut: String) {
        self.enabled = enabled
        self.shortcut = shortcut
    }
}

public struct TrayMenuInput: Sendable {
    public var health: StackHealth
    /// Whether this app runs the stack (Restart / Logs only make sense then).
    public var localStack: Bool
    public var items: [InboxItem]
    public var runs: [RunSummary]
    /// Runs paused from the tray (or on sleep) that Resume would restart.
    public var pausedByVesper: Int
    public var quickCapture: ShortcutSetting?
    public var screenshot: ShortcutSetting?
    /// A line under the status, e.g. "Mac is hot: 1 run at a time".
    public var notice: String?
    public var maxPerSection: Int

    public init(
        health: StackHealth, localStack: Bool = true, items: [InboxItem] = [], runs: [RunSummary] = [],
        pausedByVesper: Int = 0, quickCapture: ShortcutSetting? = nil, screenshot: ShortcutSetting? = nil,
        notice: String? = nil, maxPerSection: Int = 5
    ) {
        self.health = health
        self.localStack = localStack
        self.items = items
        self.runs = runs
        self.pausedByVesper = pausedByVesper
        self.quickCapture = quickCapture
        self.screenshot = screenshot
        self.notice = notice
        self.maxPerSection = maxPerSection
    }
}

public enum TrayLastWindowAction: Equatable, Sendable { case stay, hideDock, quit }

public enum TrayModel {
    public static func clipLabel(_ text: String, max: Int = 48) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > max else { return flat }
        let head = String(flat.prefix(max - 1)).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    /// Open, unread Needs-you items, newest first.
    public static func newestNeedsYou(_ items: [InboxItem]) -> [InboxItem] {
        items.enumerated()
            .filter { $0.element.needsYou && !$0.element.resolved && !$0.element.read }
            .sorted {
                let a = parseISODate($0.element.createdAt), b = parseISODate($1.element.createdAt)
                return a != b ? a > b : $0.offset < $1.offset
            }
            .map(\.element)
    }

    static func statusLine(_ health: StackHealth) -> String {
        switch health.phase {
        case .running: return "● Vesper is running"
        case .starting: return "○ Starting…"
        case .downloading:
            if let done = health.downloadedBytes, let total = health.totalBytes, total > 0 {
                return "○ Downloading run image (\(Int(100 * Double(done) / Double(total)))%)"
            }
            return "○ Downloading run image…"
        case .stopped: return "○ Stack stopped"
        default: return "⚠ \(health.title)"
        }
    }

    /// Builds the tray menu from the latest inbox, runs and stack health.
    public static func buildTrayMenu(_ input: TrayMenuInput) -> [TrayMenuItem] {
        let max = input.maxPerSection
        var out: [TrayMenuItem] = [.header(statusLine(input.health))]
        if input.health.phase == .error || input.health.phase == .degraded {
            let step = input.health.nextStep.flatMap { $0.isEmpty ? nil : $0 } ?? input.health.message
            out.append(.header(clipLabel(step, max: 60)))
        }
        if let notice = input.notice, !notice.isEmpty { out.append(.header(clipLabel(notice, max: 60))) }
        out.append(.separator)

        let needs = newestNeedsYou(input.items)
        out.append(.header(needs.isEmpty ? "Nothing needs you" : "Needs you (\(needs.count))"))
        for item in needs.prefix(max) {
            let who = item.ticketKey.flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
            out.append(.item(label: clipLabel("\(who)\(item.title)"), action: .openHref(item.href.isEmpty ? "/inbox" : item.href)))
        }
        if needs.count > max { out.append(.item(label: "Show all \(needs.count) in Inbox…", action: .openHref("/inbox"))) }

        let running = input.runs.filter { $0.purpose != "chat" }
        if !running.isEmpty {
            out.append(.separator)
            out.append(.header("Running (\(running.count))"))
            for run in running.prefix(max) {
                let title = [run.workTitle, run.ticketKey].compactMap { $0 }.first { !$0.isEmpty } ?? "Run"
                let who = run.agent?.name.flatMap { $0.isEmpty ? nil : "\($0): " } ?? ""
                let paused = run.state == "paused" ? " (paused)" : ""
                out.append(.item(label: clipLabel("\(who)\(title)\(paused)"), action: .openHref("/runs/\(run.id)")))
            }
            if running.count > max { out.append(.item(label: "Show all \(running.count) runs…", action: .openHref("/runs"))) }
        }

        out.append(.separator)
        out.append(.item(label: "Open Vesper", action: .open))
        if let qc = input.quickCapture, qc.enabled {
            out.append(.item(label: "Quick Capture…", action: .quickCapture, accelerator: qc.shortcut))
        }
        if let shot = input.screenshot, shot.enabled {
            out.append(.item(label: "Screenshot to Chat…", action: .screenshot, accelerator: shot.shortcut))
        }

        let pausable = RunLogic.pausableRuns(running).count
        if input.pausedByVesper > 0 {
            out.append(.item(label: "Resume Runs (\(input.pausedByVesper))", action: .resumeRuns))
        } else {
            out.append(.item(label: pausable > 0 ? "Pause Runs (\(pausable))" : "Pause Runs", action: .pauseRuns, enabled: pausable > 0))
        }

        if input.localStack {
            out.append(.separator)
            out.append(.item(label: "Restart Stack", action: .restartStack, enabled: input.health.phase != .starting))
            out.append(.item(label: "Show Logs…", action: .showLogs))
        }

        out.append(.separator)
        out.append(.item(label: "Settings…", action: .preferences))
        out.append(.item(label: "Quit Vesper", action: .quit))
        return out
    }

    /// Text beside the menu bar icon: the Needs-you count, or nothing.
    public static func trayTitle(count: Int, showCount: Bool) -> String {
        if !showCount || count <= 0 { return "" }
        return count > 99 ? "99+" : String(count)
    }

    public static func trayTooltip(_ health: StackHealth, count: Int) -> String {
        let needs = count > 0 ? " · \(count) need\(count == 1 ? "s" : "") you" : ""
        return "Vesper: \(health.title)\(needs)"
    }

    /// What to do when the last window closes. "menuBar" needs the tray: without it the app would
    /// be invisible, so it falls back to the Dock.
    public static func lastWindowClosedAction(trayEnabled: Bool, policy: LastWindowPolicy) -> TrayLastWindowAction {
        if policy == .quit { return .quit }
        if policy == .menuBar && trayEnabled { return .hideDock }
        return .stay
    }

    /// Tray icon state for a stack phase.
    public enum IconState: Equatable, Sendable { case running, starting, error }

    public static func iconState(_ phase: StackPhase) -> IconState {
        switch phase {
        case .running: return .running
        case .starting, .downloading, .stopped: return .starting
        default: return .error
        }
    }
}

/// Parses the API's ISO-8601 timestamps (with or without fractional seconds). Unparseable → distantPast.
public func parseISODate(_ s: String) -> Date {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: s) ?? .distantPast
}
