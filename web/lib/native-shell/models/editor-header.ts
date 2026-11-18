// What every app editor's header row says, as native toolbar items: the save state and who is working
// on the document (leading, next to the title), and the "Review n" pill. Pure; each editor adds its own
// trailing actions (Present, Share, undo/redo). The handlers ride along as `run`.
import type { NativeAction } from "../actions.ts";
import type { Avatar } from "../protocol.ts";

export type SaveStateName = "saved" | "unsaved" | "saving" | "conflict" | "error";

export const SAVE_LABEL: Record<SaveStateName, string> = { saved: "Saved", unsaved: "Unsaved changes", saving: "Saving…", conflict: "Not saved", error: "Not saved" };

export interface EditorStatusInput {
  /** The save state and the version it is at; omit while nothing has loaded. */
  save?: { state: SaveStateName; seq?: number };
  /** A failed save can be retried from the toolbar. */
  retry?: () => void;
  /** Who is at work on the document: "Ada is editing…". */
  presence?: { label: string; avatar?: Avatar };
  /** What waits on the document (Designs' "Review 3"). */
  review?: { count: number; label: string; run: () => void };
}

/** The leading items of an editor's toolbar. */
export function editorStatusActions(i: EditorStatusInput): NativeAction[] {
  const out: NativeAction[] = [];
  if (i.save) {
    const bad = i.save.state === "error" || i.save.state === "conflict";
    const text = `${SAVE_LABEL[i.save.state]}${i.save.seq ? ` · v${i.save.seq}` : ""}`;
    const retry = i.save.state === "error" ? i.retry : undefined;
    out.push({
      id: "editor.save",
      label: retry ? `${text} · Retry` : text,
      kind: "button",
      icon: bad ? "alert" : i.save.state === "saved" ? "check" : "clock",
      showsLabel: true,
      placement: "leading",
      accent: bad,
      disabled: !retry,
      run: retry,
    });
  }
  if (i.presence) {
    out.push({ id: "editor.presence", label: i.presence.label, kind: "button", showsLabel: true, placement: "leading", disabled: true, ...(i.presence.avatar ? { avatar: i.presence.avatar } : { icon: "agents" }) });
  }
  if (i.review) {
    out.push({ id: "editor.review", label: `Review ${i.review.count}`, kind: "button", icon: "check", showsLabel: true, accent: true, placement: "leading", run: i.review.run });
  }
  return out;
}

/** "Ada is editing…" / "Ada suggested changes" / "Ada can edit", as the web header words it. */
export function presenceLabel(persona: string, live: boolean, reviewing: boolean): string {
  return live ? `${persona} is editing…` : reviewing ? `${persona} suggested changes` : `${persona} can edit`;
}
