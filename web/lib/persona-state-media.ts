// Picking which photorealistic state loop to play (LAZYAGENTS-311/312). The
// server stores one transparent Animated WebP per state; the clients drive
// them from the same CharacterState the SVG characters use.
import type { CharacterState } from "./persona-character.ts";

/** The playback summary a Persona carries (Schemas["PersonaStateMediaSummary"]). */
export type StateMediaSummary = { loops: Record<string, string>; head_url?: string; generating: boolean };

/** Loop states in display order, as the API names them. */
export const LOOP_STATES = ["idle", "thinking", "reading", "coding", "creating", "needs_you", "talking", "complete"] as const;
export type LoopState = (typeof LOOP_STATES)[number];

/**
 * What a persona's companion acts out: a character state, talking while a new reply is
 * revealed, or complete for a moment after a turn that did work delivers it. SVG characters
 * have neither pose, so only loops use them.
 */
export type CompanionState = CharacterState | "talking" | "complete";

/** The loop a character state wants: static is the idle pose, and generic work is coding. */
export function loopStateFor(state: CompanionState): LoopState {
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
export function loopFor(summary: StateMediaSummary | undefined, state: CompanionState): { state: LoopState; url: string } | undefined {
  const loops = summary?.loops;
  if (!loops) return undefined;
  const want = loopStateFor(state);
  const order: LoopState[] = [want];
  if (want !== "idle" && want !== "needs_you" && want !== "thinking" && want !== "talking" && want !== "complete") order.push("thinking");
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

/** A persona's reveal pace (Schemas["PersonaRevealPace"]). */
export type RevealPace = "auto" | "off" | "relaxed" | "natural" | "deliberate";

const WORDS_PER_SECOND: Record<Exclude<RevealPace, "auto" | "off">, number> = { relaxed: 25, natural: 15, deliberate: 8 };

/**
 * Words a second a new reply is revealed at; 0 shows it at once. auto paces only a persona
 * that has a talking loop to play meanwhile, so everyone else keeps instant replies.
 */
export function revealWordsPerSecond(pace: RevealPace | undefined, summary: StateMediaSummary | undefined): number {
  switch (pace ?? "auto") {
    case "off":
      return 0;
    case "auto":
      return summary?.loops.talking ? WORDS_PER_SECOND.natural : 0;
    default:
      return WORDS_PER_SECOND[pace as keyof typeof WORDS_PER_SECOND];
  }
}

/**
 * The part of a reply shown `elapsedMs` into its reveal, cut after whole words (and the space
 * that follows them), so text never stops mid-word. done is true once it's all shown.
 */
export function revealSlice(text: string, elapsedMs: number, wordsPerSecond: number): { text: string; done: boolean } {
  if (wordsPerSecond <= 0) return { text, done: true };
  const words = Math.max(0, Math.floor((elapsedMs / 1000) * wordsPerSecond));
  const re = /\S+\s*/g;
  let end = 0;
  for (let n = 0; n < words; n++) {
    const m = re.exec(text);
    if (!m) return { text, done: true };
    end = m.index + m[0].length;
  }
  if (end >= text.trimEnd().length) return { text, done: true };
  return { text: text.slice(0, end), done: false };
}
