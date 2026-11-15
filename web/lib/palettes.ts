import { DUSK } from "./palette-defaults.ts";

export type ColorMode = "dark" | "light";
export type ThemePref = ColorMode | "system";
export type Tokens = Record<string, string>;
type Seed = readonly [bg: string, surface: string, text: string, accent: string, blue: string, orange: string, green: string, yellow: string, pink: string, cyan: string, purple: string, red: string];
export type Palette = { id: string; name: string; description: string; source?: string; dark: Tokens; light: Tokens };

export function mix(a: string, b: string, weight: number): string {
  return "#" + [1, 3, 5].map((i) => Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - weight) + parseInt(b.slice(i, i + 2), 16) * weight).toString(16).padStart(2, "0")).join("");
}

function luminance(hex: string): number {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((n) => n <= 0.04045 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4);
  return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
}

export function contrast(a: string, b: string): number {
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/** Keep a hue, nudging toward black/white until small text is readable. */
export function readable(color: string, backgrounds: readonly string[], minimum = 4.5): string {
  const target = contrast("#ffffff", backgrounds[0]) > contrast("#000000", backgrounds[0]) ? "#ffffff" : "#000000";
  for (let i = 0; i <= 100; i++) {
    const candidate = mix(color, target, i / 100);
    if (backgrounds.every((bg) => contrast(candidate, bg) >= minimum)) return candidate;
  }
  return target;
}

function tokens(seed: Seed, mode: ColorMode): Tokens {
  const [bg, surface, text, accent, ...series] = seed;
  const dark = mode === "dark";
  const t: Tokens = { ...DUSK[mode] };
  const raised = mix(surface, text, dark ? 0.035 : 0);
  const grounds = [bg, surface, raised];
  Object.assign(t, {
    bg, "bg-sidebar": mix(bg, surface, 0.6), "bg-panel": mix(bg, surface, 0.35), surface,
    "surface-raised": raised, "surface-sunken": mix(bg, surface, 0.4),
    hover: mix(surface, text, 0.065), selected: mix(surface, accent, 0.14),
    border: mix(surface, text, 0.13), "border-subtle": mix(surface, text, 0.09),
    "border-row": mix(surface, text, 0.055), "border-strong": mix(surface, text, 0.22),
    track: mix(surface, text, 0.14), text: readable(text, grounds),
    "text-2": readable(mix(text, bg, 0.12), grounds),
    "text-secondary": readable(mix(text, bg, 0.28), grounds),
    "text-tertiary": readable(mix(text, bg, 0.42), grounds),
    accent: readable(accent, grounds, 3), "accent-soft": accent + "26",
    "brand-deep": mix(bg, series[6], 0.35), "brand-violet": series[6], "brand-star": series[1],
    "human-avatar-bg": mix(surface, text, 0.12),
  });
  t["text-on-accent"] = readable(bg, [t.accent]);
  const states: Record<string, string> = { backlog: t["text-tertiary"], todo: t["text-secondary"], progress: series[3], review: series[0], done: series[2], human: series[1], blocked: series[7] };
  for (const [state, color] of Object.entries(states)) t[`state-${state}`] = readable(color, grounds);
  for (const state of ["human", "blocked", "review", "done", "neutral"]) {
    const color = state === "neutral" ? t["text-secondary"] : t[`state-${state}`];
    t[`pill-${state}-bg`] = mix(surface, color, 0.12);
    t[`pill-${state}-fg`] = readable(color, [t[`pill-${state}-bg`]]);
  }
  ["atlas", "quill", "sentry", "juno", "nova", "relay", "pike", "echo"].forEach((name, i) => {
    const color = series[[6, 5, 4, 0, 3, 2, 1, 7][i]];
    t[`agent-${name}-bg`] = mix(surface, color, 0.14);
    t[`agent-${name}`] = readable(color, [t[`agent-${name}-bg`]]);
  });
  ["prd", "spec", "adr", "report", "design", "mockup", "note"].forEach((name, i) => {
    const color = series[[6, 0, 3, 2, 4, 5, 6][i]];
    t[`doc-${name}-bg`] = mix(surface, color, 0.12);
    t[`doc-${name}`] = readable(color, [t[`doc-${name}-bg`]]);
  });
  Object.assign(t, {
    "priority-urgent": t["state-human"], "row-hover": t.hover, "border-hover": t["border-strong"],
    "border-float": t["border-strong"], "kbd-border": t["border-strong"],
    "btn-secondary-bg": surface, "btn-secondary-border": t["border-strong"], "btn-outline-bg": surface,
    "approve-fg": readable(bg, [t["state-human"]]), "segment-on": t.selected, "command-on": t.selected,
    "search-bg": surface, "priority-unlit": t.border, unassigned: t["text-tertiary"],
    scrim: bg + "b3", "shadow-float": `0 16px 40px ${bg}${dark ? "cc" : "26"}`,
    "viz-surface": surface, "viz-panel": raised, "viz-ink": t.text, "viz-muted": t["text-secondary"],
    "viz-line": mix(surface, text, 0.4), "viz-grid": t.border,
  });
  const used = new Set<string>();
  series.forEach((color, i) => {
    let resolved = readable(color, grounds);
    // Smaller source palettes reuse hues; distinguish those chart slots with
    // a neighboring palette hue rather than drawing identical series.
    for (let step = 1; used.has(resolved) && step <= 10; step++) {
      resolved = readable(mix(color, series[(i + 1) % series.length], step / 12), grounds);
    }
    used.add(resolved);
    t[`viz-${i + 1}`] = resolved;
  });
  return t;
}

function preset(id: string, name: string, description: string, source: string | undefined, dark: Seed, light: Seed): Palette {
  return { id, name, description, ...(source ? { source } : {}), dark: tokens(dark, "dark"), light: tokens(light, "light") };
}

// Adaptations for Vesper: secondary surfaces and contrast are derived, not exact editor ports.
export const PALETTES: readonly Palette[] = [
  preset("neutral", "Neutral", "Balanced grays · Vesper default", undefined,
    ["#18181b", "#222226", "#f4f4f5", "#9b8cff", "#60a5fa", "#fb923c", "#4ade80", "#facc15", "#f472b6", "#22d3ee", "#a78bfa", "#f87171"],
    ["#f5f5f7", "#ffffff", "#18181b", "#5b4bd6", "#2563eb", "#ea580c", "#16a34a", "#ca8a04", "#db2777", "#0891b2", "#7c3aed", "#dc2626"]),
  { id: "dusk", name: "Dusk", description: "Vesper’s original violet", ...DUSK },
  preset("catppuccin", "Catppuccin", "Soft pastel · Mocha / Latte", "https://catppuccin.com/palette/?flavor=latte",
    ["#1e1e2e", "#313244", "#cdd6f4", "#cba6f7", "#89b4fa", "#fab387", "#a6e3a1", "#f9e2af", "#f5c2e7", "#94e2d5", "#cba6f7", "#f38ba8"],
    ["#eff1f5", "#ffffff", "#4c4f69", "#8839ef", "#1e66f5", "#fe640b", "#40a02b", "#df8e1d", "#ea76cb", "#179299", "#8839ef", "#d20f39"]),
  preset("nord", "Nord", "Cool arctic blues", "https://www.nordtheme.com/",
    ["#2e3440", "#3b4252", "#eceff4", "#88c0d0", "#81a1c1", "#d08770", "#a3be8c", "#ebcb8b", "#b48ead", "#8fbcbb", "#b48ead", "#bf616a"],
    ["#eceff4", "#e5e9f0", "#2e3440", "#5e81ac", "#5e81ac", "#d08770", "#a3be8c", "#ebcb8b", "#b48ead", "#8fbcbb", "#b48ead", "#bf616a"]),
  preset("dracula", "Dracula", "Purple nights · Alucard-inspired light", "https://draculatheme.com/contribute",
    ["#282a36", "#343746", "#f8f8f2", "#bd93f9", "#8be9fd", "#ffb86c", "#50fa7b", "#f1fa8c", "#ff79c6", "#8be9fd", "#bd93f9", "#ff5555"],
    ["#fffbeb", "#ffffff", "#1f1f1f", "#644ac9", "#036a96", "#a34d14", "#14710a", "#846e15", "#a3144d", "#036a96", "#644ac9", "#cb3a2a"]),
  preset("gruvbox", "Gruvbox", "Warm retro earth tones", "https://github.com/morhetz/gruvbox",
    ["#282828", "#3c3836", "#ebdbb2", "#fabd2f", "#83a598", "#fe8019", "#b8bb26", "#fabd2f", "#d3869b", "#8ec07c", "#d3869b", "#fb4934"],
    ["#fbf1c7", "#f2e5bc", "#3c3836", "#af3a03", "#076678", "#af3a03", "#79740e", "#b57614", "#8f3f71", "#427b58", "#8f3f71", "#9d0006"]),
  preset("solarized", "Solarized", "Balanced blue and cream", "https://ethanschoonover.com/solarized/",
    ["#002b36", "#073642", "#fdf6e3", "#2aa198", "#268bd2", "#cb4b16", "#859900", "#b58900", "#d33682", "#2aa198", "#6c71c4", "#dc322f"],
    ["#fdf6e3", "#eee8d5", "#073642", "#268bd2", "#268bd2", "#cb4b16", "#859900", "#b58900", "#d33682", "#2aa198", "#6c71c4", "#dc322f"]),
  preset("rose-pine", "Rosé Pine", "Muted rose · Main / Dawn", "https://rosepinetheme.com/palette/",
    ["#191724", "#1f1d2e", "#e0def4", "#c4a7e7", "#9ccfd8", "#ebbcba", "#31748f", "#f6c177", "#eb6f92", "#9ccfd8", "#c4a7e7", "#eb6f92"],
    ["#faf4ed", "#fffaf3", "#575279", "#907aa9", "#56949f", "#d7827e", "#286983", "#ea9d34", "#b4637a", "#56949f", "#907aa9", "#b4637a"]),
  preset("tokyo-night", "Tokyo Night", "City blues · Night / Day", "https://github.com/folke/tokyonight.nvim",
    ["#1a1b26", "#24283b", "#c0caf5", "#7aa2f7", "#7aa2f7", "#ff9e64", "#9ece6a", "#e0af68", "#bb9af7", "#7dcfff", "#bb9af7", "#f7768e"],
    ["#e1e2e7", "#e9e9ed", "#3760bf", "#2e7de9", "#2e7de9", "#b15c00", "#587539", "#8c6c3e", "#9854f1", "#007197", "#9854f1", "#f52a65"]),
  preset("everforest", "Everforest", "Soft forest greens", "https://github.com/sainnhe/everforest/blob/master/README.md",
    ["#2d353b", "#343f44", "#d3c6aa", "#a7c080", "#7fbbb3", "#e69875", "#a7c080", "#dbbc7f", "#d699b6", "#83c092", "#d699b6", "#e67e80"],
    ["#fdf6e3", "#f4f0d9", "#5c6a72", "#8da101", "#3a94c5", "#f57d26", "#8da101", "#dfa000", "#df69ba", "#35a77c", "#df69ba", "#f85552"]),
  preset("ayu", "Ayu", "Clean neutrals and amber", "https://github.com/ayu-theme/ayu-colors",
    ["#0b0e14", "#131721", "#bfbdb6", "#e6b450", "#59c2ff", "#ff8f40", "#aad94c", "#e6b450", "#d2a6ff", "#95e6cb", "#d2a6ff", "#f07178"],
    ["#fafafa", "#ffffff", "#5c6166", "#ff9940", "#399ee6", "#fa8d3e", "#86b300", "#f2ae49", "#a37acc", "#4cbf99", "#a37acc", "#f07171"]),
  preset("flexoki", "Flexoki", "Printing inks on warm paper", "https://github.com/kepano/flexoki",
    ["#100f0f", "#1c1b1a", "#cecdc3", "#da702c", "#4385be", "#da702c", "#879a39", "#d0a215", "#ce5d97", "#3aa99f", "#8b7ec8", "#d14d41"],
    ["#fffcf0", "#f2f0e5", "#100f0f", "#bc5215", "#205ea6", "#bc5215", "#66800b", "#ad8301", "#a02f6f", "#24837b", "#5e409d", "#af3029"]),
  preset("github", "GitHub", "Crisp neutral · Dark / Light Default", "https://primer.style/primitives",
    ["#0d1117", "#161b22", "#e6edf3", "#58a6ff", "#58a6ff", "#f0883e", "#3fb950", "#d29922", "#f778ba", "#39c5cf", "#bc8cff", "#f85149"],
    ["#f6f8fa", "#ffffff", "#1f2328", "#0969da", "#0969da", "#bc4c00", "#1a7f37", "#9a6700", "#bf3989", "#1b7c83", "#8250df", "#cf222e"]),
  preset("one", "One", "Balanced slate · One Dark / Light", "https://github.com/atom/one-dark-ui",
    ["#21252b", "#282c34", "#abb2bf", "#61afef", "#61afef", "#d19a66", "#98c379", "#e5c07b", "#c678dd", "#56b6c2", "#c678dd", "#e06c75"],
    ["#f0f0f3", "#ffffff", "#383a42", "#4078f2", "#4078f2", "#c18401", "#50a14f", "#986801", "#a626a4", "#0184bc", "#a626a4", "#e45649"]),
  preset("kanagawa", "Kanagawa", "Ink and parchment · Wave / Lotus", "https://github.com/rebelot/kanagawa.nvim",
    ["#1f1f28", "#2a2a37", "#dcd7ba", "#7e9cd8", "#7e9cd8", "#ffa066", "#76946a", "#dca561", "#d27e99", "#7aa89f", "#957fb8", "#e46876"],
    ["#f2ecbc", "#f7f3d4", "#545464", "#4d699b", "#4d699b", "#cc6d00", "#6f894e", "#77713f", "#b35b79", "#597b75", "#624c83", "#c84053"]),
  preset("monokai-pro", "Monokai Pro", "Warm charcoal and vivid accents", "https://monokai.pro/",
    ["#2d2a2e", "#383539", "#fcfcfa", "#ffd866", "#78dce8", "#fc9867", "#a9dc76", "#ffd866", "#ff6188", "#78dce8", "#ab9df2", "#ff6188"],
    ["#faf4f2", "#ffffff", "#29242a", "#e16032", "#1c8ca8", "#e16032", "#569c31", "#b58900", "#d6336c", "#1c8ca8", "#7a5af5", "#d6336c"]),
  preset("high-contrast", "High Contrast", "Maximum contrast · Dark / Light", undefined,
    ["#000000", "#141416", "#ffffff", "#6cb6ff", "#6cb6ff", "#ffb757", "#56d364", "#f2cc60", "#ff9bce", "#76e3ea", "#d2a8ff", "#ff7b72"],
    ["#f2f2f5", "#ffffff", "#000000", "#0055cc", "#0055cc", "#b34700", "#116329", "#7a5200", "#9e1c64", "#006875", "#5e2ca5", "#b91c1c"]),
];

export const COLOR_KEYS = Object.keys(DUSK.dark).filter((key) => /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test((DUSK.dark as Tokens)[key]));
/** Settings → Text size; each sets --type-scale in styles/tokens.css. */
export const TEXT_SIZES = ["small", "default", "large", "larger"] as const;
export type TextSize = (typeof TEXT_SIZES)[number];
export type Appearance = { version: 1; palette: string; custom: { base: string; dark: Tokens; light: Tokens }; showHarnessActivity?: boolean; textSize?: TextSize };
export const DEFAULT_APPEARANCE: Appearance = { version: 1, palette: "neutral", custom: { base: "neutral", dark: {}, light: {} }, showHarnessActivity: true, textSize: "default" };
export const textSizeOf = (value: unknown): TextSize => TEXT_SIZES.includes(value as TextSize) ? value as TextSize : "default";

/** Only known color tokens and opaque hex enter inline CSS, including imported JSON. */
export function parseAppearance(raw: string | null): Appearance {
  try {
    if (!raw || raw.length > 40_000) return DEFAULT_APPEARANCE;
    const data = JSON.parse(raw);
    if (data?.version !== 1) return DEFAULT_APPEARANCE;
    const known = (id: unknown) => PALETTES.some((p) => p.id === id);
    const clean = (input: unknown): Tokens => Object.fromEntries(COLOR_KEYS.flatMap((key) => {
      const value = input && typeof input === "object" ? (input as Tokens)[key] : undefined;
      return typeof value === "string" && /^#[\da-f]{6}$/i.test(value) ? [[key, value.toLowerCase()]] : [];
    }));
    return { version: 1, palette: data.palette === "custom" || known(data.palette) ? data.palette : DEFAULT_APPEARANCE.palette, custom: { base: known(data.custom?.base) ? data.custom.base : DEFAULT_APPEARANCE.palette, dark: clean(data.custom?.dark), light: clean(data.custom?.light) }, showHarnessActivity: data.showHarnessActivity !== false, textSize: textSizeOf(data.textSize) };
  } catch { return DEFAULT_APPEARANCE; }
}

export function paletteTokens(settings: Appearance, mode: ColorMode): Tokens {
  return resolvePalette(settings, mode, PALETTES);
}

/** Self-contained so the exact same resolver can run in the pre-paint head script. */
export function resolvePalette(settings: Appearance, mode: ColorMode, palettes: readonly Palette[]): Tokens {
  function mix(a: string, b: string, weight: number): string {
    return "#" + [1, 3, 5].map((i) => Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - weight) + parseInt(b.slice(i, i + 2), 16) * weight).toString(16).padStart(2, "0")).join("");
  }
  function luminance(hex: string): number {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((n) => n <= 0.04045 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4);
    return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
  }
  function readable(color: string, backgrounds: readonly string[]): string {
    const contrast = (a: string, b: string) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
    const target = contrast("#ffffff", backgrounds[0]) > contrast("#000000", backgrounds[0]) ? "#ffffff" : "#000000";
    for (let i = 0; i <= 100; i++) {
      const candidate = mix(color, target, i / 100);
      if (backgrounds.every((bg) => contrast(candidate, bg) >= 4.5)) return candidate;
    }
    return target;
  }
  const base = palettes.find((p) => p.id === (settings.palette === "custom" ? settings.custom.base : settings.palette)) ?? palettes[0];
  const t = { ...base[mode] };
  if (settings.palette !== "custom") return t;
  const overrides = settings.custom[mode];
  Object.assign(t, overrides);
  // Re-derive related states when a base color changes; explicit advanced overrides win.
  const derived: Tokens = {
    "accent-soft": t.accent + "26", "row-hover": mix(t.surface, t.text, 0.065),
    hover: mix(t.surface, t.text, 0.065), selected: mix(t.surface, t.accent, 0.14),
    "text-on-accent": readable(t.bg, [t.accent]), "approve-fg": readable(t.bg, [t["state-human"]]),
    "viz-surface": t.surface, "viz-panel": t["surface-raised"], "viz-ink": t.text, "viz-muted": t["text-secondary"], "viz-grid": t.border,
    "btn-secondary-bg": t.surface, "btn-outline-bg": t.surface, "search-bg": t.surface,
  };
  derived["segment-on"] = derived.selected;
  derived["command-on"] = derived.selected;
  for (const state of ["human", "blocked", "review", "done", "neutral"]) {
    const color = state === "neutral" ? t["text-secondary"] : t[`state-${state}`];
    derived[`pill-${state}-bg`] = mix(t.surface, color, 0.12);
    derived[`pill-${state}-fg`] = readable(color, [overrides[`pill-${state}-bg`] ?? derived[`pill-${state}-bg`]]);
  }
  const dependencies: Record<string, string[]> = {
    "accent-soft": ["accent"], "row-hover": ["surface", "text"], hover: ["surface", "text"],
    selected: ["surface", "accent"], "segment-on": ["surface", "accent", "selected"], "command-on": ["surface", "accent", "selected"],
    "text-on-accent": ["bg", "accent"], "approve-fg": ["bg", "state-human"],
    "viz-surface": ["surface"], "viz-panel": ["surface-raised"], "viz-ink": ["text"],
    "viz-muted": ["text-secondary"], "viz-grid": ["border"], "btn-secondary-bg": ["surface"],
    "btn-outline-bg": ["surface"], "search-bg": ["surface"],
  };
  derived["segment-on"] = overrides.selected ?? derived.selected;
  derived["command-on"] = overrides.selected ?? derived.selected;
  for (const state of ["human", "blocked", "review", "done", "neutral"]) {
    const deps = ["surface", state === "neutral" ? "text-secondary" : `state-${state}`];
    dependencies[`pill-${state}-bg`] = deps;
    dependencies[`pill-${state}-fg`] = [...deps, `pill-${state}-bg`];
  }
  for (const [key, value] of Object.entries(derived)) {
    if (dependencies[key]?.some((dep) => dep in overrides)) t[key] = value;
  }
  Object.assign(t, overrides);
  return t;
}
