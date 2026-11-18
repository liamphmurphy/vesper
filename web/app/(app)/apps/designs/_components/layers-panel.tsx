"use client";

import { useState } from "react";
import { cx } from "@/lib/cx";
import { ancestors, kids, labelOf, mapNode, mapPage, newId } from "@/lib/designs/edit";
import type { Design, DesignNode, Page } from "@/lib/designs/schema";
import { hoverVisible } from "@/lib/reveal";

const GLYPH: Record<string, string> = { frame: "#", component: "◇", instance: "◇", group: "▢", section: "⌗", shape: "▭", path: "∿", text: "T", image: "▣", sticky: "▤", connector: "→" };

type Props = {
  design: Design;
  page: Page;
  onPage: (id: string) => void;
  selected: string[];
  onSelect: (ids: string[]) => void;
  onEdit: (fn: (d: Design) => Design, key?: string) => void;
  readOnly: boolean;
};

type Edit = (fn: (d: Design) => Design, key?: string) => void;

/** Adding, deleting and renaming pages and layers: what the panel's controls and the Mac app's sidebar rows both call. */
export function layerCommands(design: Design, onPage: (id: string) => void, onEdit: Edit) {
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

/** Pages and the layers of the current page (docs/design/designs-editor.svg, left column). */
export function LayersPanel({ design, page, onPage, selected, onSelect, onEdit, readOnly }: Props) {
  const [renaming, setRenaming] = useState<string>();
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  // Ancestors of the selection open by themselves.
  const opened = new Set(open);
  for (const id of selected) for (const a of ancestors(design, id)) opened.add(a.id);

  const cmd = layerCommands(design, onPage, onEdit);
  const addPage = () => setRenaming(cmd.addPage());
  const removePage = cmd.removePage;
  const rename = (id: string, name: string) => {
    setRenaming(undefined);
    cmd.rename(id, name);
  };

  const row = (n: DesignNode, depth: number) => {
    const sel = selected.includes(n.id);
    const ch = kids(n);
    const isOpen = opened.has(n.id);
    return (
      <li key={n.id} role="treeitem" aria-selected={sel} aria-expanded={ch.length ? isOpen : undefined} aria-label={labelOf(n)}>
        <div
          className={cx("group flex h-[26px] cursor-default items-center gap-1 rounded-md pr-1 text-13", sel ? "bg-accent-soft text-fg" : "text-fg-2 hover:bg-hover", n.visible === false && "opacity-50")}
          style={{ paddingLeft: 6 + depth * 14 }}
          onClick={(e) => onSelect(e.shiftKey || e.metaKey ? (sel ? selected.filter((s) => s !== n.id) : [...selected, n.id]) : [n.id])}
          onDoubleClick={() => !readOnly && setRenaming(n.id)}
        >
          <button
            type="button"
            aria-label={isOpen ? "Collapse" : "Expand"}
            tabIndex={-1}
            className={cx("grid size-4 flex-none place-items-center text-10 text-fg-tertiary", !ch.length && "invisible")}
            onClick={(e) => {
              e.stopPropagation();
              setOpen((o) => {
                const next = new Set(o);
                if (isOpen) next.delete(n.id);
                else next.add(n.id);
                return next;
              });
            }}
          >
            {isOpen ? "▾" : "▸"}
          </button>
          <span aria-hidden className={cx("w-3.5 flex-none text-center text-11", n.type === "component" || n.type === "instance" ? "text-accent" : "text-fg-tertiary")}>{GLYPH[n.type]}</span>
          {renaming === n.id ? (
            <input
              autoFocus
              aria-label="Layer name"
              defaultValue={n.name ?? labelOf(n)}
              maxLength={200}
              className="h-[22px] min-w-0 flex-1 rounded border border-accent bg-surface px-1 text-13 text-fg outline-none"
              onBlur={(e) => rename(n.id, e.target.value)}
              onKeyDown={(e) => {
                e.stopPropagation();
                if (e.key === "Enter") rename(n.id, e.currentTarget.value);
                if (e.key === "Escape") setRenaming(undefined);
              }}
            />
          ) : (
            <span className={cx("min-w-0 flex-1 truncate", (n.type === "component" || n.type === "instance") && "text-accent")}>{labelOf(n)}</span>
          )}
          {!readOnly && n.type !== "connector" && (
            <>
              <button
                type="button"
                aria-label={n.locked ? `Unlock ${labelOf(n)}` : `Lock ${labelOf(n)}`}
                className={cx("grid size-5 place-items-center rounded text-10 text-fg-tertiary hover:text-fg", !n.locked && hoverVisible())}
                onClick={(e) => {
                  e.stopPropagation();
                  onEdit((d) => mapNode(d, n.id, (x) => (x.type === "connector" ? x : ({ ...x, locked: x.locked ? undefined : true } as DesignNode))));
                }}
              >
                {n.locked ? "🔒" : "🔓"}
              </button>
              <button
                type="button"
                aria-label={n.visible === false ? `Show ${labelOf(n)}` : `Hide ${labelOf(n)}`}
                className={cx("grid size-5 place-items-center rounded text-11 text-fg-tertiary hover:text-fg", n.visible !== false && hoverVisible())}
                onClick={(e) => {
                  e.stopPropagation();
                  onEdit((d) => mapNode(d, n.id, (x) => ({ ...x, visible: x.visible === false ? undefined : false }) as DesignNode));
                }}
              >
                {n.visible === false ? "◌" : "●"}
              </button>
            </>
          )}
        </div>
        {ch.length > 0 && isOpen && <ul role="group">{[...ch].reverse().map((c) => row(c, depth + 1))}</ul>}
      </li>
    );
  };

  return (
    <div className="flex min-h-0 flex-col">
      <div className="flex items-center justify-between px-3 pb-1 pt-3">
        <h2 className="text-11 font-semibold uppercase tracking-[0.08em] text-fg-tertiary">Pages</h2>
        {!readOnly && (
          <button type="button" aria-label="Add a page" className="grid size-6 place-items-center rounded-md text-fg-secondary hover:bg-hover" onClick={addPage}>
            +
          </button>
        )}
      </div>
      <ul aria-label="Pages" className="flex flex-col gap-px px-2 pb-2">
        {design.pages.map((pg) => (
          <li key={pg.id} className="group relative">
            {renaming === pg.id ? (
              <input
                autoFocus
                aria-label="Page name"
                defaultValue={pg.name}
                maxLength={200}
                className="h-[28px] w-full rounded-md border border-accent bg-surface px-2 text-13 text-fg outline-none"
                onBlur={(e) => rename(pg.id, e.target.value)}
                onKeyDown={(e) => {
                  e.stopPropagation();
                  if (e.key === "Enter") rename(pg.id, e.currentTarget.value);
                  if (e.key === "Escape") setRenaming(undefined);
                }}
              />
            ) : (
              <button
                type="button"
                aria-current={pg.id === page.id ? "page" : undefined}
                className={cx("flex h-[28px] w-full items-center rounded-md px-2 text-left text-13", pg.id === page.id ? "bg-selected text-fg" : "text-fg-2 hover:bg-hover")}
                onClick={() => onPage(pg.id)}
                onDoubleClick={() => !readOnly && setRenaming(pg.id)}
              >
                <span className="truncate">{pg.name}</span>
              </button>
            )}
            {!readOnly && design.pages.length > 1 && renaming !== pg.id && (
              <button type="button" aria-label={`Delete page ${pg.name}`} className={cx("absolute right-1 top-1 grid size-5 place-items-center rounded text-11 text-fg-tertiary hover:bg-hover hover:text-fg", hoverVisible())} onClick={() => removePage(pg.id)}>
                ×
              </button>
            )}
          </li>
        ))}
      </ul>
      <div className="border-t border-border-subtle px-3 pb-1 pt-3">
        <h2 className="text-11 font-semibold uppercase tracking-[0.08em] text-fg-tertiary">Layers</h2>
      </div>
      <ul role="tree" aria-label="Layers" className="min-h-0 flex-1 overflow-y-auto px-2 pb-3">
        {page.children.length === 0 ? <li className="px-2 py-3 text-12 text-fg-tertiary">Nothing on this page yet. Draw a frame (F) to start.</li> : [...page.children].reverse().map((n) => row(n, 0))}
      </ul>
    </div>
  );
}
