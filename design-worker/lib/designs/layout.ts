// The shared display list (ADR-designs §3.8). A page or a node becomes flat
// drawing ops in page coordinates; the editor's <DesignSvg>, thumbnails and
// (later) the server renderer and exports all draw these ops, so they agree
// on every position, line break and colour. Pure: no DOM, so node's test
// runner and the design worker load it as is.
//
// Covers frames/components/instances with auto layout (direction, gap,
// padding, align, justify; fixed/hug/fill sizing), constraints for instances
// resized away from their main, groups, sections, shapes (every Slides
// preset) with text, vector paths, text in Inter (the Slides text model:
// greedy wrap, bullets, justify, highlight, underline, strike), images (crop,
// cover/contain/fill, rounded clip), stickies, connectors (routed around
// their siblings, route.ts), rotation, opacity,
// tokens per mode.
import { type Seg, isPreset, shapeGeometry, svgPath } from "../slides/geometry.ts";
import type { ShapeKind } from "../slides/schema.ts";
import { face, measure } from "./measure.ts";
import { connectorPath, type Outline } from "./route.ts";
import type { AutoLayout, Color, ConnectorNode, Constraints, Design, DesignNode, Mode, Paint, Page, Paragraph, Run } from "./schema.ts";

export const SHAPE_INSET = 8;
export const STICKY_INSET = 12;
export const LINE = 1.2;
export const BULLET_INDENT = 20;
export const STICKY_COLORS = { yellow: "#FDE68A", pink: "#FBCFE8", green: "#BBF7D0", blue: "#BFDBFE", violet: "#DDD6FE", grey: "#E5E7EB" } as const;
export const STICKY_TEXT = "#1A1206";
const ARROW = 10;

/** Colours used when a design has no token set, or names a token its set lacks. */
export const FALLBACK: Record<Mode, Record<string, string>> = {
  light: { text: "#16161D", "text-secondary": "#5E5E6E", bg: "#FFFFFF", surface: "#FFFFFF", border: "#D9D9E3" },
  dark: { text: "#ECECF1", "text-secondary": "#9A9AAE", bg: "#0C0C10", surface: "#16161D", border: "#2A2A36" },
};

/** Diagram colours (sections, imported charts): the Dusk values, used when a design's token set lacks the token. */
export const DIAGRAM_COLORS: Record<Mode, Record<string, string>> = {
  dark: { surface: "#15141F", "surface-raised": "#1B1A27", "border-strong": "#2E2B3B", text: "#EEEDF3", "text-2": "#CBC9D6", "text-secondary": "#A4A1B3", accent: "#9B8CFF", "accent-soft": "#9B8CFF26" },
  light: { surface: "#FFFFFF", "surface-raised": "#F6F5FA", "border-strong": "#DEDAEA", text: "#17151F", "text-2": "#3A3747", "text-secondary": "#55526A", accent: "#5B4BD6", "accent-soft": "#5B4BD61F" },
};
/** `$name` when the design's token set has that colour, else its hex for the design's mode, so new nodes always validate. */
export function tokenOr(design: Pick<Design, "tokens_ref" | "token_sets" | "mode">, name: string): Color {
  const set = design.tokens_ref ? design.token_sets[design.tokens_ref.set] : undefined;
  if (set?.modes.dark[name]?.kind === "color") return `$${name}` as Color;
  return (DIAGRAM_COLORS[design.mode]?.[name] ?? DIAGRAM_COLORS.dark[name] ?? "#808080") as Color;
}

const r2 = (n: number) => Math.round(n * 100) / 100;

export type Box = { x: number; y: number; w: number; h: number };
export type ResolvedPaint = string | { angle: number; stops: [string, string] };
type Common = { el: string; opacity?: number };
type StrokeProps = { stroke?: string; sw: number; dash?: string; cap?: string; join?: string };
export type Op =
  | ({ op: "rect"; x: number; y: number; w: number; h: number; r: number; fill?: ResolvedPaint } & StrokeProps & Common)
  | ({ op: "ellipse"; x: number; y: number; w: number; h: number; fill?: ResolvedPaint } & StrokeProps & Common)
  | ({ op: "path"; d: string; box: Box; fill?: ResolvedPaint } & StrokeProps & Common)
  | ({ op: "polyline"; points: [number, number][] } & StrokeProps & Common)
  | ({ op: "image"; asset: string; x: number; y: number; w: number; h: number; r: number; src: Box; iw: number; ih: number; alt: string } & Common)
  | ({ op: "text"; x: number; y: number; text: string; weight: number; italic: boolean; size: number; fill: string } & Common)
  | { op: "clip"; x: number; y: number; w: number; h: number; r: number }
  | { op: "unclip" }
  | { op: "rotate"; deg: number; cx: number; cy: number }
  | { op: "unrotate" };

/** One top-level node's ops and box, so the editor can cull off-screen ones. */
export type LaidNode = { id: string; box: Box; ops: Op[] };
export type LaidPage = {
  nodes: LaidNode[];
  /** Page-level connectors, drawn over the nodes. */
  connectors: Op[];
  box: Box;
  background?: string;
  /** Every drawn node's absolute, unrotated box (instance children as instance/child). */
  boxes: Map<string, Box & { rotation?: number }>;
  /** Each laid node's box relative to its parent: what settle() writes back. */
  local: Map<string, Box>;
  /** Text nodes whose text doesn't fit their box. */
  overflow: Set<string>;
};

const DASH: Record<string, number[]> = { dash: [4, 3], dot: [1, 1], dashDot: [4, 3, 1, 3], longDash: [8, 3] };
export const dashArray = (dash: string | undefined, sw: number) => (dash && DASH[dash] ? DASH[dash].map((n) => r2(n * sw)).join(" ") : undefined);

export const sizingOf = (n: DesignNode) => ({ w: ("sizing" in n && n.sizing?.w) || "fixed", h: ("sizing" in n && n.sizing?.h) || "fixed" });
export const autoLayoutOf = (n: DesignNode): Required<AutoLayout> | undefined => {
  const al = "auto_layout" in n ? n.auto_layout : undefined;
  return al && { gap: 0, padding: [0, 0, 0, 0], align: "start", justify: "start", ...al };
};
export const childrenOf = (n: DesignNode): DesignNode[] => ("children" in n && Array.isArray(n.children) ? n.children : []);
/** Children an auto-layout container places: not absolute, not hidden, not connectors. */
export const flowKids = (n: DesignNode) => childrenOf(n).filter((c) => c.type !== "connector" && !("absolute" in c && c.absolute) && c.visible !== false);

const weightOf = (r: Run) => r.weight ?? (r.bold ? 700 : 400);

// ---------- text ----------

type Piece = { run: Run; text: string; x: number; w: number };
type Line = { y: number; lh: number; maxSize: number; left: number; pieces: Piece[]; align: NonNullable<Paragraph["align"]>; last: boolean; bullet?: { glyph: string; x: number; run: Run } };

export const lineHeight = (p: Paragraph) => Math.max(...p.runs.map((r) => r.size)) * LINE * (p.lineSpacing || 1);

/** Greedy word wrap (as lib/slides/layout.ts). innerW = Infinity gives the unwrapped width. */
export function wrap(paragraphs: Paragraph[], innerW: number): { lines: Line[]; height: number; width: number } {
  const lines: Line[] = [];
  let y = 0;
  let number = 0;
  for (const p of paragraphs) {
    y += p.spaceBefore ?? 0;
    const lh = lineHeight(p);
    const maxSize = Math.max(...p.runs.map((r) => r.size));
    const level = p.level ?? 0;
    const left = p.bullet ? BULLET_INDENT * (level + 1) : 0;
    number = p.bullet === "number" ? number + 1 : 0;
    const first = lines.length;
    let cur: Piece[] = [];
    let w = 0;
    const flush = () => {
      lines.push({ y, lh, maxSize, left, pieces: cur, align: p.align ?? "left", last: false });
      cur = [];
      w = 0;
      y += lh;
    };
    for (const r of p.runs)
      for (const t of r.text.split(/(?<= )/)) {
        if (!t) continue;
        const wt = weightOf(r);
        const tw = measure(t, wt, r.italic, r.size);
        const trimmed = measure(t.trimEnd(), wt, r.italic, r.size);
        if (cur.length && w + trimmed > innerW - left + 0.001) flush();
        if (!cur.length && trimmed > innerW - left + 0.001) {
          // A word longer than the line breaks between characters.
          let chunk = "";
          for (const ch of t) {
            if (chunk && measure(chunk + ch, wt, r.italic, r.size) > innerW - left + 0.001) {
              cur.push({ run: r, text: chunk, x: 0, w: measure(chunk, wt, r.italic, r.size) });
              flush();
              chunk = "";
            }
            chunk += ch;
          }
          cur.push({ run: r, text: chunk, x: 0, w: measure(chunk, wt, r.italic, r.size) });
          w = cur[0].w;
          continue;
        }
        cur.push({ run: r, text: t, x: w, w: tw });
        w += tw;
      }
    flush();
    lines[lines.length - 1].last = true;
    if (p.bullet) lines[first].bullet = { glyph: p.bullet === "number" ? `${number}.` : "•", x: BULLET_INDENT * level, run: p.runs[0] };
  }
  const width = Math.max(0, ...lines.map((l) => l.left + usedWidth(l)));
  return { lines, height: y, width };
}
const usedWidth = (l: Line) => {
  const last = l.pieces.at(-1);
  return last ? last.x + measure(last.text.trimEnd(), weightOf(last.run), last.run.italic, last.run.size) : 0;
};

// ---------- the layout ----------

export type Layout = ReturnType<typeof makeLayout>;

/** A layout over one design. Build one per body; it indexes the nodes once. */
export function makeLayout(design: Design) {
  const index = new Map<string, DesignNode>();
  const visit = (n: DesignNode) => {
    index.set(n.id, n);
    for (const c of childrenOf(n)) visit(c);
  };
  for (const p of design.pages) for (const n of p.children) visit(n);
  const set = design.tokens_ref ? design.token_sets[design.tokens_ref.set] : undefined;

  const color = (c: Color | undefined, mode: Mode): string | undefined => {
    if (c === undefined) return undefined;
    if (!c.startsWith("$")) return c;
    const name = c.slice(1);
    const t = (mode === "light" && set?.modes.light?.[name]) || set?.modes.dark[name];
    return t?.kind === "color" ? t.value : (FALLBACK[mode][name] ?? FALLBACK[mode].text);
  };
  const paint = (p: Paint | undefined, mode: Mode): ResolvedPaint | undefined =>
    p === undefined ? undefined : typeof p === "string" ? color(p, mode) : { angle: p.angle, stops: [color(p.stops[0], mode)!, color(p.stops[1], mode)!] };

  const boxes = new Map<string, Box & { rotation?: number }>();
  const local = new Map<string, Box>();
  const overflow = new Set<string>();

  function textOps(paragraphs: Paragraph[], box: Box, inset: number, valign: string, mode: Mode, ops: Op[], el: string, defaultColor: string): number {
    const innerW = box.w - 2 * inset;
    const { lines, height } = wrap(paragraphs, innerW);
    const avail = box.h - 2 * inset;
    const shift = valign === "middle" ? (avail - height) / 2 : valign === "bottom" ? avail - height : 0;
    const highlights: Op[] = [];
    const out: Op[] = [];
    for (const l of lines) {
      const f = face(400, false);
      const baseline = box.y + inset + shift + l.y + (l.lh - (f.asc + f.desc) * l.maxSize) / 2 + f.asc * l.maxSize;
      const room = innerW - l.left - usedWidth(l);
      const dx = l.align === "center" ? room / 2 : l.align === "right" ? room : 0;
      const gaps = l.align === "justify" && !l.last && room > 0 ? l.pieces.slice(0, -1).filter((pc) => pc.text.endsWith(" ")).length : 0;
      const per = gaps ? room / gaps : 0;
      let spread = 0;
      if (l.bullet && l.pieces.some((p) => p.text.trim())) {
        const r = l.bullet.run;
        out.push({ op: "text", x: r2(box.x + inset + l.bullet.x), y: r2(baseline), text: l.bullet.glyph, weight: 400, italic: false, size: r.size, fill: color(r.color, mode) ?? defaultColor, el });
      }
      for (const pc of l.pieces) {
        const x = box.x + inset + l.left + dx + pc.x + spread;
        if (per && pc.text.endsWith(" ")) spread += per;
        const text = pc.text.trimEnd();
        if (!text.trim()) continue;
        const r = pc.run;
        const wt = weightOf(r);
        const w = measure(text, wt, r.italic, r.size);
        const fill = color(r.color, mode) ?? defaultColor;
        const fm = face(wt, r.italic);
        if (r.highlight) highlights.push({ op: "rect", x: r2(x), y: r2(baseline - fm.asc * r.size), w: r2(w), h: r2((fm.asc + fm.desc) * r.size), r: 0, fill: color(r.highlight, mode), sw: 0, el });
        out.push({ op: "text", x: r2(x), y: r2(baseline), text, weight: wt, italic: !!r.italic, size: r.size, fill, el });
        if (r.underline) out.push({ op: "rect", x: r2(x), y: r2(baseline + fm.underline.pos * r.size), w: r2(w), h: r2(fm.underline.thick * r.size), r: 0, fill, sw: 0, el });
        if (r.strike) out.push({ op: "rect", x: r2(x), y: r2(baseline - fm.strike.pos * r.size), w: r2(w), h: r2(fm.strike.thick * r.size), r: 0, fill, sw: 0, el });
      }
    }
    ops.push(...highlights, ...out);
    return height;
  }

  /** An instance as its component's subtree with the overrides applied, sized to the instance. */
  function expand(n: DesignNode): DesignNode {
    if (n.type !== "instance") return n;
    const main = index.get(n.component);
    if (!main || (main.type !== "component" && main.type !== "frame")) return { ...n, type: "frame", children: [] } as unknown as DesignNode;
    const clone = (m: DesignNode): DesignNode => {
      const o = n.overrides?.[m.id] ?? {};
      const c = { ...m, id: `${n.id}/${m.id}` } as DesignNode & Record<string, unknown>;
      if ("children" in m) (c as { children: DesignNode[] }).children = m.children.map(clone);
      if (o.fill !== undefined) c.fill = o.fill;
      if (o.visible !== undefined) c.visible = o.visible;
      if (o.text !== undefined && c.type === "text") c.paragraphs = [{ ...c.paragraphs[0], runs: [{ ...c.paragraphs[0].runs[0], text: o.text }] }];
      return c;
    };
    const root = clone(main) as DesignNode & { children: DesignNode[] };
    // Resized away from its main: children follow their constraints.
    if (!main.auto_layout && (n.w !== main.w || n.h !== main.h)) root.children = root.children.map((c) => constrain(c, main.w, main.h, n.w, n.h));
    return { ...root, id: n.id, type: "frame", x: n.x, y: n.y, w: n.w, h: n.h, sizing: n.sizing ?? main.sizing, name: n.name, rotation: n.rotation, opacity: n.opacity } as DesignNode;
  }

  /** Intrinsic (hug) width; for text, its unwrapped width. */
  function hugW(n: DesignNode): number {
    n = expand(n);
    if (n.type === "text") return wrap(n.paragraphs, Infinity).width;
    const al = autoLayoutOf(n);
    if (!al || n.type === "connector") return n.type === "connector" ? 0 : n.w;
    const ws = flowKids(n).map((c) => (sizingOf(c).w === "fill" ? (al.direction === "horizontal" ? hugW(c) : 0) : widthOf(c)));
    const [, pr, , pl] = al.padding;
    return pl + pr + (al.direction === "horizontal" ? ws.reduce((a, b) => a + b, 0) + al.gap * Math.max(0, ws.length - 1) : Math.max(0, ...ws));
  }
  const widthOf = (n: DesignNode): number => (n.type === "connector" ? 0 : sizingOf(n).w === "hug" ? hugW(n) : n.w);

  /** Height at a given width (hug), after laying the children out. */
  function hugH(n: DesignNode, w: number): number {
    n = expand(n);
    if (n.type === "text") return wrap(n.paragraphs, w).height;
    if (n.type === "connector") return 0;
    const al = autoLayoutOf(n);
    if (!al) return n.h;
    const placed = childBoxes(n, al, w, undefined);
    const [pt, , pb] = al.padding;
    const hs = placed.map((b) => b.h);
    return pt + pb + (al.direction === "vertical" ? hs.reduce((a, b) => a + b, 0) + al.gap * Math.max(0, hs.length - 1) : Math.max(0, ...hs));
  }
  const heightOf = (n: DesignNode, w: number) => (n.type === "connector" ? 0 : sizingOf(n).h === "hug" ? hugH(n, w) : n.h);

  /** Child boxes (relative to the container) inside an auto-layout container of width w (and height h, once known). */
  function childBoxes(n: DesignNode, al: Required<AutoLayout>, w: number, h: number | undefined) {
    const kids = flowKids(n) as Exclude<DesignNode, ConnectorNode>[];
    const [pt, pr, pb, pl] = al.padding;
    const innerW = w - pl - pr;
    const horiz = al.direction === "horizontal";
    let widths: number[];
    if (horiz) {
      const fixed = kids.map((c) => (sizingOf(c).w === "fill" ? null : widthOf(c)));
      const fills = fixed.filter((x) => x === null).length;
      const used = fixed.reduce<number>((a, b) => a + (b ?? 0), 0) + al.gap * Math.max(0, kids.length - 1);
      const share = fills ? Math.max(0, innerW - used) / fills : 0;
      widths = fixed.map((x) => x ?? share);
    } else widths = kids.map((c) => (sizingOf(c).w === "fill" ? Math.max(0, innerW) : widthOf(c)));
    const innerH = h === undefined ? undefined : h - pt - pb;
    let heights: (number | null)[] = kids.map((c, i) => {
      const s = sizingOf(c).h;
      if (s === "hug") return hugH(c, widths[i]);
      if (s === "fill") return horiz ? (innerH ?? c.h) : null;
      return c.h;
    });
    if (!horiz) {
      const fills = heights.filter((x) => x === null).length;
      const used = heights.reduce<number>((a, b) => a + (b ?? 0), 0) + al.gap * Math.max(0, kids.length - 1);
      const share = fills && innerH !== undefined ? Math.max(0, innerH - used) / fills : 0;
      heights = heights.map((x) => x ?? share);
    }
    const hs = heights as number[];
    const mainSizes = horiz ? widths : hs;
    const total = mainSizes.reduce((a, b) => a + b, 0) + al.gap * Math.max(0, kids.length - 1);
    const mainInner = horiz ? innerW : (innerH ?? total);
    let gap = al.gap;
    let start = 0;
    if (al.justify === "center") start = (mainInner - total) / 2;
    else if (al.justify === "end") start = mainInner - total;
    else if (al.justify === "space-between" && kids.length > 1) gap = (mainInner - (total - al.gap * (kids.length - 1))) / (kids.length - 1);
    const crossInner = horiz ? (innerH ?? Math.max(0, ...hs)) : innerW;
    let pos = start;
    return kids.map((c, i) => {
      const cw = widths[i];
      const ch = hs[i];
      const cross = horiz ? ch : cw;
      const off = al.align === "center" ? (crossInner - cross) / 2 : al.align === "end" ? crossInner - cross : 0;
      const box = horiz ? { x: pl + pos, y: pt + off, w: cw, h: ch } : { x: pl + off, y: pt + pos, w: cw, h: ch };
      pos += (horiz ? cw : ch) + gap;
      return { c, ...box };
    });
  }

  // ---------- drawing ----------

  function draw(node: DesignNode, ax: number, ay: number, w: number, h: number, mode: Mode, ops: Op[]) {
    if (node.visible === false || node.type === "connector") return;
    const id = node.id;
    const n = expand(node) as Exclude<DesignNode, ConnectorNode>;
    mode = ("mode" in n && n.mode) || mode;
    const box = { x: ax, y: ay, w, h };
    boxes.set(id, { ...box, rotation: n.rotation });
    const op0 = ops.length;
    const rot = n.rotation ? { op: "rotate" as const, deg: n.rotation, cx: ax + w / 2, cy: ay + h / 2 } : undefined;
    if (rot) ops.push(rot);
    const stroke = (s: { stroke?: Color; stroke_width?: number; dash?: string }) => ({ stroke: color(s.stroke, mode), sw: s.stroke ? (s.stroke_width ?? 1) : 0, dash: s.stroke ? dashArray(s.dash, s.stroke_width ?? 1) : undefined });
    switch (n.type) {
      case "frame":
      case "component":
      case "section": {
        const fill = paint(n.fill, mode);
        const st: ReturnType<typeof stroke> = n.type === "section" ? { stroke: undefined, sw: 0, dash: undefined } : stroke(n);
        const r = n.type === "section" ? 8 : (n.radius ?? 0);
        if (fill || st.stroke) ops.push({ op: "rect", ...box, r, fill, ...st, el: id });
        if (n.type === "section") ops.push({ op: "text", x: ax + 16, y: ay + 28, text: n.name ?? "Section", weight: 600, italic: false, size: 14, fill: color("$text-secondary", mode)!, el: id });
        const clip = n.type !== "section" && n.clip;
        if (clip) ops.push({ op: "clip", ...box, r });
        drawChildren(n, box, mode, ops);
        if (clip) ops.push({ op: "unclip" });
        break;
      }
      case "group":
        drawChildren(n, box, mode, ops);
        break;
      case "shape": {
        const fill = paint(n.fill, mode);
        const st = stroke(n);
        const shape = n.shape as ShapeKind;
        let text = box;
        if (shape === "ellipse") ops.push({ op: "ellipse", ...box, fill, ...st, el: id });
        else if (shape === "rect" || shape === "roundRect") ops.push({ op: "rect", ...box, r: shape === "roundRect" ? Math.min(n.radius ?? 8, w / 2, h / 2) : 0, fill, ...st, el: id });
        else {
          const g = shapeGeometry(isPreset(shape) ? shape : "rect", box, n.radius ?? 8);
          ops.push({ op: "path", d: svgPath(g.segs as Seg[]), box, fill, ...st, el: id });
          text = g.text;
        }
        if (n.text) textOps(n.text.paragraphs, text, SHAPE_INSET, n.text.valign ?? "middle", mode, ops, id, color("$text", mode)!);
        break;
      }
      case "path": {
        const d = n.d.replace(/(-?[\d.]+(?:e-?\d+)?)[ ,]+(-?[\d.]+(?:e-?\d+)?)/gi, (_, x, y) => `${r2(ax + +x)} ${r2(ay + +y)}`);
        ops.push({ op: "path", d, box, fill: paint(n.fill, mode), ...stroke(n), cap: n.cap, join: n.join, el: id });
        break;
      }
      case "text": {
        const height = textOps(n.paragraphs, box, 0, n.valign ?? "top", mode, ops, id, color("$text", mode)!);
        if (height > h + 0.5) overflow.add(id);
        break;
      }
      case "image": {
        const a = design.assets[n.asset];
        if (!a) {
          ops.push({ op: "rect", ...box, r: n.radius ?? 0, fill: "#E5E7EB", sw: 0, el: id });
          break;
        }
        const c = n.crop ?? { l: 0, t: 0, r: 0, b: 0 };
        let sx = c.l * a.w, sy = c.t * a.h, sw = (1 - c.l - c.r) * a.w, sh = (1 - c.t - c.b) * a.h;
        let dest = box;
        const fit = n.fit ?? "cover";
        if (fit === "cover") {
          const k = Math.max(w / sw, h / sh);
          const vw = w / k, vh = h / k;
          sx += (sw - vw) / 2;
          sy += (sh - vh) / 2;
          sw = vw;
          sh = vh;
        } else if (fit === "contain") {
          const k = Math.min(w / sw, h / sh);
          dest = { x: ax + (w - sw * k) / 2, y: ay + (h - sh * k) / 2, w: sw * k, h: sh * k };
        }
        ops.push({ op: "image", asset: n.asset, ...dest, r: n.radius ?? 0, src: { x: r2(sx), y: r2(sy), w: r2(sw), h: r2(sh) }, iw: a.w, ih: a.h, alt: n.alt ?? a.alt ?? "", el: id });
        break;
      }
      case "sticky": {
        ops.push({ op: "rect", ...box, r: 4, fill: STICKY_COLORS[n.color ?? "yellow"], sw: 0, el: id });
        const paras: Paragraph[] = [{ runs: [{ text: n.text, size: 14, weight: 500, color: STICKY_TEXT }] }];
        if (n.author) paras.push({ spaceBefore: 6, runs: [{ text: n.author, size: 11, color: STICKY_TEXT }] });
        textOps(paras, box, STICKY_INSET, "top", mode, ops, id, STICKY_TEXT);
        break;
      }
    }
    if (rot) ops.push({ op: "unrotate" });
    if (n.opacity !== undefined && n.opacity < 1)
      for (let i = op0; i < ops.length; i++) {
        const o = ops[i];
        if ("el" in o) o.opacity = (o.opacity ?? 1) * n.opacity;
      }
  }

  function drawChildren(n: DesignNode, box: Box, mode: Mode, ops: Op[]) {
    const al = autoLayoutOf(n);
    const placed = al ? childBoxes(n, al, box.w, box.h) : [];
    const byId = new Map(placed.map((b) => [b.c.id, b]));
    const connectors: ConnectorNode[] = [];
    for (const c of childrenOf(n)) {
      if (c.type === "connector") {
        connectors.push(c);
        continue;
      }
      const b = byId.get(c.id);
      if (b) {
        local.set(c.id, { x: b.x, y: b.y, w: b.w, h: b.h });
        draw(c, box.x + b.x, box.y + b.y, b.w, b.h, mode, ops);
      } else {
        const w = widthOf(c);
        const h = heightOf(c, w);
        local.set(c.id, { x: c.x, y: c.y, w, h });
        draw(c, box.x + c.x, box.y + c.y, w, h, mode, ops);
      }
    }
    for (const c of connectors) drawConnector(c, mode, ops, "fill" in n && typeof n.fill === "string" ? color(n.fill, mode) : undefined, childrenOf(n), box);
  }

  // ---------- connectors (routing in route.ts) ----------

  /**
   * What a connector in `list` (its container's children) routes around: every
   * drawn sibling except its ends, looking inside the siblings that hold an end
   * (a subgraph section) so the nodes next to the end are avoided too.
   */
  function obstaclesIn(list: DesignNode[], ends: Set<string>, out: Box[] = []): Box[] {
    for (const n of list) {
      if (n.type === "connector" || n.visible === false || ends.has(n.id)) continue;
      if (holdsAny(n, ends)) obstaclesIn(childrenOf(n), ends, out);
      else {
        const b = boxes.get(n.id);
        if (b) out.push(b);
      }
    }
    return out;
  }
  const holdsAny = (n: DesignNode, ids: Set<string>): boolean => childrenOf(n).some((c) => ids.has(c.id) || holdsAny(c, ids));
  const outlineOf = (id: string): Outline => {
    const n = index.get(id);
    return n?.type === "shape" && (n.shape === "diamond" || n.shape === "ellipse") ? n.shape : "box";
  };

  function drawConnector(c: ConnectorNode, mode: Mode, ops: Op[], bg: string | undefined, siblings: DesignNode[], origin: Box | { x: number; y: number } = { x: 0, y: 0 }) {
    if (c.visible === false) return;
    const fb = boxes.get(c.from.node), tb = boxes.get(c.to.node);
    if (!fb || !tb) return;
    const pts = connectorPath(
      { from: fb, to: tb, fromAnchor: c.from.anchor, toAnchor: c.to.anchor, fromOutline: outlineOf(c.from.node), toOutline: outlineOf(c.to.node) },
      {
        straight: c.route === "straight",
        points: c.points?.map(([x, y]) => [origin.x + x, origin.y + y] as [number, number]),
        obstacles: obstaclesIn(siblings, new Set([c.from.node, c.to.node])),
      },
    );
    if (pts.length < 2) return;
    const stroke = color(c.stroke ?? "$text-secondary", mode)!;
    const sw = c.stroke_width ?? 1.5;
    const end = c.end_arrow ?? "arrow";
    const line = pts.map((p) => [...p] as [number, number]);
    const head = (tip: [number, number], from: [number, number], kind: string, setEnd: (p: [number, number]) => void) => {
      if (kind === "none") return;
      const len = Math.hypot(tip[0] - from[0], tip[1] - from[1]) || 1;
      const ux = (tip[0] - from[0]) / len, uy = (tip[1] - from[1]) / len;
      if (kind === "dot") {
        ops.push({ op: "ellipse", x: tip[0] - 3.5, y: tip[1] - 3.5, w: 7, h: 7, fill: stroke, sw: 0, el: c.id });
        return;
      }
      setEnd([tip[0] - ux * ARROW * 0.8, tip[1] - uy * ARROW * 0.8]);
      const base = [tip[0] - ux * ARROW, tip[1] - uy * ARROW];
      const half = ARROW * 0.45;
      const d = `M${r2(tip[0])} ${r2(tip[1])} L${r2(base[0] - uy * half)} ${r2(base[1] + ux * half)} L${r2(base[0] + uy * half)} ${r2(base[1] - ux * half)} Z`;
      ops.push({ op: "path", d, box: { x: tip[0] - ARROW, y: tip[1] - ARROW, w: 2 * ARROW, h: 2 * ARROW }, fill: stroke, sw: 0, el: c.id });
    };
    const lineAt = ops.length;
    head(pts.at(-1)!, pts.at(-2)!, end, (p) => (line[line.length - 1] = p));
    head(pts[0], pts[1], c.start_arrow ?? "none", (p) => (line[0] = p));
    ops.splice(lineAt, 0, { op: "polyline", points: line.map(([x, y]) => [r2(x), r2(y)]), stroke, sw, dash: dashArray(c.dash, sw), join: "round", el: c.id });
    if (c.label) {
      let best = 0, bi = 1;
      for (let i = 1; i < pts.length; i++) {
        const l = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
        if (l > best) {
          best = l;
          bi = i;
        }
      }
      const mx = (pts[bi][0] + pts[bi - 1][0]) / 2, my = (pts[bi][1] + pts[bi - 1][1]) / 2;
      const size = 12;
      const tw = measure(c.label, 400, false, size);
      ops.push({ op: "rect", x: r2(mx - tw / 2 - 6), y: r2(my - 10), w: r2(tw + 12), h: 20, r: 4, fill: bg ?? color("$bg", mode), sw: 0, el: c.id });
      const f = face(400, false);
      ops.push({ op: "text", x: r2(mx - tw / 2), y: r2(my - 10 + (20 - (f.asc + f.desc) * size) / 2 + f.asc * size), text: c.label, weight: 400, italic: false, size, fill: color("$text-secondary", mode)!, el: c.id });
    }
  }

  /** One top-level node (or any node with a known absolute position) as ops. */
  function layTop(n: DesignNode, mode: Mode): LaidNode {
    const w = widthOf(n);
    const h = heightOf(n, w);
    const ops: Op[] = [];
    if (n.type !== "connector") {
      local.set(n.id, { x: n.x, y: n.y, w, h });
      draw(n, n.x, n.y, w, h, mode, ops);
    }
    return { id: n.id, box: { x: n.type === "connector" ? 0 : n.x, y: n.type === "connector" ? 0 : n.y, w, h }, ops };
  }

  /** A whole page: every top-level node, for the canvas, thumbnails and review. */
  function layoutPage(page: Page): LaidPage {
    boxes.clear();
    local.clear();
    overflow.clear();
    const nodes: LaidNode[] = [];
    const conns: ConnectorNode[] = [];
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const n of page.children) {
      if (n.type === "connector") {
        conns.push(n);
        continue;
      }
      if (n.visible === false) continue;
      const laid = layTop(n, design.mode);
      nodes.push(laid);
      const b = laid.box;
      x0 = Math.min(x0, b.x);
      y0 = Math.min(y0, b.y);
      x1 = Math.max(x1, b.x + b.w);
      y1 = Math.max(y1, b.y + b.h);
    }
    const connectors: Op[] = [];
    for (const c of conns) drawConnector(c, design.mode, connectors, color(page.background, design.mode), page.children);
    const box = Number.isFinite(x0) ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 0, h: 0 };
    return { nodes, connectors, box, background: color(page.background, design.mode), boxes: new Map(boxes), local: new Map(local), overflow: new Set(overflow) };
  }

  return { layoutPage, color, paint, hugW, hugH, widthOf, heightOf, expand };
}

/** All ops of a laid page in paint order: the nodes, then the page's connectors. */
export const pageOps = (p: LaidPage): Op[] => [...p.nodes.flatMap((n) => n.ops), ...p.connectors];

/**
 * Moves a child of a resized (non-auto-layout) container by its constraints
 * (ADR §3.2): from the old container size (ow × oh) to the new one.
 */
export function constrain<N extends DesignNode>(c: N, ow: number, oh: number, nw: number, nh: number): N {
  if (c.type === "connector" || (ow === nw && oh === nh)) return c;
  const k = (c as { constraints?: Constraints }).constraints ?? {};
  const axis = (mode: string | undefined, pos: number, size: number, o: number, n: number): [number, number] => {
    switch (mode) {
      case "right":
      case "bottom":
        return [pos + (n - o), size];
      case "left-right":
      case "top-bottom":
        return [pos, Math.max(0, size + (n - o))];
      case "center":
        return [pos + (n - o) / 2, size];
      case "scale":
        return o ? [(pos * n) / o, (size * n) / o] : [pos, size];
      default:
        return [pos, size];
    }
  };
  const [x, w] = axis(k.h, c.x, c.w, ow, nw);
  const [y, h] = axis(k.v, c.y, c.h, oh, nh);
  if (x === c.x && y === c.y && w === c.w && h === c.h) return c;
  return { ...c, x: r2(x), y: r2(y), w: r2(w), h: r2(h) };
}

/**
 * The design with every laid node's cached box rewritten from the layout
 * (ADR §3.2: auto-laid children's x, y, w, h and hug sizes are a cache the
 * editor refreshes when it saves). Nodes whose box already matches are kept
 * as they are, so an unchanged design comes back identical.
 */
export function settle(design: Design): Design {
  const lay = makeLayout(design);
  let changed = false;
  const pages = design.pages.map((p) => {
    const { local } = lay.layoutPage(p);
    const fix = (n: DesignNode): DesignNode => {
      let out = n;
      if ("children" in n && Array.isArray(n.children)) {
        const kids = n.children.map(fix);
        if (kids.some((k, i) => k !== n.children[i])) out = { ...n, children: kids } as DesignNode;
      }
      const b = local.get(n.id);
      if (b && out.type !== "connector") {
        const nb = { x: r2(b.x), y: r2(b.y), w: r2(b.w), h: r2(b.h) };
        if (nb.x !== out.x || nb.y !== out.y || nb.w !== out.w || nb.h !== out.h) out = { ...out, ...nb };
      }
      if (out !== n) changed = true;
      return out;
    };
    const kids = p.children.map(fix);
    return kids.some((k, i) => k !== p.children[i]) ? { ...p, children: kids } : p;
  });
  return changed ? { ...design, pages } : design;
}
