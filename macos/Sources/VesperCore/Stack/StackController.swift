import Foundation
import Observation

// The public surface the app target uses to run the bundled `vesper app` (docs/dev/native-mac-app.md,
// "Shell ↔ Go"). The window code depends only on this file's public API; the implementation fills
// in the bodies.

/// Health phases, as desktop/src/stack-health.ts (minus "remote": the app is local only).
public enum StackPhase: String, Sendable, Codable {
    case starting, downloading, running, degraded, error, stopped
}

/// What the window, menu bar and Dock show about the local stack.
public struct StackHealth: Sendable, Equatable {
    public var phase: StackPhase
    /// Short title, e.g. "Vesper is running", "Virtualization unavailable".
    public var title: String
    public var message: String
    /// What the person can do next, e.g. "Free up disk space, then restart the stack."
    public var nextStep: String?
    /// 0...1 while the run image downloads.
    public var downloadFraction: Double?

    public init(phase: StackPhase, title: String, message: String = "", nextStep: String? = nil, downloadFraction: Double? = nil) {
        self.phase = phase
        self.title = title
        self.message = message
        self.nextStep = nextStep
        self.downloadFraction = downloadFraction
    }

    public static let initial = StackHealth(phase: .starting, title: "Starting…")
}

/// A signed-in connection to the running stack.
public struct StackSession: Sendable, Equatable {
    /// e.g. http://127.0.0.1:8080
    public var baseURL: URL
    /// The `vesper_session` cookie value. Put it into each web view's cookie store and send it on
    /// the shell's own API calls. Never log it.
    public var sessionToken: String

    public init(baseURL: URL, sessionToken: String) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
    }

    public static let cookieName = "vesper_session"
}

/// Runs and supervises the bundled `vesper app`. One per app.
@MainActor
@Observable
public final class StackController {
    public private(set) var health: StackHealth = .initial
    /// Non-nil once the stack is ready and the shell is signed in.
    public private(set) var session: StackSession?
    /// The data dir passed to `vesper app` (default ~/Library/Application Support/vesper-desktop).
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    /// Starts the stack if it isn't running. Updates `health` and then `session`.
    public func start() async {}

    /// Stops and starts the stack (menu, menu bar, Settings, auto-restart).
    public func restart() async {}

    /// SIGTERM, wait up to 10 s, then SIGKILL. Called on quit.
    public func stop() async {}

    /// `<dataDir>/logs/vesper-app.log`.
    public var logFileURL: URL { dataDirectory.appendingPathComponent("logs/vesper-app.log") }
}
