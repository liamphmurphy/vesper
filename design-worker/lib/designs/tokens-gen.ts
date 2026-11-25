// Builds the Dusk token snapshot (ADR-designs §3.5) from web/styles/tokens.css:
// the :root block becomes `dark`, the :root[data-theme="light"] overrides
// become `light`. Colours are normalised to upper-case #RRGGBB(AA), px
// dimensions are kept, and fonts, shadows and composite values are skipped.
// The Tailwind colour names come from app/globals.css's @theme block, so
// Inspect can say `bg-surface` rather than `bg-[var(--surface)]`.
// Pure: the caller reads the files and hashes tokens.css.
import type { Token } from "./schema.ts";

export const TOKENS_SOURCE = "web/styles/tokens.css";

export type Snapshot = {
  source: string;
  hash: string;
  modes: { dark: Record<string, Token>; light: Record<string, Token> };
  /** CSS variable name → Tailwind colour name (bg-<name>, text-<name>, border-<name>). */
  tailwind: Record<string, string>;
};

function block(css: string, selector: string): string {
  const i = css.indexOf(selector);
  if (i < 0) throw new Error(`no ${selector} block`);
  let depth = 0;
  const start = css.indexOf("{", i);
  for (let j = start; j < css.length; j++) {
    if (css[j] === "{") depth++;
    if (css[j] === "}" && --depth === 0) return css.slice(start + 1, j);
  }
  throw new Error(`unclosed ${selector}`);
}

/** #RGB, #RRGGBB(AA) and rgb()/rgba() become upper-case #RRGGBB or #RRGGBBAA. */
export function hexColor(v: string): string {
  const m = v.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/i);
  if (m) {
    const h = (n: number) => Math.round(n).toString(16).padStart(2, "0");
    return ("#" + h(+m[1]) + h(+m[2]) + h(+m[3]) + (m[4] === undefined || +m[4] === 1 ? "" : h(+m[4] * 255))).toUpperCase();
  }
  if (/^#[0-9a-f]{3}$/i.test(v)) return ("#" + [...v.slice(1)].map((c) => c + c).join("")).toUpperCase();
  return v.toUpperCase();
}

function vars(body: string): Record<string, Token> {
  const out: Record<string, Token> = {};
  for (const m of body.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/--([a-z0-9-]+)\s*:\s*([^;]+);/gi)) {
    const value = m[2].trim();
    if (/^#[0-9a-f]{3,8}$/i.test(value) || /^rgba?\(/i.test(value)) out[m[1]] = { kind: "color", value: hexColor(value) };
    else if (/^-?\d+(\.\d+)?px$/.test(value)) out[m[1]] = { kind: "dimension", value };
  }
  return out;
}

/** `--color-<name>: var(--<token>)` pairs in the @theme block. */
export function tailwindColors(globalsCss: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of block(globalsCss, "@theme").matchAll(/--color-([a-z0-9-]+)\s*:\s*var\(--([a-z0-9-]+)\)\s*;/gi)) out[m[2]] ??= m[1];
  return out;
}

export function buildSnapshot(tokensCss: string, sha256Hex: string, globalsCss: string): Snapshot {
  return {
    source: TOKENS_SOURCE,
    hash: "sha256:" + sha256Hex,
    modes: { dark: vars(block(tokensCss, ":root {")), light: vars(block(tokensCss, ':root[data-theme="light"]')) },
    tailwind: tailwindColors(globalsCss),
  };
}
