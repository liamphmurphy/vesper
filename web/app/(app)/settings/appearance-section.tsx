"use client";

import { useRef, useState } from "react";
import { PALETTES, COLOR_KEYS, contrast, paletteTokens, parseAppearance, type ColorMode, type Tokens } from "@/lib/palettes";
import { hexToHsl, hslToHex } from "@/lib/persona-ui";
import { defaultAppearance, ThemeSwitch, useAppearance, useAppearanceStorage } from "@/components/shell/theme";
import { ColorWheel } from "@/components/ui/color-wheel";
import { Button } from "@/components/ui/button";
import { Card, TextInput } from "@/components/ui/primitives";
import { Icon } from "@/components/ui/icon";
import { Segmented, Toggle } from "@/components/ui/controls";
import { cx } from "@/lib/cx";

const GROUPS: { label: string; keys: string[] }[] = [
  { label: "Backgrounds and surfaces", keys: ["bg", "bg-sidebar", "bg-panel", "surface", "surface-raised", "surface-sunken", "border", "border-strong"] },
  { label: "Text and buttons", keys: ["text", "text-2", "text-secondary", "text-tertiary", "accent", "text-on-accent", "btn-secondary-bg", "btn-secondary-border", "btn-outline-bg"] },
  { label: "Status colors", keys: ["state-backlog", "state-todo", "state-progress", "state-review", "state-done", "state-human", "state-blocked"] },
  { label: "Charts and SVGs", keys: ["viz-surface", "viz-panel", "viz-ink", "viz-muted", "viz-line", "viz-grid", ...Array.from({ length: 8 }, (_, i) => `viz-${i + 1}`)] },
];
const basic = new Set(GROUPS.flatMap((g) => g.keys));
const advanced = COLOR_KEYS.filter((k) => !basic.has(k));
const title = (key: string) => key.replace(/^viz-/, "Diagram ").replace(/^bg$/, "Background").replace(/-/g, " ").replace(/^./, (c) => c.toUpperCase());

export function AppearanceSection() {
  const [settings, update] = useAppearance();
  const persisted = useAppearanceStorage();
  const [editMode, setEditMode] = useState<ColorMode>("dark");
  const [activeKey, setActiveKey] = useState("bg");
  const [message, setMessage] = useState("");
  const upload = useRef<HTMLInputElement>(null);
  const colors = paletteTokens(settings, editMode);
  const custom = settings.palette === "custom";
  const overrides = settings.custom[editMode];
  const setColor = (value: string) => update({ ...settings, custom: { ...settings.custom, [editMode]: { ...overrides, [activeKey]: value } } });
  const resetColor = () => {
    const next = { ...overrides };
    delete next[activeKey];
    update({ ...settings, custom: { ...settings.custom, [editMode]: next } });
  };
  const warnings = [
    ...["bg", "surface", "surface-raised", "btn-secondary-bg", "btn-outline-bg"].flatMap((bg) => ["text", "text-2", "text-secondary", "text-tertiary"].map((fg) => ({ name: `${title(fg)} on ${title(bg)}`, ratio: contrast(colors[fg], colors[bg]) }))),
    { name: "Button text on accent", ratio: contrast(colors["text-on-accent"], colors.accent) },
    { name: "Approval button text", ratio: contrast(colors["approve-fg"], colors["state-human"]) },
    { name: "Diagram text", ratio: contrast(colors["viz-ink"], colors["viz-panel"]) },
    { name: "Diagram secondary text", ratio: contrast(colors["viz-muted"], colors["viz-surface"]) },
  ].filter((p) => p.ratio < 4.5);
  const exportSettings = () => {
    const { version, palette, custom } = settings;
    const url = URL.createObjectURL(new Blob([JSON.stringify({ version, palette, custom }, null, 2)], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url; a.download = "vesper-palette.json"; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  const field = (key: string) => <button type="button" key={key} aria-pressed={activeKey === key} onClick={() => setActiveKey(key)} className={cx("flex items-center gap-2 rounded-md border p-2 text-left text-12", activeKey === key ? "border-accent bg-selected text-fg" : "border-border text-fg-secondary hover:bg-hover")}>
    <span aria-hidden className="size-5 flex-none rounded-full border border-border-strong" style={{ background: colors[key] }} />
    <span className="min-w-0">{title(key)}{overrides[key] && <span className="ml-1 text-fg-tertiary" aria-label="Customized">•</span>}</span>
  </button>;

  return <Card>
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><h3 className="type-heading">Mode</h3><p className="type-small text-fg-tertiary">System follows your OS setting. Palette is independent of mode.</p></div>
        <ThemeSwitch />
      </div>
      <div className="flex flex-col gap-1.5">
        <Toggle label="Show harness activity" checked={settings.showHarnessActivity !== false}
          onChange={(showHarnessActivity) => update({ ...settings, showHarnessActivity })} />
        <p className="type-small text-fg-tertiary">Show animated harness characters and usage in the right rail.</p>
      </div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><h3 className="type-heading">Text size</h3><p className="type-small text-fg-tertiary">Scales all text in Vesper. Documents and slides keep their own sizes when printed or exported.</p></div>
        <Segmented label="Text size" value={settings.textSize ?? "default"} onChange={(textSize) => update({ ...settings, textSize })} options={[
          { value: "small", label: "Small" }, { value: "default", label: "Default" }, { value: "large", label: "Large" }, { value: "larger", label: "Larger" },
        ]} />
      </div>
      <fieldset>
        <legend className="type-heading mb-2">Color palette</legend>
        <div className="grid grid-cols-2 gap-2 lg:grid-cols-3">
          {[...PALETTES, { id: "custom", name: "Custom", description: "Your own colors", dark: paletteTokens({ ...settings, palette: "custom" }, "dark"), light: paletteTokens({ ...settings, palette: "custom" }, "light") }].map((p) => <label key={p.id} className={cx("flex cursor-pointer flex-col gap-2 rounded-lg border p-3", settings.palette === p.id ? "border-accent bg-selected" : "border-border hover:bg-hover")}>
            <span className="flex items-center gap-2"><input type="radio" aria-label={p.name} name="color-palette" value={p.id} checked={settings.palette === p.id} onChange={() => update({ ...settings, palette: p.id })} className="accent-accent" /><span className="text-13 font-medium">{p.name}</span></span>
            <span aria-hidden className="flex overflow-hidden rounded-md border border-border">
              {[p.dark.bg, p.light.bg, p.dark.accent, p.dark["state-done"], p.dark["state-human"]].map((color, i) => <span key={i} className="h-5 flex-1" style={{ background: color }} />)}
            </span>
            <span className="text-11 text-fg-tertiary">{p.description}</span>
          </label>)}
        </div>
      </fieldset>
      <div className="flex flex-wrap gap-2">
        {!custom && <Button onClick={() => update({ ...settings, palette: "custom", custom: { base: settings.palette, dark: {}, light: {} } })}>Customize this palette</Button>}
        <Button variant="outline" onClick={exportSettings}>Export palette</Button>
        <Button variant="outline" onClick={() => upload.current?.click()}>Import palette</Button>
        <Button variant="ghost" onClick={() => { const reset = defaultAppearance(); update({ ...reset, showHarnessActivity: settings.showHarnessActivity, textSize: settings.textSize }); setMessage(`Palette reset to ${PALETTES.find((p) => p.id === reset.palette)?.name ?? "the default"}.`); }}>Reset palette</Button>
        <input ref={upload} aria-label="Palette JSON file" type="file" accept=".json,application/json" className="sr-only" onChange={async (e) => {
          const file = e.target.files?.[0];
          e.target.value = "";
          if (!file) return;
          try {
            if (file.size > 40000) throw new Error("Use a palette JSON file smaller than 40 KB.");
            const raw = await file.text();
            const data = JSON.parse(raw);
            if (data?.version !== 1 || ![...PALETTES.map((p) => p.id), "custom"].includes(data.palette)) throw new Error("This file is not a Vesper palette.");
            update({ ...parseAppearance(raw), showHarnessActivity: settings.showHarnessActivity, textSize: settings.textSize }); setMessage("Palette imported.");
          } catch (error) { setMessage(error instanceof Error ? error.message : "Could not import palette."); }
        }} />
      </div>
      <p className="text-12 text-fg-tertiary">Changes apply immediately and are saved in this browser. Export and import to move your palette to another device.</p>
      {!persisted && <p role="status" className="text-12 text-pill-human-fg">Browser storage is unavailable. Your colors apply for this visit; export to keep them.</p>}
      {message && <p role="status" className="text-12 text-fg-secondary">{message}</p>}
      {custom && <div className="flex flex-col gap-4 border-t border-border pt-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <label className="flex items-center gap-2 text-14">Base palette<select aria-label="Base palette" value={settings.custom.base} className="rounded-md border border-border bg-surface p-1.5 text-fg" onChange={(e) => update({ ...settings, custom: { ...settings.custom, base: e.target.value } })}>{PALETTES.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <Segmented label="Edit palette variant" value={editMode} onChange={setEditMode} options={[{ value: "dark", label: "Dark colors" }, { value: "light", label: "Light colors" }]} />
        </div>
        <p className="text-12 text-fg-tertiary">Editing the {editMode} variant. Switch Mode above to see it across the app. Hover states, tints, and diagram text follow your base colors unless overridden.</p>
        <PalettePreview colors={colors} />
        <div className="grid items-start gap-4 xl:grid-cols-[1fr_280px]">
          <div className="flex flex-col gap-4">{GROUPS.map((g) => <fieldset key={g.label}><legend className="type-heading mb-2">{g.label}</legend><div className="grid grid-cols-2 gap-1.5 sm:grid-cols-3">{g.keys.map(field)}</div></fieldset>)}
            <details><summary className="cursor-pointer text-14 font-medium">Advanced color overrides</summary><div className="mt-2 grid grid-cols-2 gap-1.5 sm:grid-cols-3">{advanced.map(field)}</div></details>
          </div>
          <div className="order-first flex flex-col gap-3 rounded-lg border border-border bg-surface-raised p-3 xl:sticky xl:top-4 xl:order-last">
            <label className="flex flex-col gap-1 text-12">Color to edit<select aria-label="Color to edit" value={activeKey} onChange={(e) => setActiveKey(e.target.value)} className="w-full rounded-md border border-border bg-surface p-1.5 text-fg">{[...GROUPS, { label: "Advanced overrides", keys: advanced }].map((g) => <optgroup key={g.label} label={g.label}>{g.keys.map((key) => <option key={key} value={key}>{title(key)}</option>)}</optgroup>)}</select></label>
            <h4 className="type-heading">{title(activeKey)}</h4>
            <ColorEditor key={`${editMode}-${activeKey}`} value={colors[activeKey].slice(0, 7)} onChange={setColor} />
            <Button variant="outline" disabled={!overrides[activeKey]} onClick={resetColor}>Reset this color</Button>
            <Button variant="ghost" onClick={() => update({ ...settings, custom: { ...settings.custom, [editMode]: {} } })}>Reset {editMode} colors</Button>
          </div>
        </div>
        <div role="status" aria-label="Palette contrast" className="rounded-xl border border-border p-3 text-12">
          {warnings.length ? <><p className="font-medium">{warnings.length} text combinations fall below 4.5:1 contrast.</p><ul className="mt-2 flex flex-col gap-1">{warnings.map((w) => <li key={w.name}>{w.name}: {w.ratio.toFixed(2)}:1</li>)}</ul></> : <p>Text contrast passes 4.5:1 on the preview surfaces.</p>}
        </div>
      </div>}
    </div>
  </Card>;
}

function ColorEditor({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  // Retain hue/saturation at black and white so picking a hue, then moving
  // lightness, still yields that hue instead of resetting to gray.
  const [picker, setPicker] = useState(() => ({ value, ...hexToHsl(value) }));
  const { h, s, l } = picker.value === value ? picker : hexToHsl(value);
  const [error, setError] = useState(false);
  const pick = (h: number, s: number, l: number) => {
    const next = hslToHex(h, s, l);
    setPicker({ value: next, h, s, l });
    setError(false);
    onChange(next);
  };
  return <>
    <div className="flex justify-center"><ColorWheel h={h} s={s} onPick={(h, s) => pick(h, s, l)} /></div>
    <label className="flex flex-col gap-1 text-12">Lightness<input aria-label="Color lightness" type="range" min="0" max="100" value={Math.round(l * 100)} onChange={(e) => pick(h, s, Number(e.target.value) / 100)} className="w-full accent-accent" /></label>
    <label className="flex flex-col gap-1 text-12">Hex color<TextInput key={value} aria-label="Hex color" defaultValue={value} maxLength={7} spellCheck={false} aria-invalid={error} onChange={(e) => {
      const valid = /^#[\da-f]{6}$/i.test(e.target.value);
      setError(!valid);
      if (valid) {
        const next = e.target.value.toLowerCase();
        setPicker({ value: next, ...hexToHsl(next) });
        onChange(next);
      }
    }} /></label>
    {error && <p role="alert" className="text-12 text-pill-human-fg">Enter a six-digit hex color, such as #7864d9.</p>}
  </>;
}

function PalettePreview({ colors: c }: { colors: Tokens }) {
  return <div aria-label="Palette preview" className="grid gap-3 rounded-lg border p-4 sm:grid-cols-2" style={{ background: c.bg, color: c.text, borderColor: c.border }}>
    <div><p className="font-semibold">Your workspace, your colors</p><p className="mt-1 text-12" style={{ color: c["text-secondary"] }}>Text, buttons, status colors, and diagrams.</p><div className="mt-3 flex gap-2"><span className="rounded-md px-3 py-1.5 text-12 font-semibold" style={{ background: c.accent, color: c["text-on-accent"] }}>Primary button</span><span className="rounded-md border px-3 py-1.5 text-12" style={{ background: c["btn-secondary-bg"], borderColor: c["btn-secondary-border"], color: c.text }}>Secondary</span></div><div className="mt-3 flex gap-3 text-12">{["done", "human", "blocked"].map((s) => <span key={s} style={{ color: c[`state-${s}`] }}>● {s}</span>)}</div></div>
    <div className="rounded-md border p-3" style={{ background: c.surface, borderColor: c.border }}><svg role="img" aria-label="Palette chart and icons" viewBox="0 0 220 76" className="w-full"><path d="M8 60H210" stroke={c["viz-line"]} />{[28, 45, 38, 55, 32, 48, 42, 56].map((height, i) => <rect key={i} x={12 + i * 25} y={60 - height} width="16" height={height} rx="3" fill={c[`viz-${i + 1}`]} />)}<text x="110" y="74" textAnchor="middle" fontSize="9" fill={c["viz-muted"]}>Charts and SVG elements</text></svg><div className="mt-1 flex items-center gap-2 text-12" style={{ color: c.accent }}><Icon name="check" /><Icon name="compass" /><span>Icons inherit your colors</span></div></div>
  </div>;
}
