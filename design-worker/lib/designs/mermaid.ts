// Mermaid flowchart → design nodes and connectors with automatic layout
// (ADR-designs §2.4, §5.3; productionised from docs/design/poc/mermaid.mjs).
//
// Mermaid's own parser needs a DOM, so this is a small parser for the
// flowchart subset, run by the design worker. ELK (layered, orthogonal edge
// routing) places the nodes and routes the connectors; the routes are stored
// as the connectors' `points`, which the editor keeps until an end moves.
//
// Supported: flowchart|graph TD/TB/BT/LR/RL; node shapes [] () ([]) (()) {}
// {{}} [()] >]; quoted labels; edges --> --- -.-> -.- ==> with |label| or
// -- label --> / -. label .-> / == label ==>; chains (a --> b --> c); & lists;
// subgraph id [title] ... end (nested); %% comments; ; separators.
// Ignored with a warning: classDef, class, style, linkStyle, click, and
// direction inside a subgraph. Anything else is refused with the line number
// and the text that failed; nothing is half-imported.
import ELK from "elkjs/lib/elk.bundled.js";
import { tokenOr } from "./layout.ts";
import { measure } from "./measure.ts";
import type { ConnectorNode, Design, DesignNode, SectionNode, ShapeNode } from "./schema.ts";

export class MermaidError extends Error {}

/** Caps, so one import can't stall the worker. */
export const MAX_SOURCE = 50_000;
export const MAX_NODES = 300;
export const MAX_EDGES = 600;
export const MAX_LINE = 2_000;

type Kind = "rect" | "round" | "stadium" | "circle" | "diamond" | "hexagon" | "cylinder" | "flag";
const SHAPES: [string, string, Kind][] = [
  ["([", "])", "stadium"],
  ["((", "))", "circle"],
  ["[(", ")]", "cylinder"],
  ["{{", "}}", "hexagon"],
  ["[", "]", "rect"],
  ["(", ")", "round"],
  ["{", "}", "diamond"],
  [">", "]", "flag"],
];
const ID = /^[A-Za-z_]\w*(?:-[A-Za-z0-9_]+)*/; // a hyphen only inside an id, so "a-->b" is an edge
// Edge operators, longest first. Captures an inline label for the "-- text -->" forms.
const EDGES = [
  { re: /^-\.\s*([^.|]+?)\s*\.->/, dash: true, arrow: true, thick: false },
  { re: /^==\s*([^=|]+?)\s*==>/, dash: false, arrow: true, thick: true },
  { re: /^--\s*([^-|>]+?)\s*-->/, dash: false, arrow: true, thick: false },
  { re: /^-\.->/, dash: true, arrow: true, thick: false },
  { re: /^-\.-/, dash: true, arrow: false, thick: false },
  { re: /^==>/, dash: false, arrow: true, thick: true },
  { re: /^-->/, dash: false, arrow: true, thick: false },
  { re: /^---/, dash: false, arrow: false, thick: false },
];
const IGNORED = /^(classDef|class|style|linkStyle|click)\b/;

export type ChartNode = { id: string; label: string; shape: Kind; parent: string | null };
export type ChartEdge = { from: string; to: string; label?: string; dash: boolean; arrow: boolean; thick: boolean };
export type ChartGroup = { id: string; title: string; parent: string | null };
export type Chart = { direction: "TB" | "BT" | "LR" | "RL"; nodes: ChartNode[]; edges: ChartEdge[]; groups: ChartGroup[]; warnings: string[] };

/** Parses the flowchart subset; throws MermaidError naming the line and the problem. */
export function parseFlowchart(src: string): Chart {
  if (src.length > MAX_SOURCE) throw new MermaidError(`the Mermaid text is ${src.length} characters; the cap is ${MAX_SOURCE}`);
  const lines = src.split(/\r?\n/);
  const nodes = new Map<string, ChartNode>();
  const edges: ChartEdge[] = [];
  const groups: ChartGroup[] = [];
  const warnings: string[] = [];
  const stack: string[] = [];
  let direction: Chart["direction"] | null = null;
  const fail = (ln: number, msg: string, text?: string): never => {
    throw new MermaidError(`line ${ln + 1}: ${msg}${text ? `: "${text.trim().slice(0, 60)}"` : ""}`);
  };

  const node = (rest: string, ln: number) => {
    const m = rest.match(ID);
    if (!m) fail(ln, "expected a node id", rest);
    const id = m![0];
    rest = rest.slice(id.length);
    let label: string | undefined, shape: Kind | undefined;
    for (const [open, close, kind] of SHAPES) {
      if (!rest.startsWith(open)) continue;
      const end = rest.indexOf(close, open.length);
      if (end < 0) fail(ln, `node ${id} opens ${open} but never closes it with ${close}`, rest);
      label = rest.slice(open.length, end).trim().replace(/^"(.*)"$/, "$1");
      shape = kind;
      rest = rest.slice(end + close.length);
      break;
    }
    const existing = nodes.get(id);
    if (!existing) {
      if (nodes.size >= MAX_NODES) fail(ln, `more than ${MAX_NODES} nodes`);
      nodes.set(id, { id, label: label || id, shape: shape ?? "rect", parent: stack.at(-1) ?? null });
    } else if (label !== undefined) Object.assign(existing, { label: label || id, shape });
    return { id, rest: rest.trimStart() };
  };
  const nodeList = (rest: string, ln: number) => {
    const ids: string[] = [];
    for (;;) {
      const r = node(rest, ln);
      ids.push(r.id);
      rest = r.rest;
      if (!rest.startsWith("&")) return { ids, rest };
      rest = rest.slice(1).trimStart();
    }
  };
  const statement = (s: string, ln: number) => {
    let { ids: from, rest } = nodeList(s, ln);
    while (rest) {
      const op = EDGES.find((e) => e.re.test(rest));
      if (!op) fail(ln, "expected an edge (-->, ---, -.->, ==>) or the end of the line", rest);
      const m = rest.match(op!.re)!;
      let label = m[1]?.trim();
      rest = rest.slice(m[0].length).trimStart();
      const pipe = rest.match(/^\|([^|]*)\|/);
      if (pipe) {
        label = pipe[1].trim().replace(/^"(.*)"$/, "$1");
        rest = rest.slice(pipe[0].length).trimStart();
      }
      if (!rest) fail(ln, "the edge has no target node", s);
      const r = nodeList(rest, ln);
      for (const a of from)
        for (const b of r.ids) {
          if (edges.length >= MAX_EDGES) fail(ln, `more than ${MAX_EDGES} edges`);
          edges.push({ from: a, to: b, ...(label ? { label } : {}), dash: op!.dash, arrow: op!.arrow, thick: op!.thick });
        }
      from = r.ids;
      rest = r.rest;
    }
  };

  for (let ln = 0; ln < lines.length; ln++) {
    // Bounds the edge regexes' backtracking on hostile input.
    if (lines[ln].length > MAX_LINE) fail(ln, `the line is ${lines[ln].length} characters; the cap is ${MAX_LINE}`);
    for (let s of lines[ln].replace(/%%.*$/, "").split(";")) {
      s = s.trim();
      if (!s) continue;
      if (!direction) {
        const m = s.match(/^(flowchart|graph)\s+(TD|TB|BT|LR|RL)\s*$/);
        if (!m) fail(ln, "expected 'flowchart' or 'graph' and a direction (TD, TB, BT, LR or RL); only flowcharts can be imported", s);
        direction = m![2] === "TD" ? "TB" : (m![2] as Chart["direction"]);
        continue;
      }
      if (IGNORED.test(s)) {
        warnings.push(`line ${ln + 1}: ${s.split(/\s/)[0]} is ignored (styling isn't imported)`);
        continue;
      }
      const sg = s.match(/^subgraph\s+([A-Za-z_][\w-]*)\s*(?:\[\s*"?([^"\]]*)"?\s*\])?\s*$/) || s.match(/^subgraph\s+"?([^"]+?)"?\s*$/);
      if (sg) {
        const id = sg[1].replace(/\s+/g, "_");
        if (groups.some((g) => g.id === id)) fail(ln, `subgraph ${id} is defined twice`);
        groups.push({ id, title: sg[2] || sg[1], parent: stack.at(-1) ?? null });
        stack.push(id);
        continue;
      }
      if (s === "end") {
        if (!stack.length) fail(ln, "'end' without a subgraph");
        stack.pop();
        continue;
      }
      if (/^direction\s+/.test(s)) {
        warnings.push(`line ${ln + 1}: direction inside a subgraph is ignored`);
        continue;
      }
      statement(s, ln);
    }
  }
  if (!direction) throw new MermaidError("line 1: the text is empty; expected 'flowchart LR' or similar");
  if (stack.length) throw new MermaidError(`subgraph ${stack.at(-1)} has no 'end'`);
  if (!nodes.size) throw new MermaidError("the flowchart has no nodes");
  for (const g of groups) if (nodes.has(g.id)) throw new MermaidError(`${g.id} is both a node and a subgraph`);
  return { direction, nodes: [...nodes.values()], edges, groups, warnings };
}

const SHAPE_MAP: Record<Kind, { shape: ShapeNode["shape"]; radius?: number; warn?: string }> = {
  rect: { shape: "roundRect", radius: 6 },
  round: { shape: "roundRect", radius: 14 },
  stadium: { shape: "roundRect", radius: 999 },
  circle: { shape: "ellipse" },
  diamond: { shape: "diamond" },
  hexagon: { shape: "hexagon" },
  cylinder: { shape: "roundRect", radius: 6, warn: "cylinder drawn as a rectangle" },
  flag: { shape: "roundRect", radius: 0, warn: "asymmetric shape drawn as a rectangle" },
};
const FONT = 15;
const PAD = { x: 20, y: 14 };
const r2 = (n: number) => Math.round(n * 100) / 100;

type ElkNode = { id: string; x?: number; y?: number; width?: number; height?: number; children?: ElkNode[]; layoutOptions?: Record<string, string> };
type ElkEdge = { id: string; sources: string[]; targets: string[]; labels?: object[]; container?: string; sections?: { startPoint: { x: number; y: number }; endPoint: { x: number; y: number }; bendPoints?: { x: number; y: number }[] }[] };

export type Imported = { section: SectionNode; warnings: string[] };

/**
 * Lays the chart out with ELK and returns one section holding shapes, nested
 * sections (subgraphs) and connectors with routed points, at (x, y) on the
 * page, coloured with the design's tokens where it has them. ids mints node
 * ids. Throws MermaidError for text it can't import.
 */
export async function importFlowchart(src: string, opts: { design: Pick<Design, "tokens_ref" | "token_sets" | "mode">; ids: () => string; x?: number; y?: number; name?: string }): Promise<Imported> {
  const chart = parseFlowchart(src);
  const { design, ids, x = 0, y = 0 } = opts;
  const c = (name: string) => tokenOr(design, name);
  const warnings = [...chart.warnings];
  const nid = new Map(chart.nodes.map((n) => [n.id, ids()]));
  const gid = new Map(chart.groups.map((g) => [g.id, ids()]));
  const sizeOf = (n: ChartNode) => {
    const w = measure(n.label, 500, false, FONT) + 2 * PAD.x;
    const h = FONT * 1.2 + 2 * PAD.y;
    if (n.shape === "diamond") return { w: Math.max(w * 1.5, 120), h: Math.max(h * 1.6, 72) };
    if (n.shape === "circle") return { w: Math.max(w, h), h: Math.max(w, h) };
    if (n.shape === "hexagon") return { w: w + 24, h };
    return { w: Math.max(w, 96), h };
  };
  const groupChildren = (parent: string | null): ElkNode[] => [
    ...chart.groups.filter((g) => g.parent === parent).map((g) => ({ id: `g:${g.id}`, layoutOptions: { "elk.padding": "[top=44,left=20,bottom=20,right=20]" }, children: groupChildren(g.id) })),
    ...chart.nodes.filter((n) => n.parent === parent).map((n) => {
      const s = sizeOf(n);
      return { id: n.id, width: r2(s.w), height: r2(s.h) };
    }),
  ];
  const graph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": { LR: "RIGHT", RL: "LEFT", TB: "DOWN", BT: "UP" }[chart.direction],
      "elk.edgeRouting": "ORTHOGONAL",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "56",
      "elk.spacing.nodeNode": "36",
      "elk.spacing.edgeNode": "20",
      "elk.spacing.edgeEdge": "14",
      "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
      "elk.padding": "[top=56,left=32,bottom=32,right=32]",
    },
    children: groupChildren(null),
    edges: chart.edges.map((e, i) => ({
      id: `e${i}`,
      sources: [e.from],
      targets: [e.to],
      labels: e.label ? [{ text: e.label, width: measure(e.label, 400, false, 12) + 12, height: 20 }] : [],
    })),
  };
  const laid = (await new ELK().layout(graph)) as ElkNode & { edges: ElkEdge[] };

  // ELK positions are relative to each node's parent, and an edge's points to
  // its container (ADR §5.5 finding 3): shift them into the section's frame.
  const offset = new Map<string, { x: number; y: number }>([["root", { x: 0, y: 0 }]]);
  const walk = (n: ElkNode, ox: number, oy: number) => {
    for (const k of n.children ?? []) {
      offset.set(k.id, { x: ox + k.x!, y: oy + k.y! });
      walk(k, ox + k.x!, oy + k.y!);
    }
  };
  walk(laid, 0, 0);
  const byId = new Map(chart.nodes.map((n) => [n.id, n]));
  const groupById = new Map(chart.groups.map((g) => [g.id, g]));
  const warned = new Set<Kind>();
  const toNodes = (kids: ElkNode[]): DesignNode[] =>
    kids.map((k): DesignNode => {
      if (k.id.startsWith("g:")) {
        const g = groupById.get(k.id.slice(2))!;
        return { id: gid.get(g.id)!, type: "section", name: g.title, x: r2(k.x!), y: r2(k.y!), w: r2(k.width!), h: r2(k.height!), fill: c("surface-raised"), children: toNodes(k.children ?? []) };
      }
      const n = byId.get(k.id)!;
      const m = SHAPE_MAP[n.shape];
      if (m.warn && !warned.has(n.shape)) {
        warned.add(n.shape);
        warnings.push(`${n.id}: ${m.warn}`);
      }
      const diamond = n.shape === "diamond";
      return {
        id: nid.get(n.id)!, type: "shape", shape: m.shape, name: n.label, x: r2(k.x!), y: r2(k.y!), w: r2(k.width!), h: r2(k.height!),
        ...(m.radius !== undefined ? { radius: r2(Math.min(m.radius, k.height! / 2)) } : {}),
        fill: c(diamond ? "accent-soft" : "surface"), stroke: c(diamond ? "accent" : "border-strong"), stroke_width: 1.5,
        text: { valign: "middle", paragraphs: [{ align: "center", runs: [{ text: n.label, size: FONT, weight: 500, color: c("text") }] }] },
      } as ShapeNode;
    });
  const connectors = laid.edges.map((e, i): ConnectorNode => {
    const src = chart.edges[i];
    const sec = e.sections?.[0];
    const o = offset.get(e.container ?? "root") ?? { x: 0, y: 0 };
    const points = sec ? [sec.startPoint, ...(sec.bendPoints ?? []), sec.endPoint].map((p) => [r2(o.x + p.x), r2(o.y + p.y)] as [number, number]) : undefined;
    return {
      id: ids(), type: "connector", from: { node: nid.get(src.from)! }, to: { node: nid.get(src.to)! },
      stroke: c(src.thick ? "text-2" : "text-secondary"), stroke_width: src.thick ? 3 : 1.5,
      ...(src.dash ? { dash: "dash" as const } : {}), ...(src.arrow ? {} : { end_arrow: "none" as const }), ...(src.label ? { label: src.label } : {}),
      ...(points && points.length >= 2 ? { points } : {}),
    };
  });
  const section: SectionNode = {
    id: ids(), type: "section", name: opts.name ?? "Imported flowchart", x: r2(x), y: r2(y), w: r2(laid.width!), h: r2(laid.height!), fill: c("surface"),
    children: [...toNodes(laid.children ?? []), ...connectors],
  };
  return { section, warnings };
}
