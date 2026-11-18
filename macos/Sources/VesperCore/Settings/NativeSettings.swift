import Foundation

// Mirror of desktop/src/settings.ts. The same `native` object in config.json, the same defaults and
// the same repair rules. Anything that reaches outside the app (an update check, a login item, a
// global shortcut) is opt-in.

public enum NotificationKind {
    /// Inbox kinds the app can alert on, in the order Settings lists them.
    public static let all = [
        "approval", "question", "blocked", "stalled", "mockup", "planning", "review", "workflow_gate",
        "connector_approval", "secret_approval", "merged", "pr_approved", "drive_backup",
    ]
}

/// Approval surfaces Touch ID can guard.
public enum TouchIdScope: String, Sendable, Codable, CaseIterable {
    case runApprovals = "run_approvals"
    case pushRequests = "push_requests"
    case connectorApprovals = "connector_approvals"
    case secretApprovals = "secret_approvals"
}

public enum SleepPolicy: String, Sendable, Codable, CaseIterable { case keep, pause }

/// What closing the last window does: stay in the Dock, live only in the menu bar, or quit.
public enum LastWindowPolicy: String, Sendable, Codable, CaseIterable { case dock, menuBar, quit }

/// How tabs are shown: one native window per tab under the system tab strip, or Safari-style
/// compact tabs drawn in the toolbar of a single window.
public enum TabLayout: String, Sendable, Codable, CaseIterable { case separate, compact }

public enum EditorKind: String, Sendable, Codable, CaseIterable { case terminal, app }

public let defaultQuickCaptureShortcut = "Alt+Shift+Space"
public let defaultScreenshotShortcut = "Alt+Shift+S"
public let defaultShowHideShortcut = "Alt+Shift+V"
public let defaultUpdateFeedURL = "https://api.github.com/repos/liamphmurphy/vesper/releases/latest"

public struct QuietHours: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var start: String
    public var end: String
    public init(enabled: Bool = false, start: String = "22:00", end: String = "08:00") {
        self.enabled = enabled
        self.start = start
        self.end = end
    }
}

/// Which alerts to show and how (settings `notifications`, and the policy functions' input).
public struct NotificationPolicy: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// By inbox kind (see `NotificationKind.all`). A kind that isn't listed is on.
    public var kinds: [String: Bool]
    /// Approve/Decline and inline Reply buttons on approvals and questions.
    public var actions: Bool
    /// Group alerts for the same run or ticket in Notification Center.
    public var groupByWork: Bool
    /// Alert once when a ticket or planning run completes or fails.
    public var runFinished: Bool
    public var sound: Bool
    public var quietHours: QuietHours

    public init(
        enabled: Bool = true, kinds: [String: Bool]? = nil, actions: Bool = true, groupByWork: Bool = true,
        runFinished: Bool = true, sound: Bool = true, quietHours: QuietHours = QuietHours()
    ) {
        self.enabled = enabled
        self.kinds = kinds ?? Dictionary(uniqueKeysWithValues: NotificationKind.all.map { ($0, true) })
        self.actions = actions
        self.groupByWork = groupByWork
        self.runFinished = runFinished
        self.sound = sound
        self.quietHours = quietHours
    }
}

public struct NativeSettings: Sendable, Codable, Equatable {
    public struct Tray: Sendable, Codable, Equatable {
        public var enabled = true
        public var onLastWindowClose: LastWindowPolicy = .dock
        public var showCount = true
        public init() {}
    }
    public struct Login: Sendable, Codable, Equatable {
        public var openAtLogin = false
        public var startHidden = true
        public init() {}
    }
    public struct Shortcut: Sendable, Codable, Equatable {
        public var enabled = false
        public var shortcut: String
        public init(shortcut: String) { self.shortcut = shortcut }
    }
    public struct Dock: Sendable, Codable, Equatable {
        public var menu = true
        public var progress = true
        public init() {}
    }
    public struct BackupExport: Sendable, Codable, Equatable {
        public var enabled = false
        public var folder = ""
        public var everyHours = 24
        public var keep = 7
        public init() {}
    }
    public struct Backups: Sendable, Codable, Equatable {
        public var excludeFromTimeMachine = true
        public var export = BackupExport()
        public init() {}
    }
    public struct Editor: Sendable, Codable, Equatable {
        public var kind: EditorKind = .terminal
        public var command = "nvim"
        public var app = "Visual Studio Code"
        public init() {}
    }
    public struct Workspaces: Sendable, Codable, Equatable {
        public var terminalApp = "Terminal"
        public var editor = Editor()
        public init() {}
    }
    public struct DeepLinks: Sendable, Codable, Equatable {
        public var enabled = true
        public init() {}
    }
    public struct Power: Sendable, Codable, Equatable {
        public var preventSleepWhileRunning = true
        public var onSleep: SleepPolicy = .keep
        public var warnOnBattery = true
        public var confirmQuitWithActiveRuns = true
        public var easeOffWhenHot = true
        public init() {}
    }
    public struct Stack: Sendable, Codable, Equatable {
        public var autoRestart = true
        public var minFreeDiskGb = 10
        public var runnerSlots = 2
        public init() {}
    }
    public struct Files: Sendable, Codable, Equatable {
        public var dockDrop = true
        public init() {}
    }
    public struct TouchId: Sendable, Codable, Equatable {
        public var enabled = false
        public var scopes: [String: Bool] = Dictionary(uniqueKeysWithValues: TouchIdScope.allCases.map { ($0.rawValue, true) })
        public init() {}
        public func isOn(_ scope: TouchIdScope) -> Bool { scopes[scope.rawValue] ?? false }
    }
    public struct Updates: Sendable, Codable, Equatable {
        public var checkEnabled = false
        public var feedUrl = defaultUpdateFeedURL
        public init() {}
    }

    public struct Tabs: Sendable, Codable, Equatable {
        public var layout: TabLayout = .separate
        public init() {}
    }

    public var tray = Tray()
    public var login = Login()
    public var notifications = NotificationPolicy()
    public var quickCapture = Shortcut(shortcut: defaultQuickCaptureShortcut)
    public var screenshot = Shortcut(shortcut: defaultScreenshotShortcut)
    public var showHide = Shortcut(shortcut: defaultShowHideShortcut)
    public var dock = Dock()
    public var backups = Backups()
    public var workspaces = Workspaces()
    public var deepLinks = DeepLinks()
    public var power = Power()
    public var stack = Stack()
    public var files = Files()
    public var touchId = TouchId()
    public var updates = Updates()
    public var tabs = Tabs()

    public init() {}

    public static func defaults() -> NativeSettings { NativeSettings() }
}

// MARK: - Validation helpers (settings.ts)

public func isValidClockTime(_ value: Any?) -> Bool {
    guard let s = value as? String else { return false }
    return s.range(of: #"^([01][0-9]|2[0-3]):([0-5][0-9])\z"#, options: .regularExpression) != nil
}

/// An app name for `open -a`: letters, digits, spaces and a little punctuation.
public func isValidAppName(_ value: Any?) -> Bool {
    guard let s = value as? String, !s.isEmpty, s.trimmingCharacters(in: .whitespaces) == s else { return false }
    return s.range(of: #"^[\p{L}\p{N} ._&+()'-]{1,64}\z"#, options: .regularExpression) != nil
}

/// A command for "Open in editor" run in Terminal: a program and plain arguments. No quotes, `$`,
/// backtick, `;`, `|`, `&` or redirects, so it can't become more than one command.
public func isValidTerminalCommand(_ value: Any?) -> Bool {
    guard let s = value as? String, s.utf16.count <= 100 else { return false }
    return s.range(of: #"^[A-Za-z0-9._/=+-]+( [A-Za-z0-9._/=+-]+)*\z"#, options: .regularExpression) != nil
}

/// An absolute folder path, or "" for none.
public func normalizeFolder(_ value: Any?, fallback: String) -> String {
    if let s = value as? String, s.isEmpty { return "" }
    guard let s = value as? String, s.hasPrefix("/"), s.utf16.count <= 1024,
          !s.unicodeScalars.contains(where: { $0.value <= 0x1f })
    else { return fallback }
    var trimmed = s
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.isEmpty ? "/" : trimmed
}

/// Only https feeds (or http on loopback, for testing) are accepted.
public func normalizeFeedURL(_ value: Any?, fallback: String) -> String {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
          let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
    else { return fallback }
    let loopback = host == "localhost" || host == "127.0.0.1"
    if scheme == "https" || (scheme == "http" && loopback) { return url.absoluteString }
    return fallback
}

// MARK: - Normalisation

private typealias Obj = [String: Any]

private func obj(_ value: Any?) -> Obj { value as? Obj ?? [:] }

private func isBool(_ value: Any) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

private func bool(_ value: Any?, _ fallback: Bool) -> Bool {
    guard let v = value, isBool(v), let b = v as? Bool else { return fallback }
    return b
}

/// JavaScript's `Number(value)`, for the cases a settings file or patch can contain.
private func jsNumber(_ value: Any?) -> Double? {
    switch value {
    case nil: return nil
    case is NSNull: return 0
    case let v? where isBool(v): return (v as? Bool) == true ? 1 : 0
    case let n as NSNumber: return n.doubleValue
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? 0 : Double(t)
    default: return nil
    }
}

private func intIn(_ value: Any?, _ lo: Int, _ hi: Int, _ fallback: Int) -> Int {
    guard let n = jsNumber(value), n.isFinite, n == n.rounded(), n >= Double(lo), n <= Double(hi) else { return fallback }
    return Int(n)
}

private func boolMap(_ keys: [String], _ value: Any?, _ fallback: [String: Bool]) -> [String: Bool] {
    let src = obj(value)
    return Dictionary(uniqueKeysWithValues: keys.map { ($0, bool(src[$0], fallback[$0] ?? true)) })
}

private func shortcutString(_ value: Any?, _ fallback: String) -> String {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return fallback }
    return String(s.prefix(64))
}

private func oneOf<T: RawRepresentable>(_ value: Any?, _ fallback: T) -> T where T.RawValue == String {
    if let s = value as? String, let v = T(rawValue: s) { return v }
    return fallback
}

extension NativeSettings {
    /// Accepts a partial or hostile settings object (from disk or from Settings) and returns a
    /// complete, valid one. Unknown keys are dropped; invalid values fall back to `base` (the
    /// defaults, or the current settings when applying a patch).
    public static func normalize(_ raw: Any?, base: NativeSettings = NativeSettings()) -> NativeSettings {
        let src = obj(raw)
        let tray = obj(src["tray"]), login = obj(src["login"]), notif = obj(src["notifications"])
        let quiet = obj(notif["quietHours"]), qc = obj(src["quickCapture"]), deep = obj(src["deepLinks"])
        let power = obj(src["power"]), stack = obj(src["stack"]), files = obj(src["files"])
        let touch = obj(src["touchId"]), updates = obj(src["updates"]), shot = obj(src["screenshot"])
        let showHide = obj(src["showHide"]), dock = obj(src["dock"]), backups = obj(src["backups"])
        let tabs = obj(src["tabs"])
        let exp = obj(backups["export"]), wsp = obj(src["workspaces"]), editor = obj(wsp["editor"])

        var out = NativeSettings()
        out.tray.enabled = bool(tray["enabled"], base.tray.enabled)
        out.tray.onLastWindowClose = oneOf(tray["onLastWindowClose"], base.tray.onLastWindowClose)
        out.tray.showCount = bool(tray["showCount"], base.tray.showCount)

        out.login.openAtLogin = bool(login["openAtLogin"], base.login.openAtLogin)
        out.login.startHidden = bool(login["startHidden"], base.login.startHidden)

        out.notifications = NotificationPolicy(
            enabled: bool(notif["enabled"], base.notifications.enabled),
            kinds: boolMap(NotificationKind.all, notif["kinds"], base.notifications.kinds),
            actions: bool(notif["actions"], base.notifications.actions),
            groupByWork: bool(notif["groupByWork"], base.notifications.groupByWork),
            runFinished: bool(notif["runFinished"], base.notifications.runFinished),
            sound: bool(notif["sound"], base.notifications.sound),
            quietHours: QuietHours(
                enabled: bool(quiet["enabled"], base.notifications.quietHours.enabled),
                start: isValidClockTime(quiet["start"]) ? quiet["start"] as! String : base.notifications.quietHours.start,
                end: isValidClockTime(quiet["end"]) ? quiet["end"] as! String : base.notifications.quietHours.end
            )
        )

        out.quickCapture.enabled = bool(qc["enabled"], base.quickCapture.enabled)
        out.quickCapture.shortcut = shortcutString(qc["shortcut"], base.quickCapture.shortcut)
        out.screenshot.enabled = bool(shot["enabled"], base.screenshot.enabled)
        out.screenshot.shortcut = shortcutString(shot["shortcut"], base.screenshot.shortcut)
        out.showHide.enabled = bool(showHide["enabled"], base.showHide.enabled)
        out.showHide.shortcut = shortcutString(showHide["shortcut"], base.showHide.shortcut)

        out.dock.menu = bool(dock["menu"], base.dock.menu)
        out.dock.progress = bool(dock["progress"], base.dock.progress)

        out.backups.excludeFromTimeMachine = bool(backups["excludeFromTimeMachine"], base.backups.excludeFromTimeMachine)
        out.backups.export.enabled = bool(exp["enabled"], base.backups.export.enabled)
        out.backups.export.folder = normalizeFolder(exp["folder"], fallback: base.backups.export.folder)
        out.backups.export.everyHours = intIn(exp["everyHours"], 1, 24 * 7, base.backups.export.everyHours)
        out.backups.export.keep = intIn(exp["keep"], 1, 100, base.backups.export.keep)

        out.workspaces.terminalApp = isValidAppName(wsp["terminalApp"]) ? wsp["terminalApp"] as! String : base.workspaces.terminalApp
        out.workspaces.editor.kind = oneOf(editor["kind"], base.workspaces.editor.kind)
        out.workspaces.editor.command = isValidTerminalCommand(editor["command"]) ? editor["command"] as! String : base.workspaces.editor.command
        out.workspaces.editor.app = isValidAppName(editor["app"]) ? editor["app"] as! String : base.workspaces.editor.app

        out.deepLinks.enabled = bool(deep["enabled"], base.deepLinks.enabled)

        out.power.preventSleepWhileRunning = bool(power["preventSleepWhileRunning"], base.power.preventSleepWhileRunning)
        out.power.onSleep = oneOf(power["onSleep"], base.power.onSleep)
        out.power.warnOnBattery = bool(power["warnOnBattery"], base.power.warnOnBattery)
        out.power.confirmQuitWithActiveRuns = bool(power["confirmQuitWithActiveRuns"], base.power.confirmQuitWithActiveRuns)
        out.power.easeOffWhenHot = bool(power["easeOffWhenHot"], base.power.easeOffWhenHot)

        out.stack.autoRestart = bool(stack["autoRestart"], base.stack.autoRestart)
        if let minDisk = jsNumber(stack["minFreeDiskGb"]), minDisk.isFinite, minDisk >= 1, minDisk <= 1000 {
            out.stack.minFreeDiskGb = Int(minDisk.rounded())
        } else {
            out.stack.minFreeDiskGb = base.stack.minFreeDiskGb
        }
        out.stack.runnerSlots = intIn(stack["runnerSlots"], 1, 32, base.stack.runnerSlots)

        out.files.dockDrop = bool(files["dockDrop"], base.files.dockDrop)

        out.touchId.enabled = bool(touch["enabled"], base.touchId.enabled)
        out.touchId.scopes = boolMap(TouchIdScope.allCases.map(\.rawValue), touch["scopes"], base.touchId.scopes)

        out.updates.checkEnabled = bool(updates["checkEnabled"], base.updates.checkEnabled)
        out.updates.feedUrl = normalizeFeedURL(updates["feedUrl"], fallback: base.updates.feedUrl)

        out.tabs.layout = oneOf(tabs["layout"], base.tabs.layout)
        return out
    }

    /// The settings as a JSON object (what is written under `native`).
    public func jsonObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Applies a partial patch (a JSON object, as from the Settings window) on top of these settings.
    public func applying(patch: Any?) -> NativeSettings {
        NativeSettings.normalize(Self.deepMerge(jsonObject(), obj(patch)), base: self)
    }

    private static func deepMerge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in patch {
            if k == "__proto__" || k == "constructor" || k == "prototype" { continue }
            if let nested = v as? [String: Any] {
                out[k] = deepMerge(out[k] as? [String: Any] ?? [:], nested)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
