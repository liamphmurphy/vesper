import { isActive, pausableRuns, type RunSummary } from "./runs";

/**
 * Power and lifecycle decisions (LAZYAGENTS-245). See docs/dev/desktop-power.md
 * for what Virtualization.framework does across sleep and why these are the
 * defaults.
 */

export interface PowerSettings {
  preventSleepWhileRunning: boolean;
  onSleep: "keep" | "pause";
  warnOnBattery: boolean;
  confirmQuitWithActiveRuns: boolean;
}

/**
 * Whether to hold a power-save blocker. Only while a run is actually working
 * (starting, running, or the server checking a delegated result); a run
 * waiting on the person, on quota or paused shouldn't keep the Mac awake.
 */
export function wantsSleepBlocker(settings: PowerSettings, live: readonly RunSummary[]): boolean {
  return settings.preventSleepWhileRunning && live.some(isActive);
}

/** Runs to pause when the Mac is about to sleep, under the "pause" policy. */
export function runsToPauseOnSleep(settings: PowerSettings, live: readonly RunSummary[]): RunSummary[] {
  return settings.onSleep === "pause" ? pausableRuns(live) : [];
}

/**
 * Runs to resume after wake (or from the tray's Resume): only those Vesper
 * paused itself and that are still paused. A run the person paused by hand,
 * or that has since been resumed or cancelled, is left alone.
 */
export function runsToResume(pausedByVesper: ReadonlySet<string>, live: readonly RunSummary[]): string[] {
  return live.filter((r) => pausedByVesper.has(r.id) && r.state === "paused").map((r) => r.id);
}

/** Drops ids that are no longer paused, so the set doesn't grow forever. */
export function prunePausedSet(pausedByVesper: Set<string>, live: readonly RunSummary[]): void {
  const stillPaused = new Set(live.filter((r) => r.state === "paused").map((r) => r.id));
  for (const id of [...pausedByVesper]) if (!stillPaused.has(id)) pausedByVesper.delete(id);
}

/** A one-time warning when the Mac switches to battery while runs are working. */
export function batteryWarning(settings: PowerSettings, onBattery: boolean, live: readonly RunSummary[]): string | null {
  if (!settings.warnOnBattery || !onBattery) return null;
  const n = live.filter(isActive).length;
  if (n === 0) return null;
  return `${n} run${n === 1 ? " is" : "s are"} still working. Each run is a virtual machine, so expect faster battery drain.`;
}

/** Whether quitting should ask first. */
export function shouldConfirmQuit(settings: PowerSettings, stackRunning: boolean, hasActiveRuns: boolean): boolean {
  return settings.confirmQuitWithActiveRuns && stackRunning && hasActiveRuns;
}
