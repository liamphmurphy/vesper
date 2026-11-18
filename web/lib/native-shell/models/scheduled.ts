// The Scheduled tasks list as a NavModel (scheduled-screen.tsx's left column).
import type { NavModel } from "../protocol.ts";

export type ScheduledFilter = "all" | "active" | "paused";
export interface ScheduledRow {
  id: string;
  name: string;
  enabled: boolean;
  /** describeSchedule(task) */
  schedule: string;
}

export const SCHEDULED_NEW_ACTION = "new-task";
export const SCHEDULED_FILTER_PICKER = "filter";

export function buildScheduledNavModel(input: { all: readonly ScheduledRow[]; filter: ScheduledFilter; open: string | null }): NavModel {
  const n = (on: boolean) => input.all.filter((t) => t.enabled === on).length;
  const rows = input.all.filter((t) => input.filter === "all" || t.enabled === (input.filter === "active"));
  return {
    id: "scheduled",
    title: "Scheduled",
    actions: [{ id: SCHEDULED_NEW_ACTION, label: "Create scheduled task", icon: "plus", accent: true }],
    picker: {
      id: SCHEDULED_FILTER_PICKER,
      value: input.filter,
      options: [
        { value: "all", label: `All ${input.all.length}` },
        { value: "active", label: `Active ${n(true)}` },
        { value: "paused", label: `Paused ${n(false)}` },
      ],
    },
    sections: [
      {
        id: "tasks",
        items: rows.map((t) => ({ id: t.id, title: t.name, subtitle: t.schedule, ...(t.enabled ? { status: "done" as const } : {}) })),
        emptyText: input.all.length ? "Nothing matches this filter." : "No scheduled tasks yet",
      },
    ],
    selectedId: input.open && input.open !== "new" ? input.open : null,
  };
}
