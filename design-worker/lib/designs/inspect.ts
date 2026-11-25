// Inspect (ADR-designs §3.8–3.9): a node as code a developer can start from,
// in CSS, Tailwind (HTML with classes) or React (TSX with Tailwind classes),
// plus its spacing, type styles, the tokens it uses and its images. The
// inspector's Inspect tab and the design_inspect tool (through the worker)
// both call inspect(), so they always agree. Boxes are the settled layout.
//
// Colours stay tokens: `var(--surface)` in CSS, `bg-surface` in Tailwind when
// the app's @theme maps the token (tokens.generated.json `tailwind`), and an
// arbitrary `bg-[var(--token)]` otherwise. Instances show up in React as
// their component with text overrides as props; the component follows once.
import { autoLayoutOf, childrenOf, LINE, makeLayout, sizingOf, STICKY_COLORS, STICKY_TEXT, type Box } from "./layout.ts";
import type { Color, Design, DesignNode, InstanceNode, Mode, Paint, Paragraph, Run } from "./schema.ts";
import { DUSK } from "./tokens.ts";

export type InspectTarget = "css" | "tailwind" | "react";
export const INSPECT_TARGETS: InspectTarget[] = ["css", "tailwind", "react"];

export type TokenUse = { name: string; value: string | null; used_for: string[] };
export type TypeStyle = { text: string; size: number; weight: number; italic: boolean; line_height: number; color: string; token?: string };
export type Inspected = {
  node: { id: string; name: string; type: string };
  target: InspectTarget;
  mode: Mode;
  box: Box;
  code: string;
  spacing: { direction: string; gap: number; padding: [number, number, number, number]; align: string; justify: string } | null;
  type: TypeStyle[];
  tokens: TokenUse[];
  assets: { id: string; mime: string; w: number; h: number; alt?: string }[];
  /** Nodes left out because the subtree is large. */
  truncated?: boolean;
};

export class InspectError extends Error {}

/** At most this many nodes are written out as code. */
export const MAX_NODES = 150;

type Decl = { p: string; v: string; token?: string };
type Spec = {
  id: string;
  name: string;
  type: string;
  decls: Decl[];
  children: Spec[];
  /** Text content as paragraphs of runs, each with the decls that differ from the node's. */
  text?: { runs: { text: string; decls: Decl[] }[] }[];
  /** For React: an instance renders as <Component prop="…" />. */
  instance?: { id: string; component: string; overrides: Record<string, { text?: string; visible?: boolean }> };
  img?: { asset: string; alt: string };
  note?: string;
};

const px = (n: number) => `${Math.round(n * 100) / 100}px`;
const r2 = (n: number) => Math.round(n * 100) / 100;
const weightOf = (r: Run) => r.weight ?? (r.bold ? 700 : 400);
const pascal = (s: string) => s.replace(/[^A-Za-z0-9]+/g, " ").trim().split(" ").filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join("") || "Node";
const camel = (s: string) => {
  const p = pascal(s);
  return p[0].toLowerCase() + p.slice(1);
};
const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "node";

export function inspect(design: Design, nodeId: string, target: InspectTarget): Inspected {
  if (!INSPECT_TARGETS.includes(target)) throw new InspectError(`target: use css, tailwind or react`);
  const lay = makeLayout(design);
  // Find the node, its page and ancestors (for the mode in effect).
  let page;
  let path: DesignNode[] = [];
  const find = (list: DesignNode[], trail: DesignNode[]): boolean => {
    for (const n of list) {
      if (n.id === nodeId) {
        path = [...trail, n];
        return true;
      }
      if (find(childrenOf(n), [...trail, n])) return true;
    }
    return false;
  };
  for (const p of design.pages) if (find(p.children, [])) { page = p; break; }
  if (!page) throw new InspectError(`node: ${nodeId} isn't in the design`);
  const node = path.at(-1)!;
  if (node.type === "connector") throw new InspectError(`node: ${nodeId} is a connector; inspect the nodes it joins`);
  let mode: Mode = design.mode;
  for (const a of path) if ("mode" in a && a.mode) mode = a.mode;
  const laid = lay.layoutPage(page);
  const boxOf = (id: string) => laid.boxes.get(id);
  const rootBox = boxOf(node.id);
  if (!rootBox) throw new InspectError(`node: ${nodeId} isn't drawn (it's hidden or inside a hidden node)`);

  const set = design.tokens_ref ? design.token_sets[design.tokens_ref.set] : undefined;
  const tokens = new Map<string, Set<string>>();
  const valueOf = (name: string, m: Mode) => {
    const t = (m === "light" && set?.modes.light?.[name]) || set?.modes.dark[name];
    return t?.kind === "color" ? t.value : null;
  };
  const color = (c: Color, use: string): Decl["v"] | { v: string; token: string } => {
    if (!c.startsWith("$")) return c;
    const name = c.slice(1);
    tokens.set(name, (tokens.get(name) ?? new Set()).add(use));
    return { v: `var(--${name})`, token: name };
  };
  const colorDecl = (p: string, c: Color, use: string): Decl => {
    const r = color(c, use);
    return typeof r === "string" ? { p, v: r } : { p, ...r };
  };
  const paintDecl = (paint: Paint, use: string): Decl => {
    if (typeof paint === "string") return colorDecl("background", paint, use);
    const [a, b] = paint.stops.map((s) => {
      const r = color(s, use);
      return typeof r === "string" ? r : r.v;
    });
    return { p: "background", v: `linear-gradient(${paint.angle}deg, ${a}, ${b})` };
  };
  const types: TypeStyle[] = [];
  const assets = new Map<string, Inspected["assets"][number]>();
  let count = 0;
  let truncated = false;

  const runDecls = (r: Run, use: string): Decl[] => {
    const d: Decl[] = [{ p: "font-size", v: px(r.size) }, { p: "font-weight", v: String(weightOf(r)) }];
    if (r.italic) d.push({ p: "font-style", v: "italic" });
    const deco = [r.underline && "underline", r.strike && "line-through"].filter(Boolean).join(" ");
    if (deco) d.push({ p: "text-decoration", v: deco });
    if (r.color) d.push(colorDecl("color", r.color, use));
    if (r.highlight) d.push(colorDecl("background", r.highlight, use + " highlight"));
    return d;
  };
  const textSpec = (paragraphs: Paragraph[], use: string, decls: Decl[], defaultColor?: string) => {
    const first = paragraphs[0]?.runs[0];
    if (!first) return undefined;
    const base = runDecls(first, use);
    if (!first.color && defaultColor) base.push({ p: "color", v: defaultColor });
    decls.push({ p: "font-family", v: "Inter, sans-serif" }, ...base, { p: "line-height", v: String(r2(LINE * (paragraphs[0].lineSpacing || 1))) });
    const align = paragraphs[0].align;
    if (align && align !== "left") decls.push({ p: "text-align", v: align });
    const key = (d: Decl) => d.p + ":" + d.v;
    const have = new Set(base.map(key));
    for (const p of paragraphs)
      for (const r of p.runs) {
        const c = r.color ? color(r.color, use) : undefined;
        const ts: TypeStyle = { text: r.text.length > 40 ? r.text.slice(0, 39) + "…" : r.text, size: r.size, weight: weightOf(r), italic: !!r.italic, line_height: r2(r.size * LINE * (p.lineSpacing || 1)), color: typeof c === "object" ? (valueOf(c.token, mode) ?? c.v) : (c ?? defaultColor ?? ""), ...(typeof c === "object" ? { token: c.token } : {}) };
        if (!types.some((t) => t.size === ts.size && t.weight === ts.weight && t.italic === ts.italic && t.color === ts.color && t.token === ts.token)) types.push(ts);
      }
    return paragraphs.map((p) => ({ runs: p.runs.map((r) => ({ text: r.text, decls: runDecls(r, use).filter((d) => !have.has(key(d))) })) }));
  };

  /** parentAL: the parent's auto-layout direction, "none" for a free container, undefined for the root. */
  const build = (n: DesignNode, parent: DesignNode | undefined, nodeMode: Mode): Spec | undefined => {
    if (n.visible === false || n.type === "connector") return undefined;
    if (++count > MAX_NODES) {
      truncated = true;
      return undefined;
    }
    const instanceOf = n.type === "instance" ? (n as InstanceNode) : undefined;
    const e = lay.expand(n) as DesignNode;
    const m: Mode = ("mode" in e && e.mode) || nodeMode;
    const name = n.name ?? (instanceOf ? "Instance" : n.type);
    const use = name;
    const decls: Decl[] = [];
    const b = boxOf(n.id);
    const pb = parent ? boxOf(parent.id) : undefined;
    const pal = parent ? autoLayoutOf(parent) : undefined;
    const sz = sizingOf(e);
    const absolute = parent && (!pal || ("absolute" in n && n.absolute));
    if (absolute && b && pb) decls.push({ p: "position", v: "absolute" }, { p: "left", v: px(b.x - pb.x) }, { p: "top", v: px(b.y - pb.y) });
    const dim = (axis: "w" | "h") => {
      const prop = axis === "w" ? "width" : "height";
      const s = sz[axis];
      if (s === "fill" && pal && !absolute) {
        const main = (pal.direction === "horizontal") === (axis === "w");
        decls.push(main ? { p: "flex", v: "1 1 0" } : { p: "align-self", v: "stretch" });
      } else if (s === "hug" && (e.type === "text" || autoLayoutOf(e))) {
        // Sized by its content.
      } else if (b) decls.push({ p: prop, v: px(axis === "w" ? b.w : b.h) });
    };
    dim("w");
    dim("h");
    const spec: Spec = { id: n.id, name, type: n.type, decls, children: [] };
    const al = autoLayoutOf(e);
    if (al) {
      decls.push({ p: "display", v: "flex" }, { p: "flex-direction", v: al.direction === "horizontal" ? "row" : "column" });
      if (al.gap) decls.push({ p: "gap", v: px(al.gap) });
      if (al.padding.some(Boolean)) decls.push({ p: "padding", v: al.padding.map(px).join(" ") });
      if (al.align !== "start") decls.push({ p: "align-items", v: al.align === "end" ? "flex-end" : "center" });
      if (al.justify !== "start") decls.push({ p: "justify-content", v: al.justify === "end" ? "flex-end" : al.justify });
    }
    const styled = e as DesignNode & { fill?: Paint; stroke?: Color; stroke_width?: number; dash?: string; radius?: number; clip?: boolean };
    if (e.type === "sticky") {
      decls.push({ p: "background", v: STICKY_COLORS[e.color ?? "yellow"] }, { p: "padding", v: "12px" }, { p: "color", v: STICKY_TEXT });
      spec.text = [{ runs: [{ text: e.text, decls: [] }] }];
    } else if (e.type !== "text" && e.type !== "image" && e.type !== "group") {
      if (styled.fill !== undefined && e.type !== "path") decls.push(paintDecl(styled.fill, use + " fill"));
      if (styled.stroke) {
        decls.push({ p: "border-width", v: px(styled.stroke_width ?? 1) }, { p: "border-style", v: styled.dash && styled.dash !== "solid" ? (styled.dash === "dot" ? "dotted" : "dashed") : "solid" });
        decls.push(colorDecl("border-color", styled.stroke, use + " stroke"));
      }
    }
    if (e.type === "shape" && e.shape === "ellipse") decls.push({ p: "border-radius", v: "50%" });
    else if (e.type === "section") decls.push({ p: "border-radius", v: "8px" });
    else if (styled.radius) decls.push({ p: "border-radius", v: px(styled.radius) });
    if (styled.clip) decls.push({ p: "overflow", v: "hidden" });
    if (n.opacity !== undefined && n.opacity < 1) decls.push({ p: "opacity", v: String(n.opacity) });
    if (n.rotation) decls.push({ p: "transform", v: `rotate(${n.rotation}deg)` });
    if (!parent && childrenOf(e).some((c) => c.type !== "connector" && (!al || ("absolute" in c && c.absolute)))) decls.unshift({ p: "position", v: "relative" });
    else if (parent && !absolute && childrenOf(e).some((c) => c.type !== "connector" && (!al || ("absolute" in c && c.absolute)))) decls.push({ p: "position", v: "relative" });

    switch (e.type) {
      case "text":
        spec.text = textSpec(e.paragraphs, use, decls);
        break;
      case "shape":
        if (e.shape !== "rect" && e.shape !== "roundRect" && e.shape !== "ellipse") spec.note = `shape "${e.shape}": draw it as an SVG (Export → SVG)`;
        if (e.text?.paragraphs.length) {
          spec.text = textSpec(e.text.paragraphs, use, decls);
          decls.push({ p: "padding", v: "8px" });
        }
        break;
      case "path":
        spec.note = "vector: use the SVG export for the path";
        if (e.stroke) decls.push(colorDecl("color", e.stroke, use + " stroke"));
        break;
      case "image": {
        decls.push({ p: "object-fit", v: e.fit === "contain" ? "contain" : e.fit === "fill" ? "fill" : "cover" });
        const a = design.assets[e.asset];
        if (a) assets.set(e.asset, { id: e.asset, mime: a.mime, w: a.w, h: a.h, ...(a.alt ? { alt: a.alt } : {}) });
        spec.img = { asset: e.asset, alt: e.alt ?? a?.alt ?? "" };
        if (e.crop && (e.crop.l || e.crop.t || e.crop.r || e.crop.b)) spec.note = `cropped to l ${e.crop.l}, t ${e.crop.t}, r ${e.crop.r}, b ${e.crop.b} of the image`;
        break;
      }
    }
    if (instanceOf) {
      const main = findNode(design, instanceOf.component);
      const overrides: Record<string, { text?: string; visible?: boolean }> = {};
      for (const [cid, o] of Object.entries(instanceOf.overrides ?? {})) if (o.text !== undefined || o.visible === false) overrides[cid] = { text: o.text, visible: o.visible };
      spec.instance = { id: instanceOf.component, component: main?.name ?? "Component", overrides };
    }
    for (const c of childrenOf(e)) {
      const s = build(c, e, m);
      if (s) spec.children.push(s);
    }
    return spec;
  };
  const root = build(node, undefined, mode)!;

  // Components used inside, written once after the code (React only).
  // Keyed by component id; nested instances inside a main are collected too.
  const comps = new Map<string, Spec>();
  if (target === "react") {
    const collect = (s: Spec) => {
      for (const c of s.children) collect(c);
      if (s.instance && !comps.has(s.instance.id)) {
        const main = findNode(design, s.instance.id);
        if (main) {
          count = 0;
          const ms = build(main, undefined, mode);
          if (ms) {
            comps.set(s.instance.id, ms);
            collect(ms);
          }
        }
      }
    };
    collect(root);
  }

  const code = target === "css" ? toCss(root) : target === "tailwind" ? toHtml(root, 0) : toReact(root, comps);
  const al = autoLayoutOf(lay.expand(node));
  return {
    node: { id: node.id, name: node.name ?? node.type, type: node.type },
    target,
    mode,
    box: { x: r2(rootBox.x), y: r2(rootBox.y), w: r2(rootBox.w), h: r2(rootBox.h) },
    code,
    spacing: al ? { direction: al.direction, gap: al.gap, padding: al.padding, align: al.align, justify: al.justify } : null,
    type: types,
    tokens: [...tokens].sort(([a], [b]) => a.localeCompare(b)).map(([name, uses]) => ({ name, value: valueOf(name, mode), used_for: [...uses] })),
    assets: [...assets.values()],
    ...(truncated ? { truncated } : {}),
  };
}

function findNode(root: { children?: DesignNode[]; pages?: { children: DesignNode[] }[] } | DesignNode, id: string): DesignNode | undefined {
  const lists: DesignNode[][] = "pages" in root && root.pages ? root.pages.map((p) => p.children) : [childrenOf(root as DesignNode)];
  for (const list of lists)
    for (const n of list) {
      if (n.id === id) return n;
      const f = findNode(n, id);
      if (f) return f;
    }
  return undefined;
}

// ---------- CSS ----------

function toCss(root: Spec): string {
  const used = new Set<string>();
  const out: string[] = [];
  const cls = (s: Spec, prefix?: string) => {
    let c = prefix ? `${prefix}__${slug(s.name)}` : slug(s.name);
    for (let i = 2; used.has(c); i++) c = `${prefix ? prefix + "__" : ""}${slug(s.name)}-${i}`;
    used.add(c);
    return c;
  };
  const rule = (sel: string, decls: Decl[], raw?: string) => {
    if (!decls.length && !raw) return;
    const note = raw?.replace(/\*\//g, "* /");
    out.push(`.${sel} {${note ? `\n  /* ${note} */` : ""}${decls.map((d) => `\n  ${d.p}: ${d.v};`).join("")}\n}`);
  };
  const walk = (s: Spec, prefix?: string) => {
    const c = cls(s, prefix);
    rule(c, s.decls, s.instance ? `instance of ${pascal(s.instance.component)}${s.note ? "; " + s.note : ""}` : s.note);
    s.text?.forEach((p, pi) => p.runs.forEach((r, ri) => r.decls.length && rule(`${c} .run-${pi + 1}-${ri + 1}`, r.decls, `"${r.text.trim().slice(0, 30)}"`)));
    for (const k of s.children) walk(k, prefix ?? c);
  };
  walk(root);
  return out.join("\n\n") + "\n";
}

// ---------- Tailwind ----------

const SCALE = (v: string) => {
  const n = parseFloat(v);
  return v.endsWith("px") && Number.isInteger(n / 4) ? String(n / 4) : `[${v}]`;
};
const arb = (v: string) => `[${v.replace(/ /g, "_")}]`;
function colorClass(prefix: string, d: Decl): string {
  if (d.token) {
    const tw = DUSK.tailwind[d.token];
    return tw ? `${prefix}-${tw}` : `${prefix}-[var(--${d.token})]`;
  }
  return `${prefix}-${arb(d.v)}`;
}
function padClasses(v: string): string[] {
  const [t, r, b, l] = v.split(" ").length === 1 ? [v, v, v, v] : v.split(" ");
  if (t === r && r === b && b === l) return [`p-${SCALE(t)}`];
  if (t === b && l === r) return [`px-${SCALE(l)}`, `py-${SCALE(t)}`];
  return [`pt-${SCALE(t)}`, `pr-${SCALE(r)}`, `pb-${SCALE(b)}`, `pl-${SCALE(l)}`];
}
const WEIGHT: Record<string, string> = { "400": "font-normal", "500": "font-medium", "600": "font-semibold", "700": "font-bold" };

export function tailwind(decls: Decl[]): string[] {
  const out: string[] = [];
  for (const d of decls) {
    switch (d.p) {
      case "width": out.push(`w-${arb(d.v)}`); break;
      case "height": out.push(`h-${arb(d.v)}`); break;
      case "flex": out.push("flex-1"); break;
      case "align-self": out.push("self-stretch"); break;
      case "position": out.push(d.v); break;
      case "left": out.push(`left-${arb(d.v)}`); break;
      case "top": out.push(`top-${arb(d.v)}`); break;
      case "display": out.push("flex"); break;
      case "flex-direction": out.push(d.v === "row" ? "flex-row" : "flex-col"); break;
      case "gap": out.push(`gap-${SCALE(d.v)}`); break;
      case "padding": out.push(...padClasses(d.v)); break;
      case "align-items": out.push(d.v === "center" ? "items-center" : "items-end"); break;
      case "justify-content": out.push(d.v === "center" ? "justify-center" : d.v === "flex-end" ? "justify-end" : "justify-between"); break;
      case "background": out.push(colorClass("bg", d)); break;
      case "border-width": out.push(d.v === "1px" ? "border" : `border-${arb(d.v)}`); break;
      case "border-style": if (d.v !== "solid") out.push(`border-${d.v}`); break;
      case "border-color": out.push(colorClass("border", d)); break;
      case "border-radius": out.push(d.v === "50%" ? "rounded-full" : `rounded-${arb(d.v)}`); break;
      case "overflow": out.push("overflow-hidden"); break;
      case "opacity": out.push(`opacity-${arb(d.v)}`); break;
      case "transform": out.push(`rotate-${arb(d.v.slice(7, -1))}`); break;
      case "color": out.push(colorClass("text", d)); break;
      case "font-size": out.push(`text-${arb(d.v)}`); break;
      case "font-weight": out.push(WEIGHT[d.v] ?? `font-${arb(d.v)}`); break;
      case "font-style": out.push("italic"); break;
      case "text-decoration": out.push(...d.v.split(" ")); break;
      case "line-height": out.push(`leading-${arb(d.v)}`); break;
      case "text-align": out.push(`text-${d.v}`); break;
      case "object-fit": out.push(`object-${d.v}`); break;
      case "font-family": out.push("font-sans"); break;
      default: out.push(`[${d.p}:${d.v.replace(/ /g, "_")}]`);
    }
  }
  return out;
}

const escHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escJsx = (s: string) => s.replace(/[{}<>]/g, (c) => `{"${c}"}`);

function textMarkup(s: Spec, react: boolean): string {
  const esc = react ? escJsx : escHtml;
  const attr = react ? "className" : "class";
  return (s.text ?? [])
    .map((p) => p.runs.map((r) => (r.decls.length ? `<span ${attr}="${tailwind(r.decls).join(" ")}">${esc(r.text)}</span>` : esc(r.text))).join(""))
    .join(react ? "<br />" : "<br>");
}

function element(s: Spec, depth: number, react: boolean, inner: (s: Spec, depth: number) => string): string {
  const pad = "  ".repeat(depth);
  const attr = react ? "className" : "class";
  const classes = tailwind(s.decls).join(" ");
  const note = s.note ? (react ? `${pad}{/* ${s.note} */}\n` : `${pad}<!-- ${s.note} -->\n`) : "";
  if (s.img) {
    const src = react ? `src={assets.${s.img.asset}}` : `src="${s.img.asset}.png"`;
    return `${note}${pad}<img ${attr}="${classes}" ${src} alt="${s.img.alt.replace(/"/g, "&quot;")}"${react ? " />" : ">"}`;
  }
  if (s.text && !s.children.length) {
    const tag = s.type === "text" ? "p" : "div";
    return `${note}${pad}<${tag} ${attr}="${classes}">${textMarkup(s, react)}</${tag}>`;
  }
  if (!s.children.length) return `${note}${pad}<div ${attr}="${classes}"${react ? " />" : "></div>"}`;
  return `${note}${pad}<div ${attr}="${classes}">\n${s.children.map((c) => inner(c, depth + 1)).join("\n")}\n${pad}</div>`;
}

function toHtml(s: Spec, depth: number): string {
  const pad = "  ".repeat(depth);
  const head = s.instance ? `${pad}<!-- ${pascal(s.instance.component)} -->\n` : "";
  return head + element(s, depth, false, toHtml);
}

// ---------- React ----------

const RESERVED = new Set("break case catch class const continue debugger default delete do else enum export extends false finally for function if import in instanceof new null return super switch this throw true try typeof var void while with yield let static implements interface package private protected public await assets className key ref children".split(" "));

/** A valid, unused JS identifier from a layer name. */
function ident(name: string, used: Set<string>): string {
  let p = camel(name);
  if (/^[0-9]/.test(p) || RESERVED.has(p)) p = `${p}Text`.replace(/^([0-9])/, "t$1");
  let out = p;
  for (let i = 2; used.has(out); i++) out = `${p}${i}`;
  used.add(out);
  return out;
}

type CompInfo = { name: string; spec: Spec; text: Map<string, string>; show: Map<string, string>; defaults: Map<string, string> };

function toReact(root: Spec, comps: Map<string, Spec>): string {
  const usesAssets = (s: Spec): boolean => !!s.img || s.children.some(usesAssets);
  const walk = (s: Spec, f: (s: Spec) => void) => {
    f(s);
    s.children.forEach((c) => walk(c, f));
  };
  // Every instance's hidden layers become show props on its component.
  const hiddenIds = new Map<string, Set<string>>();
  const noteHidden = (s: Spec) =>
    walk(s, (x) => {
      if (!x.instance) return;
      for (const [cid, o] of Object.entries(x.instance.overrides)) if (o.visible === false) hiddenIds.set(x.instance.id, (hiddenIds.get(x.instance.id) ?? new Set()).add(cid));
    });
  noteHidden(root);
  comps.forEach(noteHidden);
  // Component names, props per text layer (defaulting to the main's text) and show props.
  const names = new Set<string>();
  const info = new Map<string, CompInfo>();
  for (const [cid, spec] of comps) {
    let name = pascal(spec.name);
    for (let i = 2; names.has(name); i++) name = `${pascal(spec.name)}${i}`;
    names.add(name);
    const used = new Set<string>();
    const text = new Map<string, string>();
    const show = new Map<string, string>();
    const defaults = new Map<string, string>();
    walk(spec, (x) => {
      if (x === spec) return;
      if (x.type === "text" && x.text) {
        text.set(x.id, ident(x.name, used));
        defaults.set(x.id, x.text.map((p) => p.runs.map((r) => r.text).join("")).join("\n"));
      }
      if (hiddenIds.get(cid)?.has(x.id)) show.set(x.id, ident(`show ${x.name}`, used));
    });
    info.set(cid, { name, spec, text, show, defaults });
  }
  const PH = "\u0000";
  const jsx = (s: Spec, depth: number): string => {
    if (s.instance) {
      const pad = "  ".repeat(depth);
      const c = info.get(s.instance.id);
      const props: string[] = [];
      for (const [id, o] of Object.entries(s.instance.overrides)) {
        const t = c?.text.get(id);
        if (o.text !== undefined && t) props.push(`${t}={${JSON.stringify(o.text)}}`);
        const v = c?.show.get(id);
        if (o.visible === false && v) props.push(`${v}={false}`);
      }
      const layout = tailwind(s.decls.filter((d) => ["flex", "align-self", "position", "left", "top", "width"].includes(d.p))).join(" ");
      if (layout) props.push(`className="${layout}"`);
      return `${pad}<${c?.name ?? pascal(s.instance.component)}${props.length ? " " + props.join(" ") : ""} />`;
    }
    return element(s, depth, true, jsx);
  };
  const parts: string[] = [];
  if (!root.instance) parts.push(`export function ${pascal(root.name)}(${usesAssets(root) ? "{ assets }: { assets: Record<string, string> }" : ""}) {\n  return (\n${jsx(root, 2)}\n  );\n}`);
  for (const c of info.values()) {
    // Text layers read their prop; hideable layers render only when shown.
    const render = (s: Spec, depth: number): string => {
      const p = c.text.get(s.id);
      const own: Spec = p && s.text ? { ...s, text: [{ runs: [{ text: `${PH}${p}${PH}`, decls: [] }] }] } : s;
      const inner = s.instance ? jsx(own, depth) : element(own, depth, true, render);
      const v = c.show.get(s.id);
      if (!v) return inner;
      const pad = "  ".repeat(depth);
      return `${pad}{${v} && (\n${inner.split("\n").map((l) => "  " + l).join("\n")}\n${pad})}`;
    };
    const rendered = element(c.spec, 2, true, render);
    const props = [
      ...[...c.text].map(([id, p]) => `${p} = ${JSON.stringify(c.defaults.get(id))}`),
      ...[...c.show.values()].map((v) => `${v} = true`),
      'className = ""',
    ];
    const code = rendered.replace(new RegExp(`${PH}([A-Za-z0-9_$]+)${PH}`, "g"), "{$1}").replace(/className="([^"]*)"/, "className={`$1 ${className}`}");
    parts.push(`export function ${c.name}({ ${props.join(", ")} }) {\n  return (\n${code}\n  );\n}`);
  }
  if (root.instance) {
    const usage = jsx(root, 0);
    parts.push(`// This instance:\n// ${usage.trim()}`);
  }
  return parts.join("\n\n") + "\n";
}
