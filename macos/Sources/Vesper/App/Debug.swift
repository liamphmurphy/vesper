import Foundation
import Observation

/// Debug logging to stderr, on when VESPER_DEBUG=1. Never pass secrets (the session token).
let debugLoggingEnabled = ProcessInfo.processInfo.environment["VESPER_DEBUG"] == "1"

func vlog(_ message: @autoclosure () -> String) {
    guard debugLoggingEnabled else { return }
    FileHandle.standardError.write(Data("[vesper] \(message())\n".utf8))
}

/// Runs `apply` with the value `read` returns now and again after every change to the observable
/// properties `read` touches (withObservationTracking fires once, so it re-arms itself).
@MainActor
func track<T>(_ read: @escaping @MainActor () -> T, apply: @escaping @MainActor (T) -> Void) {
    let value = withObservationTracking({ read() }, onChange: {
        Task { @MainActor in track(read, apply: apply) }
    })
    apply(value)
}
