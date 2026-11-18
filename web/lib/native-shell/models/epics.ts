// The Epics list screen's left column (tickets/_components/epics-screen.tsx) as a NavModel.
import type { NavFilterMenu, NavModel, Tone } from "../protocol.ts";
import { workHeader, type WorkHeaderInput } from "./work.ts";

export const EPICS_NAV_ID = "epics";
export const EPICS_STATUS_FILTER = "epic-status";
export const EPICS_HEALTH_FILTER = "epic-health";

const HEALTH_TONE: Record<string, Tone> = { on_track: "done", at_risk: "human", off_track: "blocked" };

export interface EpicsNavInput {
  header: Omit<WorkHeaderInput, "active" | "noPersona" | "agent">;
  status: string;
  /** Counts for the three status views. */
  counts: { open: number; done: number; all: number };
  health: string;
  healthOptions: readonly { value: string; label: string }[];
  atRiskCount: number;
  groups: readonly {
    key: string;
    label: string;
    epics: readonly { id: string; name: string; health: string; done: number; total: number }[];
  }[];
  /** The epic open beside the list. */
  selectedEpicId?: string | null;
  loading?: boolean;
}

export function buildEpicsNavModel(input: EpicsNavInput): NavModel {
  const statusOptions = [
    { value: "open", label: "Active epics", n: input.counts.open },
    { value: "done", label: "Done", n: input.counts.done },
    { value: "all", label: "All epics", n: input.counts.all },
  ];
  const statusMenu: NavFilterMenu["options"] = statusOptions.map((o) => ({ value: o.value, label: `${o.label} (${o.n})`, checked: input.status === o.value }));
  const healthMenu: NavFilterMenu["options"] = input.healthOptions.map((h) => ({
    value: h.value,
    label: h.value === "at_risk" && input.atRiskCount > 0 ? `${h.label} (${input.atRiskCount})` : h.label,
    checked: input.health === h.value,
  }));
  const head = workHeader({ ...input.header, active: "epics", agent: "", noPersona: true });
  head.filters.push(
    { id: EPICS_STATUS_FILTER, label: "Status", icon: "sliders", options: statusMenu },
    { id: EPICS_HEALTH_FILTER, label: "Health", icon: "activity", options: healthMenu },
  );
  const sections: NavModel["sections"] = input.groups.map((g) => ({
    id: `space:${g.key}`,
    title: g.label,
    items: g.epics.map((e) => ({
      id: e.id,
      title: e.name,
      ...(HEALTH_TONE[e.health] ? { status: HEALTH_TONE[e.health] } : {}),
      trailing: `${e.done}/${e.total}`,
    })),
  }));
  if (sections.length === 0 && !input.loading) sections.push({ id: "empty", items: [], emptyText: "No epics match." });
  return { id: EPICS_NAV_ID, ...head, sections, selectedId: input.selectedEpicId ?? null };
}
