// The artifact screens' header rows as native toolbar items: the artifact page's Review / Edit / Start
// chat / Download / Export PDF / New version, the mockup editor's mode switch and Cancel / Save /
// Save & approve, and the full-screen review's version pickers and Close. Pure; the screens feed in
// the handlers (`run`).
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

export type ReviewMode = "single" | "side" | "swipe";

export interface ReviewActionsInput {
  versions: readonly { id: string; label: string }[];
  primaryId: string;
  currentId: string;
  pickVersion: (id: string) => void;
  /** More than one version: the compare switch. */
  modes?: { value: ReviewMode; label: string }[];
  mode: ReviewMode;
  setMode: (m: ReviewMode) => void;
  /** The versions the comparison can be against (not the primary), and the one chosen. */
  others?: readonly { id: string; label: string }[];
  withId?: string;
  setWith: (id: string) => void;
  /** The ticket the review is for, shown in the web header before the title. */
  ticket?: { key: string; run: () => void };
  close: () => void;
}

export function buildReviewActions(i: ReviewActionsInput): NativeAction[] {
  const primary = i.versions.find((v) => v.id === i.primaryId);
  const out: NativeAction[] = [
    ...(i.ticket ? [{ id: "review.ticket", label: i.ticket.key, kind: "button" as const, icon: "tickets", showsLabel: true, placement: "leading" as const, run: i.ticket.run }] : []),
    {
      id: "review.version",
      label: `Version ${primary?.label ?? ""}`.trim(),
      kind: "menu",
      showsLabel: true,
      placement: "leading",
      menu: i.versions.map((v) => ({ id: `version:${v.id}`, label: v.id === i.currentId ? `${v.label} (current)` : v.label, checked: v.id === i.primaryId, run: () => i.pickVersion(v.id) })),
    },
  ];
  if (i.modes) {
    const m = i.modes.find((x) => x.value === i.mode);
    out.push({
      id: "review.compare",
      label: `Compare: ${m?.label ?? ""}`,
      kind: "menu",
      icon: "compare",
      showsLabel: true,
      placement: "leading",
      menu: i.modes.map((x) => ({ id: `mode:${x.value}`, label: x.label, checked: x.value === i.mode, run: () => i.setMode(x.value) })),
    });
  }
  if (i.others?.length && i.mode !== "single") {
    const w = i.others.find((v) => v.id === i.withId);
    out.push({
      id: "review.with",
      label: `with ${w?.label ?? ""}`.trim(),
      kind: "menu",
      showsLabel: true,
      placement: "leading",
      menu: i.others.map((v) => ({ id: `with:${v.id}`, label: v.id === i.currentId ? `${v.label} (current)` : v.label, checked: v.id === i.withId, run: () => i.setWith(v.id) })),
    });
  }
  out.push({ id: "review.close", label: "Close", kind: "button", icon: "x", showsLabel: true, run: i.close });
  return out;
}
