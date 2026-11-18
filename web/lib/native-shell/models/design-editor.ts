// The Designs editor in the native shell: pages and the current page's layers as a NavModel (the web's
// left column: select, add / rename / delete pages, nested layers with rename, hide and lock), and the
// header's Present / Share / Review / title menu. Pure; the screen feeds in the document and handlers.
import type { NativeAction } from "../actions.ts";
import type { MenuItem, NavItem, NavModel } from "../protocol.ts";
import { editorStatusActions, type EditorStatusInput } from "./editor-header.ts";

export const DESIGN_NAV_ID = "design-layers";
export const pageRowId = (id: string) => `page:${id}`;
export const layerRowId = (id: string) => `layer:${id}`;

/** A layer as the panel lists it: the screen turns each DesignNode into one (labelOf, kids). */
export interface LayerRow {
  id: string;
  label: string;
  type: string;
  visible: boolean;
  locked: boolean;
  /** Connectors have no lock or visibility toggles in the web panel. */
  togglable: boolean;
  children: readonly LayerRow[];
}

export const L = {
  addPage: "add-page",
  rename: "rename",
  del: "delete",
  hide: "toggle-visible",
  lock: "toggle-lock",
} as const;

/** Layer icons from the web's glyph column, as the Icon set's names. */
const LAYER_ICON: Record<string, string> = {
  frame: "dashboard", component: "plug", instance: "plug", group: "folder", section: "board", shape: "designs",
  path: "edit", text: "edit", image: "library", sticky: "artifacts", connector: "chevr",
};

export type DesignCommand =
  | { type: "page"; id: string }
  | { type: "select"; id: string }
  | { type: "addPage" }
  | { type: "renamePage"; id: string }
  | { type: "removePage"; id: string }
  | { type: "renameLayer"; id: string }
  | { type: "toggleVisible"; id: string }
  | { type: "toggleLock"; id: string }
  | { type: "toggle"; id: string; expanded: boolean };

export interface DesignNavInput {
  title?: string;
  pages: readonly { id: string; name: string }[];
  currentPageId: string;
  layers: readonly LayerRow[];
  /** The selected layers; the sidebar shows the first as its selection. */
  selected: readonly string[];
  /** Layers shown open (the user's, plus the selection's ancestors). */
  open: ReadonlySet<string>;
  readOnly: boolean;
}

function layerItem(n: LayerRow, i: DesignNavInput): NavItem {
  // The web lists a node's children topmost first (the reverse of paint order).
  const kids = [...n.children].reverse();
  const menu: MenuItem[] = [{ id: L.rename, label: "Rename…", icon: "edit", disabled: i.readOnly }];
  if (n.togglable) {
    menu.push(
      { id: L.hide, label: n.visible ? "Hide" : "Show", disabled: i.readOnly },
      { id: L.lock, label: n.locked ? "Unlock" : "Lock", icon: "lock", disabled: i.readOnly },
    );
  }
  return {
    id: layerRowId(n.id),
    title: n.label,
    icon: LAYER_ICON[n.type] ?? "designs",
    ...(n.locked ? { trailing: "Locked" } : {}),
    ...(n.visible ? {} : { status: "neutral" as const, subtitle: "Hidden" }),
    ...(kids.length ? { children: kids.map((k) => layerItem(k, i)), expanded: i.open.has(n.id) } : {}),
    contextMenu: menu,
  };
}

export function buildDesignNav(i: DesignNavInput): NavModel {
  const pages: NavItem[] = i.pages.map((p) => ({
    id: pageRowId(p.id),
    title: p.name,
    icon: "artifacts",
    contextMenu: [
      { id: L.rename, label: "Rename…", icon: "edit", disabled: i.readOnly },
      { id: L.del, label: "Delete page", icon: "trash", destructive: true, disabled: i.readOnly || i.pages.length < 2 },
    ],
  }));
  const first = i.selected[0];
  return {
    id: DESIGN_NAV_ID,
    title: i.title,
    sections: [
      {
        id: "pages",
        title: "Pages",
        items: pages,
        actions: [{ id: L.addPage, label: "Add a page", icon: "plus", disabled: i.readOnly }],
      },
      {
        id: "layers",
        title: "Layers",
        items: [...i.layers].reverse().map((n) => layerItem(n, i)),
        emptyText: "Nothing on this page yet. Draw a frame (F) to start.",
      },
    ],
    selectedId: first ? layerRowId(first) : pageRowId(i.currentPageId),
  };
}

/** What a sidebar command means for the design; null for anything else. */
export function parseDesignCommand(cmd: { type: string; actionId?: string; itemId?: string; menuItemId?: string; expanded?: boolean }): DesignCommand | null {
  const page = (id?: string) => (id?.startsWith("page:") ? id.slice("page:".length) : null);
  const layer = (id?: string) => (id?.startsWith("layer:") ? id.slice("layer:".length) : null);
  if (cmd.type === "nav.activate") {
    const p = page(cmd.itemId);
    if (p) return { type: "page", id: p };
    const l = layer(cmd.itemId);
    return l ? { type: "select", id: l } : null;
  }
  if (cmd.type === "nav.toggle") {
    const l = layer(cmd.itemId);
    return l ? { type: "toggle", id: l, expanded: !!cmd.expanded } : null;
  }
  if (cmd.type !== "nav.action") return null;
  if (cmd.actionId === L.addPage) return { type: "addPage" };
  const p = page(cmd.itemId);
  if (p) return cmd.menuItemId === L.rename ? { type: "renamePage", id: p } : cmd.menuItemId === L.del ? { type: "removePage", id: p } : null;
  const l = layer(cmd.itemId);
  if (!l) return null;
  return cmd.menuItemId === L.rename ? { type: "renameLayer", id: l } : cmd.menuItemId === L.hide ? { type: "toggleVisible", id: l } : cmd.menuItemId === L.lock ? { type: "toggleLock", id: l } : null;
}

export type ExportScopeName = "selection" | "frame" | "page" | "frames";
export type ExportFormatName = "png" | "svg" | "pdf";

export interface DesignActionsInput extends EditorStatusInput {
  canPresent: boolean;
  present: () => void;
  /** Present once the design has loaded; its Share menu. */
  share?: {
    scopes: { id: ExportScopeName; label: string; disabled?: boolean }[];
    scope: ExportScopeName;
    busy: boolean;
    pick: (s: ExportScopeName) => void;
    download: (format: ExportFormatName, scale: number) => void;
    toLibrary: (format: ExportFormatName, scale: number) => void;
  };
}

const FORMAT_ENTRIES: { id: string; label: string; format: ExportFormatName; scale: number }[] = [
  { id: "png1", label: "PNG 1×", format: "png", scale: 1 },
  { id: "png2", label: "PNG 2×", format: "png", scale: 2 },
  { id: "png3", label: "PNG 3×", format: "png", scale: 3 },
  { id: "svg", label: "SVG", format: "svg", scale: 1 },
  { id: "pdf", label: "PDF", format: "pdf", scale: 1 },
];

export function buildDesignActions(i: DesignActionsInput): NativeAction[] {
  const out: NativeAction[] = [...editorStatusActions(i)];
  out.push({ id: "design.present", label: "Present", icon: "play", kind: "button", showsLabel: true, disabled: !i.canPresent, run: i.present });
  const s = i.share;
  if (s) {
    out.push({
      id: "design.share",
      label: "Share",
      icon: "upload",
      kind: "menu",
      showsLabel: true,
      disabled: s.busy,
      menu: [
        { id: "what", label: "What to export", children: s.scopes.map((x) => ({ id: `scope:${x.id}`, label: x.label, checked: x.id === s.scope, disabled: x.disabled, run: () => s.pick(x.id) })) },
        { id: "sep", separator: true },
        { id: "download", label: "Download", children: FORMAT_ENTRIES.map((f) => ({ id: `download:${f.id}`, label: f.label, run: () => s.download(f.format, f.scale) })) },
        { id: "library", label: "Save to Library", children: FORMAT_ENTRIES.map((f) => ({ id: `library:${f.id}`, label: f.label, run: () => s.toLibrary(f.format, f.scale) })) },
      ],
    });
  }
  return out;
}

/** The design title's ▾ menu: Rename and Duplicate. */
export function buildDesignTitleMenu(i: { duplicating: boolean; rename: () => void; duplicate: () => void }): NonNullable<NativeAction["menu"]> {
  return [
    { id: "rename", label: "Rename…", icon: "edit", run: i.rename },
    { id: "duplicate", label: "Duplicate", disabled: i.duplicating, run: i.duplicate },
  ];
}
