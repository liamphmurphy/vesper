// Settings' section list as a NavModel (the sticky section nav in settings-screen.tsx).
import type { NavModel, Tone } from "../protocol.ts";

export type SettingsHealth = "ok" | "attention" | "idle" | "unknown";
export interface SettingsNavEntry {
  id: string;
  label: string;
  health: SettingsHealth;
  badge?: string;
}

const HEALTH_TONE: Partial<Record<SettingsHealth, Tone>> = { ok: "done", attention: "human" };

export function buildSettingsNavModel(entries: readonly SettingsNavEntry[]): NavModel {
  return {
    id: "settings",
    title: "Settings",
    sections: [
      {
        id: "sections",
        items: entries.map((n) => ({
          id: n.id,
          title: n.label,
          ...(HEALTH_TONE[n.health] ? { status: HEALTH_TONE[n.health] } : {}),
          ...(n.badge ? { badge: { text: n.badge, tone: "human" as Tone } } : {}),
        })),
      },
    ],
  };
}
