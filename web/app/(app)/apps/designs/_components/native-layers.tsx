"use client";

import { useCallback, useMemo, useState } from "react";
import { ancestors, find, kids, labelOf, mapNode, mapPage, newId } from "@/lib/designs/edit";
import type { Design, DesignNode, Page } from "@/lib/designs/schema";
import { buildDesignNav, parseDesignCommand, type LayerRow } from "@/lib/native-shell/models/design-editor";
import { NativeRenameDialog } from "@/components/shell/native-rename-dialog";

type Edit = (fn: (d: Design) => Design, key?: string) => void;

function layerCommands(design: Design, onPage: (id: string) => void, onEdit: Edit) {
  return {
    /** Adds a page after the others, opens it, and returns its id. */
    addPage: (): string => {
      const id = newId("p");
      onEdit((d) => ({ ...d, pages: [...d.pages, { id, name: `Page ${d.pages.length + 1}`, children: [] }] }));
      onPage(id);
      return id;
    },
    removePage: (id: string) => {
      if (design.pages.length < 2) return;
      const i = design.pages.findIndex((p) => p.id === id);
      onEdit((d) => ({ ...d, pages: d.pages.filter((p) => p.id !== id) }));
      onPage(design.pages[i === 0 ? 1 : i - 1].id);
    },
    /** Renames a page or a layer; a blank name changes nothing. */
    rename: (id: string, name: string) => {
      const n = name.trim();
      if (!n) return;
      if (design.pages.some((p) => p.id === id)) onEdit((d) => mapPage(d, id, (p) => (p.name === n ? p : { ...p, name: n.slice(0, 200) })));
      else onEdit((d) => mapNode(d, id, (x) => (x.name === n ? x : ({ ...x, name: n.slice(0, 200) } as DesignNode))));
    },
  };
}

const toRow = (n: DesignNode): LayerRow => ({
  id: n.id,
  label: labelOf(n),
  type: n.type,
  visible: n.visible !== false,
  locked: n.type !== "connector" && !!n.locked,
  togglable: n.type !== "connector",
  children: kids(n).map(toRow),
});

/**
 * The layers panel (pages and the page's layer tree) as rows in the Mac app's sidebar, with the
 * same commands: pick a page or layer, add / rename / delete pages, rename / hide / lock layers.
 * Returns the navigator for EditorLayout's `nativeLeft` and the dialog its Rename… opens.
 */
export function useNativeLayers({ design, page, title, selected, onSelect, onPage, onEdit, readOnly }: {
  design?: Design;
  page?: Page;
  title: string;
  selected: string[];
  onSelect: (ids: string[]) => void;
  onPage: (id: string) => void;
  onEdit: Edit;
  readOnly: boolean;
}) {
  const [open, setOpen] = useState<ReadonlySet<string>>(() => new Set());
  const [renaming, setRenaming] = useState<{ id: string; value: string; kind: "page" | "layer" } | null>(null);

  // The user's open layers, and the selection's ancestors (the web panel opens those by itself).
  const opened = useMemo(() => {
    const o = new Set(open);
    if (design) for (const id of selected) for (const a of ancestors(design, id)) o.add(a.id);
    return o;
  }, [open, design, selected]);

  const model = useMemo(
    () =>
      design && page
        ? buildDesignNav({
            title,
            pages: design.pages.map((p) => ({ id: p.id, name: p.name })),
            currentPageId: page.id,
            layers: page.children.map(toRow),
            selected,
            open: opened,
            readOnly,
          })
        : undefined,
    [design, page, title, selected, opened, readOnly],
  );

  const onCommand = useCallback(
    (raw: Parameters<typeof parseDesignCommand>[0]) => {
      const c = parseDesignCommand(raw);
      if (!c || !design) return;
      const edit = layerCommands(design, onPage, onEdit);
      switch (c.type) {
        case "page":
          return onPage(c.id);
        case "select":
          return onSelect([c.id]);
        case "toggle":
          return setOpen((o) => {
            const next = new Set(o);
            if (c.expanded) next.add(c.id);
            else next.delete(c.id);
            return next;
          });
      }
      if (readOnly) return;
      switch (c.type) {
        case "addPage": {
          const id = edit.addPage();
          return setRenaming({ id, value: `Page ${design.pages.length + 1}`, kind: "page" });
        }
        case "removePage":
          return edit.removePage(c.id);
        case "renamePage":
          return setRenaming({ id: c.id, value: design.pages.find((p) => p.id === c.id)?.name ?? "", kind: "page" });
        case "renameLayer": {
          const n = find(design, c.id)?.node;
          return n && setRenaming({ id: c.id, value: n.name ?? labelOf(n), kind: "layer" });
        }
        case "toggleVisible":
          return onEdit((d) => mapNode(d, c.id, (x) => ({ ...x, visible: x.visible === false ? undefined : false }) as DesignNode));
        case "toggleLock":
          return onEdit((d) => mapNode(d, c.id, (x) => (x.type === "connector" ? x : ({ ...x, locked: x.locked ? undefined : true } as DesignNode))));
      }
    },
    [design, onPage, onEdit, onSelect, readOnly],
  );

  const dialog = (
    <NativeRenameDialog
      request={renaming && { heading: renaming.kind === "page" ? "Rename page" : "Rename layer", label: renaming.kind === "page" ? "Page name" : "Layer name", value: renaming.value, maxLength: 200 }}
      onClose={() => setRenaming(null)}
      onSubmit={(name) => renaming && design && layerCommands(design, onPage, onEdit).rename(renaming.id, name)}
    />
  );
  return { nativeLeft: model && { model, onCommand }, dialog };
}
