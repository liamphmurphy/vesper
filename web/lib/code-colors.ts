// Shiki's theme colours, re-hued onto the palette's chart colours so code matches the rest of the
// app. Kept free of React so the native markdown fixtures (scripts/markdown-fixtures.mjs) check
// the Mac app's port against it.

import type { VizPalette } from "./chat-svg.ts";
import { hexToHsl } from "./persona-ui.ts";

/** The palette colour for a token Shiki coloured `source` ("#RRGGBB"); greys become ink or muted. */
export function tokenColor(source: unknown, palette: VizPalette): string {
  if (typeof source !== "string" || !/^#[\da-f]{6}$/i.test(source)) return palette.ink;
  const { h, s, l } = hexToHsl(source);
  if (s < 0.2) return l < 0.65 ? palette.muted : palette.ink;
  const slot = h < 15 || h >= 345 ? 7 : h < 45 ? 1 : h < 75 ? 3 : h < 160 ? 2 : h < 195 ? 5 : h < 255 ? 0 : h < 290 ? 6 : 4;
  return palette.series[slot];
}
