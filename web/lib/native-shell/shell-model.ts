// The fixed top of the native sidebar as a ShellModel: the areas (with the badges the web's icon
// row shows as dots) and the Apps entries (the AppsMenu's custom apps and tools). Pure.

import type { Area } from "../navigator.ts";
import type { AreaId, ShellApp, ShellArea, ShellModel, Tone } from "./protocol.ts";

export interface AreaDef {
  area: Exclude<Area, "apps" | "runs" | "tickets">;
  href: string;
  label: string;
  icon: string;
  badge?: string;
}

export interface ShellModelInput {
  areas: readonly AreaDef[];
  /** Counts by badge name, as useNavCounts returns. */
  counts: Record<string, number>;
  /** The area the path belongs to, from currentArea(). */
  current: Area | null;
  customApps: readonly { slug: string; name: string; icon: string }[];
  tools: readonly { href: string; label: string; icon: string }[];
}

/** The protocol has one "work" area where the web has runs and tickets too. */
export function protocolArea(area: Area | null): AreaId | null {
  return area === "runs" || area === "tickets" ? "work" : area;
}

/** A dot, in the colour the web's icon row uses: runs working is green, anything else the accent. */
const dotTone = (badge: string): Tone => (badge === "runs" ? "done" : "accent");

export function buildShellModel(input: ShellModelInput): ShellModel {
  const areas: ShellArea[] = input.areas.map((a) => {
    const area: ShellArea = { id: a.area, label: a.label, icon: a.icon, href: a.href };
    if (a.badge && (input.counts[a.badge] ?? 0) > 0) area.badge = { tone: dotTone(a.badge) };
    return area;
  });
  const apps: ShellApp[] = [
    ...input.customApps.map((a) => ({ id: `app:${a.slug}`, label: a.name, icon: a.icon, href: `/apps/${a.slug}` })),
    ...input.tools.map((t) => ({ id: `tool:${t.href}`, label: t.label, icon: t.icon, href: t.href })),
  ];
  return { areas, apps, currentArea: protocolArea(input.current) };
}
