// The artifact screens' header rows as native toolbar items: the artifact page's Review / Edit / Start
// chat / Download / Export PDF / New version, and the mockup editor's mode switch and Cancel / Save /
// Save & approve. Pure; the screens feed in the handlers (`run`).
import type { NativeAction } from "../actions.ts";

export interface ArtifactActionsInput {
  isMockup: boolean;
  /** The artifact is a Markdown document the print view can export. */
  canExportPdf: boolean;
  review: () => void;
  edit: () => void;
  startChat: { disabled: boolean; run: () => void };
  download: () => void;
  exportPdf: () => void;
  newVersion: () => void;
}

export function buildArtifactActions(i: ArtifactActionsInput): NativeAction[] {
  return [
    ...(i.isMockup
      ? [
          { id: "artifact.review", label: "Review", kind: "button" as const, icon: "check", showsLabel: true, accent: true, run: i.review },
          { id: "artifact.edit", label: "Edit", kind: "button" as const, icon: "edit", showsLabel: true, run: i.edit },
        ]
      : []),
    { id: "artifact.chat", label: "Start chat", kind: "button", icon: "msg", showsLabel: true, disabled: i.startChat.disabled, run: i.startChat.run },
    { id: "artifact.download", label: "Download", kind: "button", icon: "download", showsLabel: true, run: i.download },
    ...(i.canExportPdf ? [{ id: "artifact.pdf", label: "Export PDF", kind: "button" as const, icon: "printer", showsLabel: true, run: i.exportPdf }] : []),
    { id: "artifact.version", label: "New version", kind: "button", icon: i.isMockup ? "upload" : "history", showsLabel: true, run: i.newVersion },
  ];
}

export type MockupMode = "visual" | "source" | "split";

export interface MockupEditActionsInput {
  mode: MockupMode;
  modes: readonly { value: MockupMode; label: string }[];
  setMode: (m: MockupMode) => void;
  canSave: boolean;
  cancel: () => void;
  saveVersion: () => void;
  saveAndApprove: () => void;
}

export function buildMockupEditActions(i: MockupEditActionsInput): NativeAction[] {
  const current = i.modes.find((m) => m.value === i.mode);
  return [
    {
      id: "mockup.mode",
      label: current ? `Editor: ${current.label}` : "Editor mode",
      kind: "menu",
      icon: "sliders",
      showsLabel: true,
      placement: "leading",
      menu: i.modes.map((m) => ({ id: `mode:${m.value}`, label: m.label, checked: m.value === i.mode, run: () => i.setMode(m.value) })),
    },
    { id: "mockup.cancel", label: "Cancel", kind: "button", showsLabel: true, run: i.cancel },
    { id: "mockup.save", label: "Save version", kind: "button", showsLabel: true, disabled: !i.canSave, run: i.saveVersion },
    { id: "mockup.approve", label: "Save & approve", kind: "button", icon: "check", showsLabel: true, accent: true, disabled: !i.canSave, run: i.saveAndApprove },
  ];
}
