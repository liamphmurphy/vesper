// The Docs editor in the native shell: its outline of headings as a NavModel (the web's outline
// panel), and its Share menu as a toolbar item. Pure; DocScreen feeds in the document and the handlers.
import type { NativeAction } from "../actions.ts";
import type { NavItem, NavModel } from "../protocol.ts";
import { editorStatusActions, type EditorStatusInput } from "./editor-header.ts";

export const DOC_NAV_ID = "doc-outline";
export const headingId = (i: number) => `h:${i}`;
/** The heading index a row id stands for, or null for any other id. */
export function parseHeadingId(id: string): number | null {
  const m = /^h:(\d+)$/.exec(id);
  return m ? Number(m[1]) : null;
}

export interface Heading {
  level: number;
  text: string;
}

/** Headings nested by level: a heading's children are the deeper headings that follow it. */
export function outlineItems(outline: readonly Heading[]): NavItem[] {
  const roots: NavItem[] = [];
  const stack: { level: number; item: NavItem }[] = [];
  outline.forEach((h, i) => {
    const item: NavItem = { id: headingId(i), title: h.text || "Untitled heading", icon: "wiki" };
    while (stack.length && stack[stack.length - 1].level >= h.level) stack.pop();
    const parent = stack[stack.length - 1]?.item;
    if (parent) {
      (parent.children ??= []).push(item);
      parent.expanded = true;
    } else roots.push(item);
    stack.push({ level: h.level, item });
  });
  return roots;
}

export function buildDocOutlineNav(i: { title?: string; outline: readonly Heading[] }): NavModel {
  return {
    id: DOC_NAV_ID,
    title: i.title,
    sections: [{ id: "outline", title: "Outline", items: outlineItems(i.outline), emptyText: "No headings yet." }],
    selectedId: null,
  };
}

export interface DocShareInput extends EditorStatusInput {
  /** Nothing to share until the document is there. */
  canShare: boolean;
  pdf: () => void;
  word: () => void;
  markdown: () => void;
  copy: () => void;
  saveToLibrary: () => void;
  promote: () => void;
  libraryPending?: boolean;
  promotePending?: boolean;
}

/** The doc's toolbar: status on the leading side, the Share menu (the web's ExportMenu) trailing. */
export function buildDocActions(i: DocShareInput): NativeAction[] {
  return [
    ...editorStatusActions(i),
    ...(i.canShare
      ? [{
          id: "doc.share",
          label: "Share",
          icon: "upload",
          kind: "menu" as const,
          showsLabel: true,
          menu: [
            { id: "pdf", label: "PDF", run: i.pdf },
            { id: "word", label: "Word (.docx)", run: i.word },
            { id: "markdown", label: "Markdown (.md)", run: i.markdown },
            { id: "sep", separator: true },
            { id: "copy", label: "Copy as rich text", run: i.copy },
            { id: "library", label: "Save to Library", disabled: i.libraryPending, run: i.saveToLibrary },
            { id: "promote", label: "Promote to wiki", disabled: i.promotePending, run: i.promote },
          ],
        }]
      : []),
  ];
}
