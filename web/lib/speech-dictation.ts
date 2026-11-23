// Pure helpers for push-to-talk and toggle dictation in the web chat composer.
// Kept free of React so `npm run test:unit` covers it.

export const HOLD_THRESHOLD_MS = 280;

/**
 * Stitches a live dictated transcript onto the draft text captured when dictation
 * started, adding a space separator only when needed.
 */
export function stitchDictation(baseDraft: string, spoken: string): string {
  const clean = spoken.trim();
  if (!clean) return baseDraft;
  if (!baseDraft) return clean;
  const needsSpace = !/\s$/.test(baseDraft);
  return `${baseDraft}${needsSpace ? " " : ""}${clean}`;
}

/**
 * Decides what pointer-up does after a mic press:
 * - Held >= HOLD_THRESHOLD_MS: push-to-talk finishes on release.
 * - Quick tap while already listening before press: stops hands-free listening.
 * - Quick tap when idle: stays listening in hands-free toggle mode.
 */
export function resolveMicRelease(opts: {
  elapsedMs: number;
  wasListeningBeforePress: boolean;
}): "stop" | "keep-listening" {
  if (opts.wasListeningBeforePress) return "stop";
  return opts.elapsedMs >= HOLD_THRESHOLD_MS ? "stop" : "keep-listening";
}
