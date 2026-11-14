// Reviewing a persona's design suggestion (ADR-designs §3.7, designs-review.svg):
// each op of a proposal is one change, classified as added / changed /
// removed with the node to pin and the box to pin it on, a Before / After
// preview made by applying the ops to a copy, and the dependency rules (op j
// needs the op that creates what it points at). Pure: unit-tested in
// lib/designs-review.test.mjs.
import { find, insertNodes, kids, labelOf, mapNode, mapPage, plainText, removeNodes, withPlainText, type Box } from "./edit.ts";
import { makeLayout } from "./layout.ts";
import type { Design, DesignNode, Page } from "./schema.ts";
import { normalize } from "./schema.ts";
import { settle } from "./layout.ts";
import * as W from "./doc.ts";
import { mergeDesigns } from "./merge.ts";

/** One op of a proposal: {op, why, …fields}, ids minted by the server. */
export type DesignOp = { op: string; why?: string; [k: string]: unknown };
export type ChangeKind = "added" | "changed" | "removed";
export type State = "accepted" | "rejected";
export type Decision = { state: State; reason?: string };
export type Decisions = Record<number, Decision | undefined>;

export type Change = {
  i: number;
  op: DesignOp;
  kind: ChangeKind;
  title: string;
  why: string;
  /** The node (or page) the change is about: what Discuss comments on and the pin sits on. */
  target?: string;
  /** The page the change is on. */
  page?: string;
  /** Where to pin it, in page coordinates. */
  box?: Box;
  /** Earlier ops this one needs (they create something it points at). */
  needs: number[];
};

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const obj = (v: unknown): Record<string, unknown> | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined);
const children = (n: Record<string, unknown>): Record<string, unknown>[] => (Array.isArray(n.children) ? n.children.filter((c): c is Record<string, unknown> => !!obj(c)) : []);

// ---- Dependencies: mirrors server/internal/design/ops.go Creates / Deps ----

/** The ids an op adds. */
export function creates(op: DesignOp): string[] {
  const out: string[] = [];
  const collect = (n: Record<string, unknown>) => {
    if (typeof n.id === "string") out.push(n.id);
    children(n).forEach(collect);
  };
  switch (op.op) {
    case "add_page":
    case "add_node": {
      const n = obj(op.op === "add_node" ? op.node : op.page);
      if (n) collect(n);
      break;
    }
    case "connect":
    case "add_sticky":
    case "instantiate":
    case "add_link":
      if (typeof op.id === "string") out.push(op.id);
      break;
  }
  return out;
}

const REF_KEYS = ["id", "parent", "after", "before", "page", "from", "to", "component", "node"];

/** For each op, the earlier ops that create something it points at: accepting it needs them. */
export function dependencies(ops: DesignOp[]): number[][] {
  const by = new Map<string, number>();
  return ops.map((op, j) => {
    const made = creates(op);
    const needs: number[] = [];
    for (const k of REF_KEYS) {
      const r = op[k];
      if (typeof r !== "string" || made.includes(r)) continue;
      const i = by.get(r);
      if (i !== undefined && !needs.includes(i)) needs.push(i);
    }
    for (const id of made) by.set(id, j);
    return needs;
  });
}

const closure = (start: number, next: (i: number) => number[]): Set<number> => {
  const seen = new Set<number>();
  const go = (i: number) => {
    for (const k of next(i)) if (!seen.has(k)) {
        seen.add(k);
        go(k);
      }
  };
  go(start);
  return seen;
};

/** Decides one op. Accepting it accepts everything it needs; rejecting it rejects everything that needs it. */
export function decide(deps: number[][], decisions: Decisions, i: number, state: State, reason?: string): Decisions {
  const out = { ...decisions };
  if (state === "accepted") {
    for (const k of [i, ...closure(i, (x) => deps[x] ?? [])]) out[k] = { state };
  } else {
    out[i] = { state, ...(reason?.trim() ? { reason: reason.trim() } : {}) };
    const needing = (x: number) => deps.flatMap((d, j) => (d.includes(x) ? [j] : []));
    for (const k of closure(i, needing)) out[k] = { state };
  }
  return out;
}

/** Accept or reject every undecided change (dependencies followed). */
export function decideRest(deps: number[][], decisions: Decisions, count: number, state: State): Decisions {
  let out = decisions;
  for (let i = 0; i < count; i++) if (!out[i]) out = decide(deps, out, i, state);
  return out;
}

export const undecided = (decisions: Decisions, count: number) => Array.from({ length: count }, (_, i) => i).filter((i) => !decisions[i]);

/** The resolve request body: exactly one decision per op, in order; undefined until every op is decided. */
export function resolveBody(decisions: Decisions, count: number): { decisions: { i: number; state: State; reason?: string }[] } | undefined {
  const list: { i: number; state: State; reason?: string }[] = [];
  for (let i = 0; i < count; i++) {
    const d = decisions[i];
    if (!d) return undefined;
    list.push({ i, state: d.state, ...(d.reason ? { reason: d.reason } : {}) });
  }
  return { decisions: list };
}

// ---- Applying ops to a copy ----

function pageOf(d: Design, id: string): Page | undefined {
  return d.pages.find((p) => p.id === id);
}

/** Inserts node under parent after the sibling after, before the sibling before, or on top. */
function insertAt(d: Design, parent: string, node: DesignNode, after?: string, before?: string): Design {
  const list = pageOf(d, parent)?.children ?? kids(find(d, parent)?.node ?? ({ children: [] } as unknown as DesignNode));
  const at = after ? list.findIndex((n) => n.id === after) + 1 : before ? list.findIndex((n) => n.id === before) : undefined;
  return insertNodes(d, parent, [node], at === undefined || at < 0 || (after && at === 0) ? undefined : at);
}

/** One op on a design; undefined when it no longer applies (its target is gone, a field is unknown). */
export function applyOp(d: Design, op: DesignOp): Design | undefined {
  const id = str(op.id);
  switch (op.op) {
    case "add_page": {
      const page = obj(op.page);
      if (!page) return undefined;
      const p = { children: [], ...page } as unknown as Page;
      const at = op.after ? d.pages.findIndex((x) => x.id === op.after) + 1 : d.pages.length;
      return { ...d, pages: [...d.pages.slice(0, at), p, ...d.pages.slice(at)] };
    }
    case "set_page":
      if (!pageOf(d, id)) return undefined;
      return mapPage(d, id, (p) => {
        const next: Record<string, unknown> = { ...p };
        for (const k of ["name", "background"]) {
          if (!(k in op)) continue;
          if (op[k] === null) delete next[k];
          else next[k] = op[k];
        }
        return next as unknown as Page;
      });
    case "remove_page":
      return pageOf(d, id) && d.pages.length > 1 ? { ...d, pages: d.pages.filter((p) => p.id !== id) } : undefined;
    case "add_node": {
      const node = obj(op.node);
      return node && (pageOf(d, str(op.parent)) || find(d, str(op.parent))) ? insertAt(d, str(op.parent), node as unknown as DesignNode, str(op.after) || undefined, str(op.before) || undefined) : undefined;
    }
    case "set_node": {
      const fields = obj(op.fields);
      if (!fields || !find(d, id)) return undefined;
      return mapNode(d, id, (n) => {
        const next: Record<string, unknown> = { ...n };
        for (const [k, v] of Object.entries(fields)) {
          if (v === null) delete next[k];
          else next[k] = v;
        }
        return next as unknown as DesignNode;
      });
    }
    case "move_node": {
      const f = find(d, id);
      if (!f) return undefined;
      let out = mapNode(d, id, (n) => ({ ...n, ...("x" in op ? { x: op.x } : {}), ...("y" in op ? { y: op.y } : {}) }) as DesignNode);
      const parent = str(op.parent), after = str(op.after), before = str(op.before);
      const sibling = after || before;
      if (parent || sibling) {
        const target = parent || find(out, sibling)?.parent?.id || find(out, sibling)?.page.id;
        const node = find(out, id)!.node;
        if (!target) return undefined;
        if (sibling === id) return out;
        out = removeNodes(out, new Set([id]));
        out = insertAt(out, target, node, after || undefined, before || undefined);
      }
      return out;
    }
    case "remove_node":
      return find(d, id) ? removeNodes(d, new Set([id])) : undefined;
    case "set_text": {
      const f = find(d, id);
      if (!f || f.node.type !== "text") return undefined;
      return mapNode(d, id, (n) => {
        if (n.type !== "text") return n;
        if (Array.isArray(op.paragraphs)) return { ...n, paragraphs: op.paragraphs as typeof n.paragraphs };
        return typeof op.text === "string" ? { ...n, paragraphs: withPlainText(n.paragraphs, op.text) } : n;
      });
    }
    case "add_sticky": {
      const page = pageOf(d, str(op.page));
      if (!page) return undefined;
      const node = { id, type: "sticky", x: op.x, y: op.y, w: 160, h: 120, text: op.text, color: op.color, ...(op.author ? { author: op.author } : {}) };
      return insertNodes(d, page.id, [node as unknown as DesignNode]);
    }
    case "connect": {
      const from = find(d, str(op.from)), to = find(d, str(op.to));
      if (!from || !to) return undefined;
      const skip = new Set(["op", "why", "from", "to", "from_anchor", "to_anchor"]);
      const node: Record<string, unknown> = { type: "connector", from: { node: op.from, ...(op.from_anchor ? { anchor: op.from_anchor } : {}) }, to: { node: op.to, ...(op.to_anchor ? { anchor: op.to_anchor } : {}) } };
      for (const [k, v] of Object.entries(op)) if (!skip.has(k)) node[k] = v;
      return insertNodes(d, from.page.id, [node as unknown as DesignNode]);
    }
    case "add_link":
      return { ...d, links: [...d.links, { id, from: op.from, to: op.to, trigger: op.trigger ?? "click", transition: op.transition ?? "instant", ...(op.delay_ms !== undefined ? { delay_ms: op.delay_ms } : {}), ...(op.duration_ms !== undefined ? { duration_ms: op.duration_ms } : {}) } as Design["links"][number]] };
    case "set_link":
      return d.links.some((l) => l.id === id) ? { ...d, links: d.links.map((l) => (l.id === id ? ({ ...l, ...Object.fromEntries(Object.entries(op).filter(([k]) => !["op", "why", "id"].includes(k))) } as typeof l) : l)) } : undefined;
    case "remove_link":
      return d.links.some((l) => l.id === id) ? { ...d, links: d.links.filter((l) => l.id !== id) } : undefined;
    case "create_component":
      return find(d, id)?.node.type === "frame" ? mapNode(d, id, (n) => ({ ...n, type: "component", ...(op.name ? { name: op.name } : {}) }) as DesignNode) : undefined;
    case "instantiate": {
      const parent = str(op.parent);
      if (!find(d, str(op.component)) || !(pageOf(d, parent) || find(d, parent))) return undefined;
      const node = { id, type: "instance", component: op.component, x: op.x, y: op.y, ...(op.overrides ? { overrides: op.overrides } : {}) };
      return insertAt(d, parent, node as unknown as DesignNode, str(op.after) || undefined);
    }
    case "set_overrides":
      return find(d, id) ? mapNode(d, id, (n) => ({ ...n, overrides: op.overrides }) as DesignNode) : undefined;
    default:
      // detach, set_token, link_ticket…: reviewed and resolved on the server; no preview here.
      return undefined;
  }
}

/** The ops applied in order, each on the result of the last; one that no longer applies is skipped. keep picks which. */
export function applyOps(d: Design, ops: DesignOp[], keep: (i: number) => boolean = () => true): Design {
  let out = d;
  ops.forEach((op, i) => {
    if (!keep(i)) return;
    try {
      out = applyOp(out, op) ?? out;
    } catch {
      // A malformed op previews as nothing.
    }
  });
  return out;
}

/** A design as the editor draws it: laid out and normalised, falling back to the raw copy. */
export function preview(d: Design): Design {
  try {
    return normalize(settle(d)).design;
  } catch {
    return d;
  }
}

// ---- Classifying ----

function boxes(d: Design): Map<string, { box: Box; page: string }> {
  const out = new Map<string, { box: Box; page: string }>();
  try {
    const lay = makeLayout(d);
    for (const p of d.pages) for (const [id, box] of lay.layoutPage(p).boxes) out.set(id, { box, page: p.id });
  } catch {
    // An unlaid design pins nothing.
  }
  return out;
}

const quote = (s: string) => `“${s}”`;

/** The node or page an op is about, and how it changes the design. */
function describe(op: DesignOp, d: Design): { kind: ChangeKind; title: string; target?: string } {
  const name = (id: unknown) => {
    const n = find(d, str(id))?.node;
    return n ? quote(labelOf(n)) : pageOf(d, str(id)) ? quote(pageOf(d, str(id))!.name) : "a layer";
  };
  const id = str(op.id);
  switch (op.op) {
    case "add_page":
      return { kind: "added", title: `Add page ${quote(str(obj(op.page)?.name) || "Page")}`, target: str(obj(op.page)?.id) || undefined };
    case "set_page":
      return { kind: "changed", title: `Change page ${name(id)}`, target: id };
    case "remove_page":
      return { kind: "removed", title: `Remove page ${name(id)}`, target: id };
    case "add_node": {
      const n = obj(op.node) ?? {};
      const label = str(n.name) || (n.type === "text" ? Array.isArray(n.paragraphs) ? plainText(n.paragraphs as never).slice(0, 40) : str(n.text) : "") || str(n.type);
      return { kind: "added", title: `Add ${str(n.type) || "layer"} ${quote(label || "layer")}`, target: str(n.id) || undefined };
    }
    case "set_node": {
      const keys = Object.keys(obj(op.fields) ?? {});
      return { kind: "changed", title: `Change ${name(id)}${keys.length ? `: ${keys.slice(0, 3).join(", ")}${keys.length > 3 ? "…" : ""}` : ""}`, target: id };
    }
    case "move_node":
      return { kind: "changed", title: `Move ${name(id)}`, target: id };
    case "remove_node":
      return { kind: "removed", title: `Remove ${name(id)}`, target: id };
    case "set_text":
      return { kind: "changed", title: `Edit text ${name(id)}`, target: id };
    case "connect":
      return { kind: "added", title: `Connect ${name(op.from)} → ${name(op.to)}`, target: id || str(op.from) };
    case "add_sticky":
      return { kind: "added", title: `Add sticky note ${quote(str(op.text).slice(0, 30))}`, target: id || undefined };
    case "add_link":
      return { kind: "added", title: `Link ${name(op.from)} → ${name(op.to)}`, target: str(op.from) };
    case "set_link": {
      const l = d.links.find((x) => x.id === id);
      return { kind: "changed", title: "Change a prototype link", target: l?.from };
    }
    case "remove_link": {
      const l = d.links.find((x) => x.id === id);
      return { kind: "removed", title: "Remove a prototype link", target: l?.from };
    }
    case "create_component":
      return { kind: "changed", title: `Make ${name(id)} a component`, target: id };
    case "instantiate":
      return { kind: "added", title: `Add an instance of ${name(op.component)}`, target: id || undefined };
    case "set_overrides":
      return { kind: "changed", title: `Change overrides of ${name(id)}`, target: id };
    case "detach":
      return { kind: "changed", title: `Detach ${name(id)}`, target: id };
    case "set_token":
      return { kind: "changed", title: `Set token ${str(op.name)}` };
    case "link_ticket":
      return { kind: "changed", title: `Link ${str(op.ticket)} to ${name(op.node)}`, target: str(op.node) };
    case "unlink_ticket":
      return { kind: "changed", title: `Unlink ${str(op.ticket)} from ${name(op.node)}`, target: str(op.node) };
    default:
      return { kind: "changed", title: str(op.op).replace(/_/g, " ") };
  }
}

/**
 * Each op as a change: what it is, the node to discuss, the page and the box
 * to pin (an added or changed node on the design with every op applied, a
 * removed one where it is now).
 */
export function classify(before: Design, ops: DesignOp[], needs: number[][] = dependencies(ops)): Change[] {
  const now = boxes(before);
  const after = boxes(applyOps(before, ops));
  return ops.map((op, i) => {
    const { kind, title, target } = describe(op, before);
    // Names of layers an op adds come from the op, of the others from the design before it.
    const where = target ? (kind === "removed" ? (now.get(target) ?? after.get(target)) : (after.get(target) ?? now.get(target))) : undefined;
    const page = where?.page ?? (target ? (pageOf(before, target)?.id ?? find(before, target)?.page.id) : undefined) ?? (op.op === "add_sticky" ? str(op.page) : undefined);
    return { i, op, kind, title, why: str(op.why), target, page, box: where?.box, needs: needs[i] ?? [] };
  });
}

// ---- A version that arrives from elsewhere (a persona's direct edit, an accepted suggestion) ----

/**
 * The working copy after the server's version `seq` arrives. Unsaved edits are
 * never overwritten: with none, the version replaces the draft; with some, it
 * is three-way merged into them (the draft is then unsaved on top of it). Either
 * way the person's previous draft is the single undo step, so undoing the
 * arrival saves a new version that inverts it (ADR §3.7). Overlapping changes
 * return the working copy as it was (conflict): the next save meets them as a
 * 409 and asks the person.
 */
export function adoptVersion(doc: W.Doc, seq: number, theirs: Design): { doc: W.Doc; conflict: boolean } {
  if (seq <= doc.saved.seq) return { doc, conflict: false };
  const next = settleCopy(theirs);
  const base = W.open(seq, theirs);
  // Nothing new to the person: just move the base up.
  if (W.sameDesign(settleCopy(doc.draft), next)) return { doc: W.saved(doc, seq, theirs), conflict: false };
  if (!W.isDirty(doc)) return { doc: { ...base, past: [doc.draft] }, conflict: false };
  const r = mergeDesigns(doc.saved.design, W.settled(doc.draft), next);
  if (!r.design) return { doc, conflict: true };
  return { doc: { ...base, draft: r.design, past: [doc.draft] }, conflict: false };
}

const settleCopy = (d: Design) => W.settled(d);
