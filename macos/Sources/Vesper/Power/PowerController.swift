import AppKit
import IOKit.ps
import VesperCore

/// Power and thermal handling (desktop/src/power.ts, thermal.ts and the power parts of native.ts):
/// keep the Mac awake while runs work, pause on sleep and resume on wake, warn once per battery
/// session, and ease off (fewer runner slots) when the Mac is hot or in Low Power Mode.
@MainActor
final class PowerController {
    struct Hooks {
        var settings: () -> NativeSettings.Power
        var liveRuns: () -> [RunSummary]
        var client: () -> APIClient?
        var pause: ([RunSummary]) async -> Void
        var resume: () async -> Void
        var refreshRuns: () async -> Void
        var notice: (_ title: String, _ body: String) -> Void
        /// The easing-off line changed (the menu bar shows it).
        var noticeChanged: () -> Void
    }

    private let hooks: Hooks
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var thermalTimer: Timer?
    private var onBattery = false
    private var batteryWarned = false
    private var applying = false
    /// The runner's slot cap as the server last reported it, nil for none.
    private(set) var slotLimit: Int?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    var easingOffNotice: String? {
        Thermal.easingOffLabel(limit: slotLimit, thermal: Self.thermalState(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    // MARK: Lifecycle

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyThermal() }
            })
        }
        startPowerSourceWatch()
        // A restarted runner comes back uncapped: look again now and then, as the health poll did.
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThermal() }
        }
    }

    // MARK: Sleep blocker

    /// Called with each runs snapshot and when settings change.
    func update() {
        if PowerLogic.wantsSleepBlocker(hooks.settings(), live: hooks.liveRuns()) {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Vesper runs are working")
            }
        } else if let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
        evaluateBattery()
    }

    var isHoldingSleepBlocker: Bool { activity != nil }

    // MARK: Sleep / wake

    private func willSleep() {
        let runs = PowerLogic.runsToPauseOnSleep(hooks.settings(), live: hooks.liveRuns())
        guard !runs.isEmpty else { return }
        Task { await hooks.pause(runs) }
    }

    private func didWake() {
        Task {
            if hooks.settings().onSleep == .pause { await hooks.resume() }
            await hooks.refreshRuns()
        }
        applyThermal()
    }

    // MARK: Battery

    private func startPowerSourceWatch() {
        onBattery = Self.isOnBattery()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let controller = Unmanaged<PowerController>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { controller.powerSourceChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    private func powerSourceChanged() {
        let now = Self.isOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        if !now { batteryWarned = false }
        evaluateBattery()
        applyThermal()
    }

    /// Once per battery session, while runs are working (also when they start after the switch).
    private func evaluateBattery() {
        guard onBattery, !batteryWarned,
              let message = PowerLogic.batteryWarning(hooks.settings(), onBattery: true, live: hooks.liveRuns()) else { return }
        batteryWarned = true
        hooks.notice("Running on battery", message)
    }

    // MARK: Thermal

    static func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    /// Asks the runner for fewer slots while hot or in Low Power Mode, and lifts the cap after.
    func applyThermal() {
        guard !applying, let client = hooks.client() else { return }
        applying = true
        Task {
            defer { applying = false }
            guard let status: RunnerStatus = try? await client.get("/api/v1/runner", timeout: 4),
                  let runner = status.runners?.first, let max = runner.maxConcurrent, max >= 1 else { return }
            let desired = Thermal.desiredSlotLimit(ThermalInput(
                enabled: hooks.settings().easeOffWhenHot, thermal: Self.thermalState(),
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, maxSlots: max))
            var current = runner.slotLimit
            if desired != current {
                do {
                    try await client.setSlotLimit(desired)
                    current = desired
                } catch {
                    vlog("slot limit not applied: \(error)")
                }
            }
            if current != slotLimit {
                slotLimit = current
                hooks.noticeChanged()
            }
        }
    }

    func reset() {
        slotLimit = nil
    }
}
