// The Board screen's left column: the Work header and a By epic filter.
import type { NavModel } from "../protocol.ts";
import { workModel, type WorkHeaderInput } from "./work.ts";

export const BOARD_ALL_EPICS = "all-epics";

export function buildBoardNavModel(input: {
  header: WorkHeaderInput;
  /** Absent without a project (the page shows the scope picker). */
  epics?: readonly { id: string; name: string }[];
  epic?: string;
}): NavModel {
  const sections: NavModel["sections"] = [];
  if (input.epics) {
    sections.push({
      id: "by-epic",
      title: "By epic",
      items: [{ id: BOARD_ALL_EPICS, title: "All epics" }, ...input.epics.map((e) => ({ id: `epic:${e.id}`, title: e.name }))],
    });
  }
  return workModel("board", input.header, sections, input.epic ? `epic:${input.epic}` : input.epics ? BOARD_ALL_EPICS : null);
}
