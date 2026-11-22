import assert from "node:assert/strict";
import test from "node:test";
import { COLOR_KEYS, DEFAULT_APPEARANCE, PALETTES, colorTokens, contrast, paletteTokens, parseAppearance, resolvePalette, withSystemAccent } from "./palettes.ts";

test("Neutral default, Dusk, macOS and fifteen named palettes cover the complete token contract in both modes", () => {
  assert.equal(PALETTES[0].id, "neutral");
  assert.equal(DEFAULT_APPEARANCE.palette, "neutral");
  assert.equal(PALETTES.length, 18);
  assert.equal(new Set(PALETTES.map((p) => p.id)).size, 18);
  const keys = Object.keys(PALETTES[0].dark).sort();
  for (const p of PALETTES) for (const mode of ["light", "dark"]) {
    const t = paletteTokens({ ...DEFAULT_APPEARANCE, palette: p.id }, mode);
    assert.deepEqual(Object.keys(t).sort(), keys, `${p.id} ${mode}`);
    for (const k of COLOR_KEYS) assert.match(t[k], /^#[\da-f]{6}(?:[\da-f]{2})?$/i, `${p.id} ${mode} ${k}`);
    const series = Array.from({ length: 8 }, (_, i) => t[`viz-${i + 1}`]);
    assert.equal(new Set(series).size, 8, `${p.id} ${mode} distinct chart slots`);
    for (const color of series) assert.match(color, /^#[\da-f]{6}$/i);
  }
});

test("preset text and buttons meet small text contrast on their surfaces", () => {
  for (const p of PALETTES.filter((p) => p.id !== "dusk")) for (const mode of ["light", "dark"]) {
    const t = p[mode];
    for (const fg of ["text", "text-2", "text-secondary", "text-tertiary", "state-human", "state-blocked", "state-done"])
      for (const bg of ["bg", "surface", "surface-raised"])
        assert.ok(contrast(t[fg], t[bg]) >= 4.5, `${p.id} ${mode} ${fg} on ${bg}`);
    assert.ok(contrast(t["text-on-accent"], t.accent) >= 4.5, `${p.id} ${mode} primary`);
    assert.ok(contrast(t["approve-fg"], t["state-human"]) >= 4.5, `${p.id} ${mode} approval`);
  }
});

test("corrupt, oversized, unknown and CSS injection preferences fall back safely", () => {
  for (const raw of [null, "{", "null", "false", '{"version":2}', "a".repeat(40001)]) assert.deepEqual(parseAppearance(raw), DEFAULT_APPEARANCE);
  const settings = parseAppearance(JSON.stringify({ version: 1, palette: "custom", custom: { base: "unknown", dark: { bg: "red; display:none", text: "#ABCDEF", "unknown-token": "#123456", accent: "url(evil)" }, light: null } }));
  assert.equal(settings.custom.base, DEFAULT_APPEARANCE.palette);
  assert.deepEqual(settings.custom.dark, { text: "#abcdef" });
  assert.deepEqual(settings.custom.light, {});
  assert.equal(parseAppearance('{"version":1,"palette":"unknown"}').palette, DEFAULT_APPEARANCE.palette);
});

test("harness activity is on for existing preferences and off only for an explicit false", () => {
  assert.equal(DEFAULT_APPEARANCE.showHarnessActivity, true);
  for (const value of [undefined, null, 0, "false", true, {}, []]) {
    assert.equal(parseAppearance(JSON.stringify({ version: 1, palette: "nord", showHarnessActivity: value })).showHarnessActivity, true);
  }
  const disabled = parseAppearance(JSON.stringify({ version: 1, palette: "nord", showHarnessActivity: false }));
  assert.equal(disabled.showHarnessActivity, false);
  assert.equal(parseAppearance(JSON.stringify(disabled)).showHarnessActivity, false);
  assert.equal(paletteTokens(disabled, "dark").bg, PALETTES.find((p) => p.id === "nord").dark.bg);
});

test("custom colors are independent by mode and explicit advanced colors win", () => {
  const custom = { version: 1, palette: "custom", custom: { base: "nord", dark: { surface: "#182128", accent: "#aabbcc", "state-human": "#aabbcc", "viz-panel": "#123456" }, light: { bg: "#fff0ee" } } };
  const dark = paletteTokens(custom, "dark"), light = paletteTokens(custom, "light");
  assert.equal(dark.surface, "#182128");
  assert.equal(dark["viz-surface"], dark.surface);
  assert.equal(dark["viz-panel"], "#123456");
  assert.equal(dark["accent-soft"], "#aabbcc26");
  assert.ok(contrast(dark["text-on-accent"], dark.accent) >= 4.5);
  assert.equal(light.bg, "#fff0ee");
  assert.equal(light.surface, PALETTES.find((p) => p.id === "nord").light.surface);
  assert.notEqual(dark["pill-human-bg"], PALETTES.find((p) => p.id === "nord").dark["pill-human-bg"]);
});

test("serialized resolver matches runtime custom and preset colors", () => {
  const prepaintResolve = new Function(`return (${resolvePalette.toString()})`)();
  for (const mode of ["dark", "light"]) for (const p of PALETTES) {
    const settings = { version: 1, palette: "custom", custom: { base: p.id, dark: { accent: "#663399", surface: "#112233" }, light: { bg: "#eeeeee" } } };
    assert.deepEqual(prepaintResolve(settings, mode, PALETTES), paletteTokens(settings, mode));
  }
});

test("switching to Custom without overrides preserves the selected base exactly", () => {
  for (const p of PALETTES) for (const mode of ["light", "dark"]) {
    assert.deepEqual(paletteTokens({ version: 1, palette: "custom", custom: { base: p.id, dark: {}, light: {} } }, mode), p[mode]);
  }
});

test("macOS palette: AppKit backgrounds in both modes, and an accent that follows the system", () => {
  const mac = PALETTES.find((p) => p.id === "macos");
  assert.equal(mac.dark.bg, "#1e1e1e");
  assert.equal(mac.light.bg, "#ffffff");
  for (const mode of ["dark", "light"]) {
    const t = withSystemAccent(mac[mode], "#ff9500", mode);
    assert.ok(contrast(t.accent, t.bg) >= 3, `${mode} accent`);
    assert.equal(t["accent-soft"], t.accent + "26");
    assert.equal(t["segment-on"], t.selected);
    assert.notEqual(t.selected, mac[mode].selected);
    assert.ok(contrast(t["text-on-accent"], t.accent) >= 4.5);
    assert.equal(t.bg, mac[mode].bg);
  }
  assert.equal(withSystemAccent(mac.dark, "orange", "dark"), mac.dark);
});

test("an unsaved appearance is the macOS palette only inside the Mac app", () => {
  assert.equal(DEFAULT_APPEARANCE.palette, "neutral");
  const neutral = PALETTES.find((p) => p.id === "neutral"), mac = PALETTES.find((p) => p.id === "macos");
  assert.deepEqual(resolvePalette(DEFAULT_APPEARANCE, "dark", PALETTES), neutral.dark);
  globalThis.window = { __VESPER_NATIVE__: { v: 1 } };
  try {
    assert.deepEqual(resolvePalette(DEFAULT_APPEARANCE, "dark", PALETTES), mac.dark);
    // A saved choice always wins.
    assert.deepEqual(resolvePalette(parseAppearance(JSON.stringify({ version: 1, palette: "neutral" })), "dark", PALETTES), neutral.dark);
  } finally {
    delete globalThis.window;
  }
});

test("colorTokens keeps the hex colours the Mac app's native screens read, and drops other CSS values", () => {
  const tokens = paletteTokens(DEFAULT_APPEARANCE, "dark");
  const colors = colorTokens(tokens);
  assert.equal(colors.text, tokens.text);
  assert.equal(colors["accent-soft"], tokens["accent-soft"]);
  assert.equal(colors["shadow-float"], undefined);
  for (const value of Object.values(colors)) assert.match(value, /^#[\da-f]{6}([\da-f]{2})?$/i);
});
