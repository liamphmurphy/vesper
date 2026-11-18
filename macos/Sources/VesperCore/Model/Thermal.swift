import Foundation

// Port of desktop/src/thermal.ts. Easing off when the Mac is hot or in Low Power Mode: fewer runs
// at once, through the runner's temporary slot limit (PUT /api/v1/runner/slot-limit).

public enum ThermalState: String, Sendable, Codable { case unknown, nominal, fair, serious, critical }

public struct ThermalInput: Sendable {
    public var enabled: Bool
    public var thermal: ThermalState
    public var lowPowerMode: Bool
    /// The runner's own max_concurrent.
    public var maxSlots: Int
    public init(enabled: Bool, thermal: ThermalState, lowPowerMode: Bool, maxSlots: Int) {
        self.enabled = enabled
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.maxSlots = maxSlots
    }
}

public enum Thermal {
    /// The slot limit to ask for, or nil for none. critical: one run. serious or Low Power Mode:
    /// half the slots (at least one). fair and below: no cap.
    public static func desiredSlotLimit(_ input: ThermalInput) -> Int? {
        if !input.enabled || input.maxSlots < 1 { return nil }
        let half = max(1, input.maxSlots / 2)
        if input.thermal == .critical { return 1 }
        if input.thermal == .serious || input.lowPowerMode { return half < input.maxSlots ? half : nil }
        return nil
    }

    /// Reads `pmset -g`: a line "lowpowermode 1" means Low Power Mode is on.
    public static func parseLowPowerMode(_ pmsetOutput: String) -> Bool {
        pmsetOutput.range(of: #"(?m)^\s*lowpowermode\s+1\s*$"#, options: .regularExpression) != nil
    }

    /// The tray line while a cap is on, or nil.
    public static func easingOffLabel(limit: Int?, thermal: ThermalState, lowPowerMode: Bool) -> String? {
        guard let limit else { return nil }
        let why = (thermal == .critical || thermal == .serious) ? "Mac is hot" : lowPowerMode ? "Low Power Mode" : "easing off"
        return "\(why): \(limit) run\(limit == 1 ? "" : "s") at a time"
    }
}
