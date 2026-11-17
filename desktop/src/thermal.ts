/**
 * Easing off when the Mac is hot or in Low Power Mode: fewer runs at once,
 * through the runner's temporary slot limit (PUT /runner/slot-limit).
 */

export type ThermalState = "unknown" | "nominal" | "fair" | "serious" | "critical";

export interface ThermalInput {
  enabled: boolean;
  thermal: ThermalState;
  lowPowerMode: boolean;
  /** The runner's own max_concurrent. */
  maxSlots: number;
}

/**
 * The slot limit to ask for, or null for none. critical: one run at a time.
 * serious, or Low Power Mode: half the slots (at least one). fair and below:
 * no cap; macOS calls "fair" normal operation with some fan.
 */
export function desiredSlotLimit(input: ThermalInput): number | null {
  if (!input.enabled || !Number.isInteger(input.maxSlots) || input.maxSlots < 1) return null;
  const half = Math.max(1, Math.floor(input.maxSlots / 2));
  if (input.thermal === "critical") return 1;
  if (input.thermal === "serious" || input.lowPowerMode) return half < input.maxSlots ? half : null;
  return null;
}

/** Reads `pmset -g`: a line "lowpowermode 1" means Low Power Mode is on. */
export function parseLowPowerMode(pmsetOutput: string): boolean {
  return /^\s*lowpowermode\s+1\s*$/m.test(pmsetOutput);
}

export function isThermalState(value: unknown): value is ThermalState {
  return value === "unknown" || value === "nominal" || value === "fair" || value === "serious" || value === "critical";
}

/** The tray line while a cap is on, or null. */
export function easingOffLabel(limit: number | null, thermal: ThermalState, lowPowerMode: boolean): string | null {
  if (limit === null) return null;
  const why = thermal === "critical" || thermal === "serious" ? "Mac is hot" : lowPowerMode ? "Low Power Mode" : "easing off";
  return `${why}: ${limit} run${limit === 1 ? "" : "s"} at a time`;
}
