import AppKit
import XCTest
@testable import VesperCore

/// Stands in for NSApplication's quit: asks the coordinator and, for `.terminateLater`, waits for the
/// reply in a run loop nested inside the caller, as AppKit does. (AppKit's wait runs in the modal
/// panel mode; the default mode used here is a common mode too, and the main queue doesn't drain in
/// either while a main-queue block is running.)
@MainActor
private final class FakeApp {
    private(set) var coordinator: QuitCoordinator!
    private(set) var asks = 0
    private(set) var cleanups = 0
    private(set) var terminated = false
    /// What the cleanup decides (false: unsaved changes or Cancel on "Runs are still working").
    var allowQuit = true
    var onTerminate: () -> Void = {}
    private var waiting = false
    private var answer: Bool?

    init() {
        coordinator = QuitCoordinator(
            cleanup: { [unowned self] in
                cleanups += 1
                try? await Task.sleep(for: .milliseconds(50))
                return allowQuit
            },
            reply: { [unowned self] in if waiting { answer = $0 } },
            terminate: { [unowned self] in terminate() }
        )
    }

    func terminate() {
        asks += 1
        switch coordinator.shouldTerminate() {
        case .terminateNow:
            finish()
        case .terminateLater:
            waiting = true
            answer = nil
            let deadline = Date().addingTimeInterval(2)
            while answer == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            waiting = false
            if answer == true { finish() }
        case .terminateCancel:
            break
        @unknown default:
            break
        }
    }

    /// `terminate` from inside a main-queue block, like the menu bar's Quit.
    func terminateFromMainQueue(then: @escaping @MainActor () -> Void = {}) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.terminate()
                then()
            }
        }
    }

    /// `terminate` from a run-loop timer, like ⌘Q's key event or the Dock's Apple Event.
    func terminateFromRunLoopSource() {
        RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.terminate() }
        }, forMode: .common)
    }

    private func finish() {
        terminated = true
        onTerminate()
    }
}

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    /// The menu bar's Quit: quits on the first try, after the cleanup ran.
    func testQuitFromAMainQueueBlockRunsTheCleanupAndQuits() {
        let app = FakeApp()
        let quit = expectation(description: "quit")
        app.onTerminate = { quit.fulfill() }
        app.terminateFromMainQueue()
        wait(for: [quit], timeout: 5)
        XCTAssertEqual(app.cleanups, 1)
        XCTAssertEqual(app.asks, 2, "told no to unwind the caller, then quit again after the cleanup")
    }

    /// ⌘Q, the Dock and logout: the cleanup runs while AppKit waits, so the answer comes within the
    /// one request and is never no (which would cancel a logout).
    func testQuitFromARunLoopSourceRepliesWithinTheSameRequest() {
        let app = FakeApp()
        let quit = expectation(description: "quit")
        app.onTerminate = { quit.fulfill() }
        app.terminateFromRunLoopSource()
        wait(for: [quit], timeout: 5)
        XCTAssertEqual(app.cleanups, 1)
        XCTAssertEqual(app.asks, 1)
    }

    /// A declined cleanup leaves the app open, and the next Quit asks again.
    func testDeclinedCleanupStaysOpenAndTheNextQuitAsksAgain() {
        let app = FakeApp()
        app.allowQuit = false
        let settled = expectation(description: "first quit settled")
        app.terminateFromMainQueue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        }
        wait(for: [settled], timeout: 5)
        XCTAssertFalse(app.terminated)
        XCTAssertEqual(app.cleanups, 1)

        app.allowQuit = true
        let quit = expectation(description: "second quit")
        app.onTerminate = { quit.fulfill() }
        app.terminateFromMainQueue()
        wait(for: [quit], timeout: 5)
        XCTAssertEqual(app.cleanups, 2)
    }

    /// A second Quit while the cleanup runs doesn't start another one.
    func testRepeatQuitDuringCleanupIsCancelled() {
        let app = FakeApp()
        let quit = expectation(description: "quit")
        app.onTerminate = { quit.fulfill() }
        var repeatAnswer: NSApplication.TerminateReply?
        app.terminateFromMainQueue { repeatAnswer = app.coordinator.shouldTerminate() }
        wait(for: [quit], timeout: 5)
        XCTAssertEqual(repeatAnswer, .terminateCancel)
        XCTAssertEqual(app.cleanups, 1)
    }
}
