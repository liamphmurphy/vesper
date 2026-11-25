// Tree edits on a design body for the editor: find, map, insert, remove,
// duplicate, group, reorder, resize (with constraints) and new nodes. Pure
// and structurally shared, so unchanged pages and nodes keep their identity
// (the canvas re-renders only what changed). Ids follow ADR-designs §3.1.
import { constrain, settle, tokenOr } from "./layout.ts";
import type { ConnectorNode, Design, DesignNode, FrameNode, Page, Paragraph, PathNode, SectionNode, ShapeNode, StickyNode, TextNode } from "./schema.ts";

const B32 = "abcdefghijklmnopqrstuvwxyz234567";
/** A fresh opaque id: prefix plus 10 random base32 characters. */
export function newId(prefix: "n" | "p" | "k" | "a"): string {
  let s = "";
  const bytes = new Uint8Array(10);
  globalThis.crypto.getRandomValues(bytes);
  for (const b of bytes) s += B32[b & 31];
  return `${prefix}_${s}`;
}

export type Box = { x: number; y: number; w: number; h: number };
export type Found = { node: DesignNode; parent: DesignNode | null; page: Page; index: number; depth: number };

export const kids = (n: DesignNode | Page): DesignNode[] => ("children" in n && Array.isArray(n.children) ? n.children : []);
export const isContainer = (n: DesignNode) => n.type === "frame" || n.type === "component" || n.type === "group" || n.type === "section";

/** Where a node lives. */
export function find(d: Design, id: string): Found | undefined {
  for (const page of d.pages) {
    const go = (list: DesignNode[], parent: DesignNode | null, depth: number): Found | undefined => {
      for (let i = 0; i < list.length; i++) {
        const n = list[i];
        if (n.id === id) return { node: n, parent, page, index: i, depth };
        const f = go(kids(n), n, depth + 1);
        if (f) return f;
      }
      return undefined;
    };
    const f = go(page.children, null, 0);
    if (f) return f;
  }
  return undefined;
}

/** Ancestors of a node, nearest first. */
export function ancestors(d: Design, id: string): DesignNode[] {
  const out: DesignNode[] = [];
  let f = find(d, id);
  while (f?.parent) {
    out.push(f.parent);
    f = find(d, f.parent.id);
  }
  return out;
}

function mapList(list: DesignNode[], fn: (n: DesignNode) => DesignNode | null): DesignNode[] {
  let changed = false;
  const out: DesignNode[] = [];
  for (const n of list) {
    let m = fn(n);
    if (m && "children" in m && Array.isArray(m.children)) {
      const ch = mapList(m.children, fn);
      if (ch !== m.children) m = { ...m, children: ch } as DesignNode;
    }
    if (m !== n) changed = true;
    if (m) out.push(m);
  }
  return changed ? out : list;
}

/** fn on every node (null removes it), children after their parent; pages and nodes that don't change keep their identity. */
export function mapTree(d: Design, fn: (n: DesignNode) => DesignNode | null): Design {
  let changed = false;
  const pages = d.pages.map((p) => {
    const ch = mapList(p.children, fn);
    if (ch === p.children) return p;
    changed = true;
    return { ...p, children: ch };
  });
  return changed ? { ...d, pages } : d;
}

export const mapNodes = (d: Design, ids: ReadonlySet<string>, fn: (n: DesignNode) => DesignNode) => mapTree(d, (n) => (ids.has(n.id) ? fn(n) : n));
export const mapNode = (d: Design, id: string, fn: (n: DesignNode) => DesignNode) => mapNodes(d, new Set([id]), fn);

export const mapPage = (d: Design, pageId: string, fn: (p: Page) => Page): Design => {
  let changed = false;
  const pages = d.pages.map((p) => {
    if (p.id !== pageId) return p;
    const n = fn(p);
    if (n !== p) changed = true;
    return n;
  });
  return changed ? { ...d, pages } : d;
};

/** All node ids in a subtree (the node included). */
export function subtreeIds(n: DesignNode, out = new Set<string>()): Set<string> {
  out.add(n.id);
  for (const c of kids(n)) subtreeIds(c, out);
  return out;
}

/**
 * Removes the nodes, with their subtrees and the connectors and links that
 * touch them. Instances of a removed component go too (they'd have nothing
 * to draw), and overrides keyed by removed descendants of a main are dropped.
 */
export function removeNodes(d: Design, ids: ReadonlySet<string>): Design {
  const gone = new Set<string>();
  const add = (id: string) => {
    const f = find(d, id);
    if (f) subtreeIds(f.node, gone);
  };
  for (const id of ids) add(id);
  if (!gone.size) return d;
  // Instances of removed components, until nothing more goes.
  for (let more = true; more; ) {
    more = false;
    mapTree(d, (n) => {
      if (n.type === "instance" && !gone.has(n.id) && gone.has(n.component)) {
        add(n.id);
        more = true;
      }
      return n;
    });
  }
  let out = mapTree(d, (n) => (gone.has(n.id) || (n.type === "connector" && (gone.has(n.from.node) || gone.has(n.to.node))) ? null : n));
  out = mapTree(out, (n) => {
    if (n.type !== "instance" || !n.overrides || !Object.keys(n.overrides).some((k) => gone.has(k))) return n;
    const overrides = Object.fromEntries(Object.entries(n.overrides).filter(([k]) => !gone.has(k)));
    if (Object.keys(overrides).length) return { ...n, overrides };
    const { overrides: _gone, ...rest } = n;
    void _gone;
    return rest as DesignNode;
  });
  const links = d.links.filter((l) => !gone.has(l.from) && !gone.has(l.to));
  return links.length === d.links.length ? out : { ...out, links };
}

/** Inserts nodes into a page (parent = page id) or a container, at index (default: on top). */
export function insertNodes(d: Design, parent: string, nodes: DesignNode[], index?: number): Design {
  const put = (list: DesignNode[]) => {
    const i = index === undefined ? list.length : Math.max(0, Math.min(index, list.length));
    return [...list.slice(0, i), ...nodes, ...list.slice(i)];
  };
  if (d.pages.some((p) => p.id === parent)) return mapPage(d, parent, (p) => ({ ...p, children: put(p.children) }));
  return mapNode(d, parent, (n) => ("children" in n ? ({ ...n, children: put(n.children) } as DesignNode) : n));
}

/** A deep copy with fresh ids; connectors inside it follow their copied ends. */
export function cloneFresh(n: DesignNode, map = new Map<string, string>()): DesignNode {
  const assign = (m: DesignNode) => {
    map.set(m.id, newId("n"));
    for (const c of kids(m)) assign(c);
  };
  assign(n);
  const copy = (m: DesignNode): DesignNode => {
    const c = { ...structuredClone(m), id: map.get(m.id)! } as DesignNode;
    if ("children" in m && Array.isArray(m.children)) (c as { children: DesignNode[] }).children = m.children.map(copy);
    if (c.type === "connector") {
      c.from = { ...c.from, node: map.get(c.from.node) ?? c.from.node };
      c.to = { ...c.to, node: map.get(c.to.node) ?? c.to.node };
    }
    return c;
  };
  return copy(n);
}

/** Copies of the nodes (fresh ids) just above each original, offset; returns the copies' ids. */
export function duplicateNodes(d: Design, ids: string[], offset = 24): { design: Design; ids: string[] } {
  let out = d;
  const made: string[] = [];
  for (const id of ids) {
    const f = find(out, id);
    if (!f || f.node.type === "connector") continue;
    const c = cloneFresh(f.node);
    if (c.type !== "connector" && !inAutoLayout(f.parent)) Object.assign(c, { x: c.x + offset, y: c.y + offset });
    out = insertNodes(out, f.parent?.id ?? f.page.id, [c], f.index + 1);
    made.push(c.id);
  }
  return { design: out, ids: made };
}

export const inAutoLayout = (parent: DesignNode | null) => !!parent && "auto_layout" in parent && !!parent.auto_layout;

export type ZOrder = "forward" | "backward" | "front" | "back";
function reorderList(list: DesignNode[], ids: ReadonlySet<string>, op: ZOrder): DesignNode[] {
  const sel = (n: DesignNode) => ids.has(n.id);
  let out: DesignNode[];
  if (op === "front") out = [...list.filter((n) => !sel(n)), ...list.filter(sel)];
  else if (op === "back") out = [...list.filter(sel), ...list.filter((n) => !sel(n))];
  else {
    out = [...list];
    if (op === "forward") {
      for (let i = out.length - 2; i >= 0; i--) if (sel(out[i]) && !sel(out[i + 1])) [out[i], out[i + 1]] = [out[i + 1], out[i]];
    } else {
      for (let i = 1; i < out.length; i++) if (sel(out[i]) && !sel(out[i - 1])) [out[i], out[i - 1]] = [out[i - 1], out[i]];
    }
  }
  return out.every((n, i) => n === list[i]) ? list : out;
}

/** Z-order within each selected node's own list. */
export function reorder(d: Design, ids: ReadonlySet<string>, op: ZOrder): Design {
  const pages = d.pages.map((p) => {
    const ch = reorderList(p.children, ids, op);
    return ch === p.children ? p : { ...p, children: ch };
  });
  const out = pages.some((p, i) => p !== d.pages[i]) ? { ...d, pages } : d;
  return mapTree(out, (n) => {
    if (!("children" in n) || !Array.isArray(n.children)) return n;
    const ch = reorderList(n.children, ids, op);
    return ch === n.children ? n : ({ ...n, children: ch } as DesignNode);
  });
}

/** Moves a node to another index in its own list (layers drag). */
export function moveWithin(d: Design, id: string, to: number): Design {
  const f = find(d, id);
  if (!f) return d;
  const list = f.parent ? kids(f.parent) : f.page.children;
  const rest = list.filter((n) => n.id !== id);
  const i = Math.max(0, Math.min(to, rest.length));
  const next = [...rest.slice(0, i), f.node, ...rest.slice(i)];
  if (next.every((n, k) => n === list[k])) return d;
  return f.parent ? mapNode(d, f.parent.id, (p) => ({ ...p, children: next }) as DesignNode) : mapPage(d, f.page.id, (p) => ({ ...p, children: next }));
}

/** Boxes of nodes (x, y relative to their common parent). */
export function unionBox(boxes: Box[]): Box | undefined {
  if (!boxes.length) return undefined;
  const l = Math.min(...boxes.map((b) => b.x)), t = Math.min(...boxes.map((b) => b.y));
  const r = Math.max(...boxes.map((b) => b.x + b.w)), b = Math.max(...boxes.map((b) => b.y + b.h));
  return { x: l, y: t, w: r - l, h: b - t };
}

/** The selected siblings as one group at the topmost one's place; undefined unless they share a parent. */
export function groupNodes(d: Design, ids: string[]): { design: Design; id: string } | undefined {
  // Hug sizes are a cache in the body: group from the laid-out boxes.
  d = settle(d);
  const fs = ids.map((id) => find(d, id)).filter((f): f is Found => !!f && f.node.type !== "connector");
  if (fs.length < 2) return undefined;
  const parent = fs[0].parent?.id ?? fs[0].page.id;
  if (fs.some((f) => (f.parent?.id ?? f.page.id) !== parent) || inAutoLayout(fs[0].parent)) return undefined;
  const nodes = fs.sort((a, b) => a.index - b.index).map((f) => f.node as Exclude<DesignNode, { type: "connector" }>);
  const box = unionBox(nodes)!;
  const id = newId("n");
  const group: DesignNode = { id, type: "group", name: "Group", ...box, children: nodes.map((n) => ({ ...n, x: n.x - box.x, y: n.y - box.y })) };
  const top = fs.at(-1)!.index - (fs.length - 1);
  const out = insertNodes(mapTree(d, (n) => (ids.includes(n.id) && n.type !== "connector" ? null : n)), parent, [group], top);
  return { design: out, id };
}

/** Groups (and sections) back into their children, placed where they were. */
export function ungroupNodes(d: Design, ids: string[]): { design: Design; ids: string[] } {
  let out = d;
  const freed: string[] = [];
  for (const id of ids) {
    const f = find(out, id);
    if (!f || f.node.type !== "group") continue;
    const g = f.node;
    const ch = g.children.map((c) => (c.type === "connector" ? c : ({ ...c, x: c.x + g.x, y: c.y + g.y } as DesignNode)));
    freed.push(...ch.map((c) => c.id));
    const list = f.parent ? kids(f.parent) : f.page.children;
    const next = [...list.slice(0, f.index), ...ch, ...list.slice(f.index + 1)];
    out = f.parent ? mapNode(out, f.parent.id, (p) => ({ ...p, children: next }) as DesignNode) : mapPage(out, f.page.id, (p) => ({ ...p, children: next }));
  }
  return { design: out, ids: freed };
}

const r2 = (n: number) => Math.round(n * 100) / 100;

/** resizeNode on a node of the design, after laying it out (a hug node's stored size may be stale). */
export const resizeIn = (d: Design, id: string, b: Box | ((n: DesignNode) => Box)): Design =>
  mapNode(settle(d), id, (n) => (n.type === "connector" ? n : resizeNode(n, typeof b === "function" ? b(n) : b)));

/** Scales a path's d (node coordinates) by kx, ky. */
export function scalePath(d: string, kx: number, ky: number): string {
  return d.replace(/(-?[\d.]+(?:e-?\d+)?)[ ,]+(-?[\d.]+(?:e-?\d+)?)/g, (_, x, y) => `${r2(+x * kx)} ${r2(+y * ky)}`);
}

/**
 * A node at a new box (relative to its parent). Children of a resized
 * container without auto layout follow their constraints; a group's
 * children and a path's points scale with it.
 */
export function resizeNode(n: DesignNode, b: Box): DesignNode {
  if (n.type === "connector") return n;
  const w = Math.max(1, r2(b.w)), h = Math.max(1, r2(b.h));
  const out = { ...n, x: r2(b.x), y: r2(b.y), w, h } as DesignNode;
  if (w === n.w && h === n.h) return out;
  if (out.type === "path") (out as PathNode).d = scalePath((n as PathNode).d, w / n.w, h / n.h);
  if (n.type === "group") {
    const kx = w / n.w, ky = h / n.h;
    (out as { children: DesignNode[] }).children = n.children.map((c) => (c.type === "connector" ? c : resizeNode(c, { x: c.x * kx, y: c.y * ky, w: c.w * kx, h: c.h * ky })));
  } else if ((n.type === "frame" || n.type === "component" || n.type === "section") && !("auto_layout" in n && n.auto_layout)) {
    (out as { children: DesignNode[] }).children = n.children.map((c) => constrain(c, n.w, n.h, w, h));
  }
  // A hug axis the person resized by hand becomes fixed.
  if ("sizing" in out && out.sizing) {
    const s = { ...out.sizing };
    if (w !== n.w && s.w === "hug") delete s.w;
    if (h !== n.h && s.h === "hug") delete s.h;
    (out as { sizing?: object }).sizing = Object.keys(s).length ? s : undefined;
  }
  return out;
}

// ---- New nodes ----

/** Device presets (ADR §3.2): they only seed the frame size. */
export const PRESETS: { id: string; label: string; w: number; h: number }[] = [
  { id: "iphone-15", label: "iPhone 15", w: 393, h: 852 },
  { id: "iphone-15-pro-max", label: "iPhone 15 Pro Max", w: 430, h: 932 },
  { id: "android", label: "Android", w: 412, h: 915 },
  { id: "ipad", label: "iPad", w: 820, h: 1180 },
  { id: "desktop", label: "Desktop", w: 1440, h: 900 },
  { id: "web", label: "Web", w: 1280, h: 800 },
];
export const presetLabel = (id?: string) => PRESETS.find((p) => p.id === id)?.label;

export const newFrame = (b: Box, preset?: string, name = "Frame"): FrameNode => ({ id: newId("n"), type: "frame", name, ...b, fill: "#FFFFFF", clip: true, children: [], ...(preset ? { preset } : {}) });
export const newShape = (shape: "rect" | "ellipse" | string, b: Box): ShapeNode => ({ id: newId("n"), type: "shape", shape, name: shape === "ellipse" ? "Ellipse" : "Rectangle", ...b, fill: "#D9D9E3" });
export const newText = (x: number, y: number, text = "", size = 16): TextNode => ({
  id: newId("n"), type: "text", name: "Text", x, y, w: 1, h: size * 1.2, sizing: { w: "hug", h: "hug" },
  paragraphs: [{ runs: [{ text, size }] }],
});

export const STICKY_SIZE = 200;
export const newSticky = (x: number, y: number, text = "", author?: string): StickyNode => ({
  id: newId("n"), type: "sticky", x, y, w: STICKY_SIZE, h: STICKY_SIZE, text, ...(author ? { author } : {}),
});
export const newSection = (d: Design, b: Box, name = "Section"): SectionNode => ({ id: newId("n"), type: "section", name, ...b, fill: tokenOr(d, "surface-raised"), children: [] });

/**
 * Draws a section over part of a page: the page's top-level nodes wholly
 * inside the box move into it (relative to it), so moving the section later
 * moves them along. Page connectors whose ends both move in go with them.
 */
export function wrapInSection(d: Design, pageId: string, section: SectionNode): Design {
  const page = d.pages.find((p) => p.id === pageId);
  if (!page) return d;
  const inside = (n: DesignNode) =>
    n.type !== "connector" && n.x >= section.x && n.y >= section.y && n.x + n.w <= section.x + section.w && n.y + n.h <= section.y + section.h && !n.locked;
  const moved = new Set(page.children.filter(inside).map((n) => n.id));
  const takes = (n: DesignNode) => (n.type === "connector" ? moved.has(n.from.node) && moved.has(n.to.node) : moved.has(n.id));
  const shift = ([x, y]: [number, number]): [number, number] => [r2(x - section.x), r2(y - section.y)];
  const children = page.children
    .filter(takes)
    .map((n) => (n.type === "connector" ? (n.points ? { ...n, points: n.points.map(shift) } : n) : ({ ...n, x: r2(n.x - section.x), y: r2(n.y - section.y) } as DesignNode)));
  const rest = page.children.filter((n) => !takes(n));
  // The section goes under everything else it was drawn over, at the bottom of the page's paint order.
  return mapPage(d, pageId, (p) => ({ ...p, children: [{ ...section, children }, ...rest] }));
}

/**
 * Connects two nodes on the same page with a connector in their lowest common
 * container that isn't a group (ADR §3.1). Undefined when it can't: the same
 * node, a connector, or different pages.
 */
export function connectNodes(d: Design, from: string, to: string, extra: Partial<ConnectorNode> = {}): { design: Design; id: string } | undefined {
  if (from === to) return undefined;
  const a = find(d, from), b = find(d, to);
  if (!a || !b || a.page.id !== b.page.id || a.node.type === "connector" || b.node.type === "connector") return undefined;
  const up = (id: string) => ancestors(d, id).map((n) => n.id);
  const bUp = new Set(up(to));
  let container: string = a.page.id;
  for (const id of up(from)) {
    if (!bUp.has(id)) continue;
    container = id;
    break;
  }
  // Never inside a group: go up to the group's nearest non-group ancestor.
  for (;;) {
    const f = container === a.page.id ? undefined : find(d, container);
    if (!f || f.node.type !== "group") break;
    container = f.parent?.id ?? a.page.id;
  }
  const c: ConnectorNode = { id: newId("n"), type: "connector", from: { node: from }, to: { node: to }, ...extra };
  return { design: insertNodes(d, container, [c]), id: c.id };
}

/** A path node from points in page coordinates (the pen and line tools); closed joins the ends. */
export function pathFrom(points: [number, number][], closed: boolean, name = "Path"): PathNode | undefined {
  if (points.length < 2) return undefined;
  const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
  const x = Math.min(...xs), y = Math.min(...ys);
  const w = Math.max(1, Math.max(...xs) - x), h = Math.max(1, Math.max(...ys) - y);
  const d = points.map(([px, py], i) => `${i ? "L" : "M"}${r2(px - x)} ${r2(py - y)}`).join(" ") + (closed ? " Z" : "");
  return { id: newId("n"), type: "path", name, x: r2(x), y: r2(y), w: r2(w), h: r2(h), d, stroke: "#16161D", stroke_width: 2, ...(closed ? { fill: "#D9D9E3" } : {}), cap: "round", join: "round" };
}

/** Plain text of a text node, paragraphs joined by newlines. */
export const plainText = (ps: Paragraph[]) => ps.map((p) => p.runs.map((r) => r.text).join("")).join("\n");

/** Replaces the text, keeping the first run's style per paragraph. */
export function withPlainText(ps: Paragraph[], text: string): Paragraph[] {
  const lines = text.split("\n");
  return lines.map((line, i) => {
    const src = ps[Math.min(i, ps.length - 1)] ?? { runs: [{ text: "", size: 16 }] };
    return { ...src, runs: [{ ...src.runs[0], text: line }] };
  });
}

/** The name the layers panel shows. */
export function labelOf(n: DesignNode): string {
  if (n.name) return n.name;
  if (n.type === "text") return plainText(n.paragraphs).slice(0, 40) || "Text";
  if (n.type === "shape") return n.shape === "ellipse" ? "Ellipse" : "Rectangle";
  if (n.type === "sticky") return `Sticky${n.author ? ` · ${n.author}` : ""}`;
  return n.type[0].toUpperCase() + n.type.slice(1);
}

/** The ids of every node in a page in paint order, top-level first (Select all). */
export const topLevelIds = (p: Page) => p.children.filter((n) => n.type !== "connector").map((n) => n.id);

/**
 * Moves a node into another parent (a page id or a container id), keeping
 * where it is on the page: abs is the node's absolute top-left, origin the
 * new parent's (0, 0 for a page). Goes on top of the new parent's children.
 */
export function reparent(d: Design, id: string, target: string, abs: { x: number; y: number }, origin: { x: number; y: number }): Design {
  const f = find(d, id);
  if (!f || f.node.type === "connector" || (f.parent?.id ?? f.page.id) === target) return d;
  if (subtreeIds(f.node).has(target)) return d;
  const moved = { ...f.node, x: r2(abs.x - origin.x), y: r2(abs.y - origin.y) } as DesignNode;
  const without = mapTree(d, (n) => (n.id === id ? null : n));
  return insertNodes(without, target, [moved]);
}
