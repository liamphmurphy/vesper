// Picking which photorealistic state loop to play (LAZYAGENTS-311/312). The
// server stores one transparent Animated WebP per state; the clients drive
// them from the same CharacterState the SVG characters use.
import type { CharacterState } from "./persona-character.ts";

/** The playback summary a Persona carries (Schemas["PersonaStateMediaSummary"]). */
export type StateMediaSummary = { loops: Record<string, string>; head_url?: string; generating: boolean };

/** Loop states in display order, as the API names them. */
export const LOOP_STATES = ["idle", "thinking", "reading", "coding", "creating", "needs_you"] as const;
export type LoopState = (typeof LOOP_STATES)[number];

/** The loop a character state wants: static is the idle pose, and generic work is coding. */
export function loopStateFor(state: CharacterState): LoopState {
  switch (state) {
    case "static":
      return "idle";
    case "working":
      return "coding";
    default:
      return state;
  }
}

/**
 * The loop URL to play for a state: its own loop, else thinking for any work
 * state that has none, else idle, else whichever exists. Undefined when the
 * persona has no loops, so callers fall back to its picture or character.
 */
export function loopFor(summary: StateMediaSummary | undefined, state: CharacterState): { state: LoopState; url: string } | undefined {
  const loops = summary?.loops;
  if (!loops) return undefined;
  const want = loopStateFor(state);
  const order: LoopState[] = [want];
  if (want !== "idle" && want !== "needs_you" && want !== "thinking") order.push("thinking");
  order.push("idle", ...LOOP_STATES);
  for (const s of order) {
    const url = loops[s];
    if (url) return { state: s, url };
  }
  return undefined;
}

/** Whether a persona has any loop to play. */
export function hasLoops(summary: StateMediaSummary | undefined): boolean {
  return !!summary && Object.values(summary.loops).some(Boolean);
}
