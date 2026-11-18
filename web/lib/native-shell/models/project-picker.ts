// The ProjectPicker dropdown (components/shell/project-picker.tsx) as a header action with a menu.
import type { NavAction } from "../protocol.ts";

export const PROJECT_PICKER_ACTION = "pick-space";
export const PROJECT_PICKER_OPEN = "space-open";

export function projectPickerAction(input: {
  projects: readonly { key: string; name: string }[];
  current?: { key: string; name: string } | null;
  allowAll?: boolean;
}): NavAction {
  const cur = input.current?.key ?? "";
  return {
    id: PROJECT_PICKER_ACTION,
    label: `Space: ${input.current?.name ?? "All spaces"}`,
    icon: "folder",
    menu: [
      ...(input.allowAll === false ? [] : [{ id: "space:", label: "All spaces", icon: "folder", checked: !cur }, { id: "sep-all", separator: true }]),
      ...input.projects.map((p) => ({ id: `space:${p.key}`, label: p.name, checked: cur === p.key })),
      { id: "sep-open", separator: true },
      { id: PROJECT_PICKER_OPEN, label: input.current ? `Open ${input.current.name}` : "New space", icon: input.current ? "gear" : "plus" },
    ],
  };
}
