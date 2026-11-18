// The Slides editor in the native shell: the deck's slides as a NavModel (the web's thumbnail
// column: select, add with a layout, duplicate, delete, reorder), and its Present / Share
// toolbar. Pure; DeckScreen feeds in the deck and the handlers the thumbnails call.
import type { NativeAction } from "../actions.ts";
import type { MenuItem, NavAction, NavItem, NavModel } from "../protocol.ts";
import { editorStatusActions, type EditorStatusInput } from "./editor-header.ts";

export const DECK_NAV_ID = "deck-slides";
export const slideRowId = (id: string) => `slide:${id}`;
export const parseSlideRowId = (id: string): string | null => (id.startsWith("slide:") ? id.slice("slide:".length) : null);

/** Menu and action ids. */
export const D = {
  add: "add-slide",
  addSame: "add:same",
  layout: (id: string) => `add:layout:${id}`,
  up: "up",
  down: "down",
  top: "top",
  bottom: "bottom",
  duplicate: "duplicate",
  remove: "delete",
} as const;

export type DeckCommand =
  | { type: "select"; id: string }
  | { type: "add"; layout?: string }
  | { type: "move"; id: string; to: number }
  | { type: "duplicate"; id: string }
  | { type: "remove"; id: string };

export interface DeckNavInput {
  title?: string;
  slides: readonly { id: string; title: string; hidden?: boolean }[];
  currentId?: string;
  layouts: readonly { id: string; label: string }[];
  /** Slides whose text runs past its box. */
  overflowing?: ReadonlySet<string>;
  /** Slides with a persona's pending change, and who. */
  changed?: ReadonlySet<string>;
  persona: string;
  readOnly: boolean;
}

function slideMenu(i: DeckNavInput, index: number): MenuItem[] {
  const n = i.slides.length;
  const ro = i.readOnly;
  return [
    { id: D.up, label: "Move up", disabled: ro || index === 0 },
    { id: D.down, label: "Move down", disabled: ro || index === n - 1 },
    { id: D.top, label: "Move to top", disabled: ro || index === 0 },
    { id: D.bottom, label: "Move to bottom", disabled: ro || index === n - 1 },
    { id: "s1", separator: true },
    { id: D.duplicate, label: "Duplicate", disabled: ro },
    { id: D.remove, label: "Delete", icon: "trash", destructive: true, disabled: ro || n < 2 },
  ];
}

export function buildDeckNav(i: DeckNavInput): NavModel {
  const items: NavItem[] = i.slides.map((s, k) => ({
    id: slideRowId(s.id),
    title: `${k + 1}. ${s.title}`,
    icon: "slides",
    ...(i.overflowing?.has(s.id) ? { status: "warning" as const } : {}),
    ...(i.changed?.has(s.id) ? { badge: { text: i.persona, tone: "human" as const } } : {}),
    ...(s.hidden ? { trailing: "Hidden" } : {}),
    contextMenu: slideMenu(i, k),
  }));
  const add: NavAction = {
    id: D.add,
    label: "New slide",
    icon: "plus",
    disabled: i.readOnly || !i.currentId,
    menu: [{ id: D.addSame, label: "New slide" }, { id: "s1", separator: true }, ...i.layouts.map((l) => ({ id: D.layout(l.id), label: l.label }))],
  };
  return {
    id: DECK_NAV_ID,
    title: i.title,
    sections: [{ id: "slides", title: "Slides", badge: { text: String(i.slides.length) }, items, actions: [add], emptyText: "No slides." }],
    selectedId: i.currentId ? slideRowId(i.currentId) : null,
  };
}

/** What a sidebar command on the slides means; null for anything else. `slides` is the order the rows were built in. */
export function parseDeckCommand(
  cmd: { type: string; actionId?: string; itemId?: string; menuItemId?: string },
  slides: readonly { id: string }[],
): DeckCommand | null {
  if (cmd.type === "nav.activate" && cmd.itemId) {
    const id = parseSlideRowId(cmd.itemId);
    return id ? { type: "select", id } : null;
  }
  if (cmd.type !== "nav.action") return null;
  if (cmd.actionId === D.add) {
    if (cmd.menuItemId === D.addSame) return { type: "add" };
    return cmd.menuItemId?.startsWith("add:layout:") ? { type: "add", layout: cmd.menuItemId.slice("add:layout:".length) } : null;
  }
  const id = cmd.itemId ? parseSlideRowId(cmd.itemId) : null;
  const at = slides.findIndex((s) => s.id === id);
  if (!id || at < 0) return null;
  const last = slides.length - 1;
  switch (cmd.menuItemId) {
    case D.up:
      return at > 0 ? { type: "move", id, to: at - 1 } : null;
    case D.down:
      return at < last ? { type: "move", id, to: at + 1 } : null;
    case D.top:
      return at > 0 ? { type: "move", id, to: 0 } : null;
    case D.bottom:
      return at < last ? { type: "move", id, to: last } : null;
    case D.duplicate:
      return { type: "duplicate", id };
    case D.remove:
      return slides.length > 1 ? { type: "remove", id } : null;
    default:
      return null;
  }
}

export interface DeckActionsInput extends EditorStatusInput {
  canPresent: boolean;
  present: () => void;
  /** The Share menu's export entries; absent until the deck is there. */
  share?: { pdf: () => void; pptx: () => void; pdfToLibrary: () => void; pptxToLibrary: () => void; busy: boolean };
}

export function buildDeckActions(i: DeckActionsInput): NativeAction[] {
  return [
    ...editorStatusActions(i),
    { id: "deck.present", label: "Present", icon: "play", kind: "button", showsLabel: true, disabled: !i.canPresent, run: i.present },
    ...(i.share
      ? [{
          id: "deck.share",
          label: "Share",
          icon: "upload",
          kind: "menu" as const,
          showsLabel: true,
          disabled: i.share.busy,
          menu: [
            { id: "export", label: "Export", disabled: true },
            { id: "pdf", label: "PDF (.pdf)", run: i.share.pdf },
            { id: "pptx", label: "PowerPoint (.pptx)", run: i.share.pptx },
            { id: "sep", separator: true },
            { id: "library", label: "Library", disabled: true },
            { id: "pdf-library", label: "Save PDF to Library", run: i.share.pdfToLibrary },
            { id: "pptx-library", label: "Save PowerPoint to Library", run: i.share.pptxToLibrary },
          ],
        }]
      : []),
  ];
}
