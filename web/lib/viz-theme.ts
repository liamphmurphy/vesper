"use client";

import { useMemo, useSyncExternalStore } from "react";
import { usePrintMode } from "@/components/domain/print-mode";
import { VIZ_DARK, VIZ_LIGHT, type VizPalette } from "@/lib/chat-svg";
import { PALETTES } from "@/lib/palettes";

const LIGHT_TOKENS = PALETTES[0].light;
const PRINT_LIGHT_VIZ: VizPalette = {
  surface: LIGHT_TOKENS["viz-surface"] || VIZ_LIGHT.surface,
  panel: LIGHT_TOKENS["viz-panel"] || VIZ_LIGHT.panel,
  ink: LIGHT_TOKENS["viz-ink"] || VIZ_LIGHT.ink,
  muted: LIGHT_TOKENS["viz-muted"] || VIZ_LIGHT.muted,
  line: LIGHT_TOKENS["viz-line"] || VIZ_LIGHT.line,
  grid: LIGHT_TOKENS["viz-grid"] || VIZ_LIGHT.grid,
  series: VIZ_LIGHT.series.map((fallback, i) => LIGHT_TOKENS[`viz-${i + 1}`] || fallback),
};

function subscribe(onChange: () => void) {
  const attr = new MutationObserver(onChange);
  attr.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "data-palette", "style"] });
  const os = window.matchMedia("(prefers-color-scheme: light)");
  os.addEventListener("change", onChange);
  return () => { attr.disconnect(); os.removeEventListener("change", onChange); };
}

const server = JSON.stringify(VIZ_DARK);
function snapshot(): string {
  const css = getComputedStyle(document.documentElement);
  const color = (key: string, fallback: string) => css.getPropertyValue(`--viz-${key}`).trim() || fallback;
  return JSON.stringify({
    ...Object.fromEntries((["surface", "panel", "ink", "muted", "line", "grid"] as const).map((key) => [key, color(key, VIZ_DARK[key])])),
    series: VIZ_DARK.series.map((fallback, i) => color(String(i + 1), fallback)),
  });
}

/** Concrete colors for isolated SVG images, charts, Mermaid and code tokens. */
export function useVizPalette(): VizPalette {
  const printing = usePrintMode();
  const value = useSyncExternalStore(subscribe, snapshot, () => server);
  return useMemo(() => (printing ? PRINT_LIGHT_VIZ : (JSON.parse(value) as VizPalette)), [printing, value]);
}
