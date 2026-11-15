"use client";

import { useEffect, useSyncExternalStore } from "react";
import { Segmented } from "@/components/ui/controls";
import { DEFAULT_APPEARANCE, paletteTokens, parseAppearance, type Appearance, type ThemePref } from "@/lib/palettes";
export type { ThemePref } from "@/lib/palettes";

const MODE_KEY = "la-theme";
const PALETTE_KEY = "la-appearance";
const listeners = new Set<() => void>();
let settings = DEFAULT_APPEARANCE;
let pref: ThemePref = "system";
let initialized = false;
let storageAvailable = true;

function load() {
  try {
    const mode = localStorage.getItem(MODE_KEY);
    pref = mode === "dark" || mode === "light" ? mode : "system";
    settings = parseAppearance(localStorage.getItem(PALETTE_KEY));
  } catch { storageAvailable = false; }
}

export function effectiveMode(): "dark" | "light" {
  const explicit = document.documentElement.getAttribute("data-theme");
  return explicit === "dark" || explicit === "light" ? explicit : matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

function apply() {
  const root = document.documentElement;
  // Print views own the root temporarily, so saved preferences never change paper.
  const printing = root.hasAttribute("data-print-theme");
  const colors = paletteTokens(printing ? DEFAULT_APPEARANCE : settings, effectiveMode());
  for (const [key, value] of Object.entries(colors)) {
    if (root.style.getPropertyValue(`--${key}`) !== value) root.style.setProperty(`--${key}`, value);
  }
  root.dataset.palette = printing ? DEFAULT_APPEARANCE.palette : settings.palette;
  root.dataset.harnessActivity = settings.showHarnessActivity === false ? "hidden" : "visible";
  // Print views keep the default size so paper looks the same whoever prints it.
  root.dataset.textSize = printing ? "default" : settings.textSize ?? "default";
}

function notify() { listeners.forEach((l) => l()); }

function initialize() {
  if (initialized || typeof window === "undefined") return;
  initialized = true;
  load();
  apply();
  window.addEventListener("storage", (e) => {
    if (e.key !== null && e.key !== MODE_KEY && e.key !== PALETTE_KEY) return;
    load();
    applyMode();
    notify();
  });
  matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => { apply(); notify(); });
  const observer = new MutationObserver(() => { apply(); notify(); });
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "data-print-theme"] });
}

function applyMode() {
  const root = document.documentElement;
  if (!root.hasAttribute("data-print-theme")) {
    if (pref === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", pref);
  }
  apply();
}

function subscribe(callback: () => void) {
  initialize();
  listeners.add(callback);
  return () => { listeners.delete(callback); };
}

export function setAppearance(next: Appearance) {
  initialize();
  settings = parseAppearance(JSON.stringify(next));
  try { localStorage.setItem(PALETTE_KEY, JSON.stringify(settings)); }
  catch { storageAvailable = false; }
  apply();
  notify();
}

export function useAppearance() {
  const value = useSyncExternalStore(subscribe, () => settings, () => DEFAULT_APPEARANCE);
  return [value, setAppearance] as const;
}

export function useAppearanceStorage() {
  return useSyncExternalStore(subscribe, () => storageAvailable, () => true);
}

export function useTheme(): [ThemePref, (p: ThemePref) => void] {
  const value = useSyncExternalStore(subscribe, () => pref, () => "system" as ThemePref);
  return [value, (next) => {
    initialize();
    pref = next;
    try {
      if (next === "system") localStorage.removeItem(MODE_KEY);
      else localStorage.setItem(MODE_KEY, next);
    } catch { storageAvailable = false; }
    applyMode();
    notify();
  }];
}

/** Keep palettes synchronized on every route, including pages without a switch. */
export function AppearanceSync() {
  useEffect(initialize, []);
  return null;
}

export function ThemeSwitch() {
  const [value, onChange] = useTheme();
  return <Segmented label="Theme" value={value} onChange={onChange} options={[
    { value: "system", label: "System" }, { value: "dark", label: "Dark" }, { value: "light", label: "Light" },
  ]} />;
}
