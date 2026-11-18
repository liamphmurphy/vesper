// The Workflows list (workflows-screen.tsx's left column) as a NavModel.
import type { NavModel } from "../protocol.ts";

export function buildWorkflowsNavModel(input: {
  workflows: readonly { id: string; name: string; published_version: number }[];
  runs: readonly { id: string; name: string }[];
  selectedId?: string | null;
}): NavModel {
  const sections: NavModel["sections"] = [
    {
      id: "workflows",
      items: input.workflows.map((w) => ({
        id: w.id,
        title: w.name,
        href: `/workflows/${w.id}`,
        trailing: w.published_version > 0 ? `v${w.published_version}` : "Draft",
      })),
    },
  ];
  if (input.runs.length > 0) {
    sections.push({
      id: "runs",
      title: "Recent runs",
      items: input.runs.map((r) => ({ id: `run:${r.id}`, title: r.name, href: `/workflows/runs/${r.id}` })),
    });
  }
  return { id: "workflows", title: "Workflows", sections, selectedId: input.selectedId ?? null };
}

export const WORKFLOW_PALETTE_ID = "workflow-palette";

/** The workflow editor's node palette: a row adds the node (the web also lets you drag it onto the canvas). */
export function buildWorkflowPaletteNavModel(input: {
  palette: readonly { group: string; items: readonly { type: string; label: string }[] }[];
  /** Adding is off while a proposal is previewed. */
  disabled?: boolean;
}): NavModel {
  return {
    id: WORKFLOW_PALETTE_ID,
    title: "Node types",
    sections: input.palette.map((g) => ({
      id: g.group.toLowerCase(),
      title: g.group,
      items: g.items.map((i) => ({ id: i.type, title: i.label, icon: "plus", ...(input.disabled ? { disabled: true } : {}) })),
    })),
  };
}
