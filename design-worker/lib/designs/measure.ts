// Text measurement for Designs (ADR-designs §2.3): plain arithmetic over the
// generated Inter advance widths, so the editor and the server lay text out
// identically without a canvas. Renderers draw with kerning off to match.
import metrics from "./inter-metrics.json" with { type: "json" };
import type { FaceMetrics } from "./inter-metrics-gen.ts";

export type Weight = 400 | 500 | 600 | 700;
const FACES = metrics as Record<string, FaceMetrics>;

export const face = (weight: number, italic?: boolean): FaceMetrics => FACES[`${weight}${italic ? "i" : ""}`] ?? FACES["400"];

/** Width in design px of text in Inter at a weight and size. */
export function measure(text: string, weight: number, italic: boolean | undefined, size: number): number {
  const f = face(weight, italic);
  let w = 0;
  for (const ch of text) w += f.adv[ch.codePointAt(0)!] ?? f.missing;
  return w * size;
}

/** True when a character has no Inter glyph in the table (emoji, CJK…): the editor warns about it. */
export const unsupported = (text: string) => {
  const f = FACES["400"];
  for (const ch of text) if (ch !== "\n" && f.adv[ch.codePointAt(0)!] === undefined) return true;
  return false;
};

/** The family name the renderers draw with; registered from public/fonts/designs. */
export const FAMILY = "Vesper Designs Inter";
const FILE: Record<string, string> = { "400": "Regular", "500": "Medium", "600": "SemiBold", "700": "Bold" };
export const fontUrl = (weight: number, italic: boolean, kind: "woff2" | "ttf" = "woff2") => {
  const base = FILE[String(weight)] ?? "Regular";
  const name = italic ? (base === "Regular" ? "Italic" : `${base}Italic`) : base;
  return `/fonts/designs/Inter-${name}.${kind}`;
};
