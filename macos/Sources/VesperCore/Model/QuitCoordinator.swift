#if os(macOS)
import AppKit

/// Answers `applicationShouldTerminate` for a quit that needs async cleanup first (unsaved pages,
/// active runs, stopping the stack), whatever context `NSApp.terminate` was called from.
///
/// The cleanup is main-actor work, so it needs the main queue to run. For `.terminateLater` AppKit waits
/// for the reply in a run loop nested inside whatever called `terminate`. When that caller is itself
/// a main-queue block (a `DispatchQueue.main` callback, a main-actor Task, the menu bar extra's
/// Quit), the main queue can't drain there, so the cleanup never starts and the app just sits. A
/// second Quit then exits at once without asking the delegate, skipping the cleanup.
///
/// Timers do fire in that nested loop, so one checks shortly afterwards that the cleanup started.
/// If it hasn't, the coordinator answers no, the caller unwinds, the cleanup runs, and the
/// coordinator quits again itself. It doesn't answer no up front every time: during logout or
/// restart that would cancel the logout.
@MainActor
public final class QuitCoordinator {
    private enum State {
        case idle
        /// `awaitingReply`: AppKit is still waiting on `.terminateLater`, so the outcome goes to
        /// `reply`; otherwise it has been told no and a successful cleanup calls `terminate`.
        case cleaningUp(awaitingReply: Bool)
        case readyToQuit
    }

    private let cleanup: @MainActor () async -> Bool
    private let reply: @MainActor (Bool) -> Void
    private let terminate: @MainActor () -> Void
    private let startDeadline: TimeInterval
    private var state = State.idle
    private var attempt = 0
    private var cleanupStarted = false

    /// - Parameters:
    ///   - startDeadline: how long the cleanup gets to start before AppKit is told no.
    ///   - cleanup: true to go ahead and quit, false to stay open.
    ///   - reply: `NSApp.reply(toApplicationShouldTerminate:)`.
    ///   - terminate: `NSApp.terminate(nil)`.
    public init(
        startDeadline: TimeInterval = 0.25,
        cleanup: @escaping @MainActor () async -> Bool,
        reply: @escaping @MainActor (Bool) -> Void,
        terminate: @escaping @MainActor () -> Void
    ) {
        self.startDeadline = startDeadline
        self.cleanup = cleanup
        self.reply = reply
        self.terminate = terminate
    }

    /// The answer for `applicationShouldTerminate`.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        switch state {
        case .readyToQuit: return .terminateNow
        case .cleaningUp: return .terminateCancel  // a repeat Quit: the running cleanup decides
        case .idle: break
        }
        attempt += 1
        let current = attempt
        cleanupStarted = false
        state = .cleaningUp(awaitingReply: true)
        Task { await runCleanup(attempt: current) }
        let check = Timer(timeInterval: startDeadline, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.unwindIfCleanupHasNotStarted(attempt: current) }
        }
        RunLoop.main.add(check, forMode: .common)
        return .terminateLater
    }

    private func runCleanup(attempt current: Int) async {
        guard current == attempt else { return }
        cleanupStarted = true
        let proceed = await cleanup()
        guard current == attempt, case .cleaningUp(let awaitingReply) = state else { return }
        state = proceed ? .readyToQuit : .idle
        if awaitingReply {
            reply(proceed)
        } else if proceed {
            terminate()
        }
    }

    private func unwindIfCleanupHasNotStarted(attempt current: Int) {
        guard current == attempt, !cleanupStarted, case .cleaningUp(awaitingReply: true) = state else { return }
        state = .cleaningUp(awaitingReply: false)
        reply(false)
    }
}
#endif
