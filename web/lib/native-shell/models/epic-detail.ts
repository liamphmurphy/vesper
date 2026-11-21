// The epic page's left column: the Work header and the project's epics (epics/[id]/epic-detail-screen.tsx).
import type { NavModel } from "../protocol.ts";
import { workModel } from "./work.ts";

export function buildEpicDetailNavModel(input: {
  project?: string;
  projectName?: string;
  epics: readonly { id: string; name: string; done: number; total: number }[];
  epicId: string;
}): NavModel {
  return workModel(
    "epic-detail",
    { active: "tickets", project: input.project, agent: "", noFilters: true },
    [
      {
        id: "epics",
        title: input.projectName ?? "Epics",
        badge: { text: String(input.epics.length) },
        items: input.epics.map((e) => ({ id: e.id, title: e.name, href: `/epics/${encodeURIComponent(e.id)}`, trailing: `${e.done}/${e.total}` })),
      },
    ],
    input.epicId,
  );
}
