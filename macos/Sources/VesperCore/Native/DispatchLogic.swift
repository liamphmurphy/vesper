import Foundation

/// What a dispatch preview says about starting one ticket, for the Start ready sheet: the Swift port
/// of the checks in web components/domain/dispatch-dialog.tsx (keep them in step).
public struct DispatchCheck: Sendable, Equatable {
    public var ticketKey: String
    public var blockers: [String]
    public var queuedBehind: [String]
    public var keyPresent: Bool
    /// The secret the harness needs ("ANTHROPIC_API_KEY").
    public var keySecret: String
    public var harness: String
    /// Backends of the runners online now.
    public var runnerBackends: [String]
    public var scopesNeedingApproval: Int

    public init(ticketKey: String, blockers: [String] = [], queuedBehind: [String] = [], keyPresent: Bool = true,
                keySecret: String = "", harness: String = "", runnerBackends: [String] = [], scopesNeedingApproval: Int = 0) {
        self.ticketKey = ticketKey; self.blockers = blockers; self.queuedBehind = queuedBehind; self.keyPresent = keyPresent
        self.keySecret = keySecret; self.harness = harness; self.runnerBackends = runnerBackends
        self.scopesNeedingApproval = scopesNeedingApproval
    }
}

extension API.DispatchPreview {
    public var check: DispatchCheck {
        DispatchCheck(
            ticketKey: ticketKey, blockers: blockers, queuedBehind: queuedBehind, keyPresent: harnessKey.present,
            keySecret: harnessKey.secret, harness: resolved.harness.rawValue,
            runnerBackends: runner.runners.map(\.backend.rawValue),
            scopesNeedingApproval: scopes.filter { $0.mode == .requiresApproval }.count
        )
    }
}

public enum DispatchLogic {
    public enum Tone: Sendable, Equatable { case blocked, human, neutral, done }

    /// Across every ticket in the sheet.
    public struct Summary: Sendable, Equatable {
        public var blocked: Bool
        /// Some unblocked run would need a harness key that isn't stored.
        public var missingKey: String?
        /// Why no online runner could start some of them (every runner is sandboxed and the key is missing).
        public var stuckReasons: [String]
    }

    /// Only isolated runs need a stored key; a fake or local runner uses the machine's own CLI login.
    static func isolates(_ backend: String) -> Bool { backend == "docker" || backend == "microvm" }

    public static func summary(_ checks: [DispatchCheck]) -> Summary {
        let keyless = checks.filter { c in
            c.blockers.isEmpty && !c.keyPresent && (c.runnerBackends.isEmpty || c.runnerBackends.contains(where: isolates))
        }
        let stuck = keyless.filter { !$0.runnerBackends.isEmpty && $0.runnerBackends.allSatisfy(isolates) }
        var reasons: [String] = []
        for c in stuck {
            let reason = "\(c.harness.isEmpty ? "This harness" : c.harness): no \(c.keySecret) secret"
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        return Summary(blocked: checks.contains { !$0.blockers.isEmpty }, missingKey: keyless.first?.keySecret, stuckReasons: reasons)
    }

    /// The right-hand note on a ticket's row.
    public static func rowStatus(_ c: DispatchCheck) -> (text: String, tone: Tone) {
        if !c.blockers.isEmpty { return (c.blockers.joined(separator: "; "), .blocked) }
        if !c.queuedBehind.isEmpty { return ("Queues until blockers are Done", .human) }
        if !c.keyPresent { return ("No \(c.keySecret) key", .human) }
        return ("\(c.scopesNeedingApproval) scopes need approval", .neutral)
    }

    /// When the run starts, from runner heartbeats and the queue (web `StartsLine`).
    public static func starts(online: Bool, starting: Bool, busy: Int, slots: Int, queued: Int) -> (title: String, detail: String, tone: Tone) {
        if !online {
            return starting
                ? ("Runner is starting: this run will start once it finishes booting", "", .human)
                : ("No runner is online: it waits in the queue until one starts", "", .blocked)
        }
        let free = slots - busy
        return (free > 0 && queued == 0 ? "Immediately" : "When a slot frees up",
                "\(busy) of \(slots) runner slots in use" + (queued > 0 ? " · \(queued) queued" : ""),
                free > 0 ? .done : .human)
    }
}
