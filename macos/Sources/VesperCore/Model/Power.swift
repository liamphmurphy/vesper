import Foundation

// Port of desktop/src/power.ts. See docs/dev/desktop-power.md for what Virtualization.framework
// does across sleep and why these are the defaults.

public enum RunLogic {
    /// Runs doing work right now: they keep the Mac awake and show under "Running" in the tray.
    public static func isActive(_ run: RunSummary) -> Bool {
        run.state == "starting" || run.state == "running" || (run.state == "waiting" && run.waitReason == "checks")
    }

    /// Live runs "Pause runs" can pause: chat runs only cancel, and a run in its server checks can't pause.
    public static func pausableRuns(_ runs: [RunSummary]) -> [RunSummary] {
        runs.filter { $0.purpose != "chat" && ($0.state == "running" || ($0.state == "waiting" && $0.waitReason != "checks")) }
    }
}

public enum PowerLogic {
    /// Whether to hold a power-save blocker: only while a run is actually working.
    public static func wantsSleepBlocker(_ settings: NativeSettings.Power, live: [RunSummary]) -> Bool {
        settings.preventSleepWhileRunning && live.contains(where: RunLogic.isActive)
    }

    /// Runs to pause when the Mac is about to sleep, under the "pause" policy.
    public static func runsToPauseOnSleep(_ settings: NativeSettings.Power, live: [RunSummary]) -> [RunSummary] {
        settings.onSleep == .pause ? RunLogic.pausableRuns(live) : []
    }

    /// Runs to resume after wake (or from the tray's Resume): only those Vesper paused itself and
    /// that are still paused.
    public static func runsToResume(pausedByVesper: Set<String>, live: [RunSummary]) -> [String] {
        live.filter { pausedByVesper.contains($0.id) && $0.state == "paused" }.map(\.id)
    }

    /// Drops ids that are no longer paused, so the set doesn't grow forever.
    public static func prunePausedSet(_ pausedByVesper: inout Set<String>, live: [RunSummary]) {
        let stillPaused = Set(live.filter { $0.state == "paused" }.map(\.id))
        pausedByVesper = pausedByVesper.intersection(stillPaused)
    }

    /// A one-time warning when the Mac switches to battery while runs are working.
    public static func batteryWarning(_ settings: NativeSettings.Power, onBattery: Bool, live: [RunSummary]) -> String? {
        if !settings.warnOnBattery || !onBattery { return nil }
        let n = live.filter(RunLogic.isActive).count
        if n == 0 { return nil }
        return "\(n) run\(n == 1 ? " is" : "s are") still working. Each run is a virtual machine, so expect faster battery drain."
    }

    /// Whether quitting should ask first.
    public static func shouldConfirmQuit(_ settings: NativeSettings.Power, stackRunning: Bool, hasActiveRuns: Bool) -> Bool {
        settings.confirmQuitWithActiveRuns && stackRunning && hasActiveRuns
    }
}
