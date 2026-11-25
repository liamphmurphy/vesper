// SVG → design nodes where the mapping is clear (ADR-designs §3.9
// design_import, LAZYAGENTS-152): rect, circle, ellipse, line, polyline,
// polygon, path and text, inside <svg> and <g> with translate transforms.
// Everything else (gradients, masks, clip paths, images, <use>, other
// transforms, arcs) is skipped with a warning naming it, never guessed.
// No DOM: a small tag tokenizer, so the design worker runs it in Node.
import type { Color, DesignNode, GroupNode, PathNode, ShapeNode, TextNode } from "./schema.ts";

export class SvgImportError extends Error {}

export const MAX_SVG = 500_000;
export const MAX_SVG_NODES = 2_000;

const r2 = (n: number) => Math.round(n * 100) / 100;

type El = { name: string; attrs: Record<string, string>; children: El[]; text: string };

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
const decode = (s: string) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e: string) =>
    e[0] === "#" ? String.fromCodePoint(e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : (ENTITIES[e] ?? m),
  );

/** Parses the XML into an element tree; throws SvgImportError on broken markup. */
export function parseSvg(src: string): El {
  if (src.length > MAX_SVG) throw new SvgImportError(`the SVG is ${src.length} characters; the cap is ${MAX_SVG}`);
  const root: El = { name: "#root", attrs: {}, children: [], text: "" };
  const stack: El[] = [root];
  const re = /<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<![^>]*>|<\?[\s\S]*?\?>|<\/\s*([\w:-]+)\s*>|<([\w:-]+)((?:\s+[\w:-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
  let m: RegExpExecArray | null;
  let at = 0;
  while ((m = re.exec(src))) {
    if (m.index !== at) break;
    at = re.lastIndex;
    const top = stack.at(-1)!;
    if (m[1] !== undefined) top.text += m[1];
    else if (m[2]) {
      if (top.name !== m[2]) throw new SvgImportError(`</${m[2]}> closes <${top.name === "#root" ? "nothing" : top.name}>`);
      stack.pop();
    } else if (m[3]) {
      const attrs: Record<string, string> = {};
      for (const a of m[4].matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs[a[1]] = decode(a[2] ?? a[3]);
      const el: El = { name: m[3], attrs, children: [], text: "" };
      top.children.push(el);
      if (!m[5]) stack.push(el);
    } else if (m[6] !== undefined) top.text += decode(m[6]);
  }
  if (at !== src.length) throw new SvgImportError(`the SVG markup is broken near "${src.slice(at, at + 40)}"`);
  if (stack.length > 1) throw new SvgImportError(`<${stack.at(-1)!.name}> is never closed`);
  const svg = root.children.find((c) => c.name === "svg");
  if (!svg) throw new SvgImportError("expected an <svg> element");
  return svg;
}

const NAMED: Record<string, string> = { black: "#000000", white: "#FFFFFF", red: "#FF0000", green: "#008000", blue: "#0000FF", gray: "#808080", grey: "#808080", currentcolor: "#000000" };
const hex2 = (n: number) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, "0").toUpperCase();

/** An SVG paint as a design colour; null for none; undefined (and a warning) for what it can't map. */
function colorOf(v: string | undefined, opacity: number, warn: (s: string) => void): Color | null | undefined {
  if (v === undefined) return undefined;
  v = v.trim().toLowerCase();
  if (v === "none" || v === "transparent") return null;
  let hex: string | undefined;
  if (/^#[0-9a-f]{3}$/.test(v)) hex = "#" + [...v.slice(1)].map((c) => c + c).join("");
  else if (/^#[0-9a-f]{6}([0-9a-f]{2})?$/.test(v)) hex = v;
  else if (NAMED[v]) hex = NAMED[v];
  else {
    const m = v.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/);
    if (m) {
      hex = `#${hex2(+m[1])}${hex2(+m[2])}${hex2(+m[3])}`;
      if (m[4] !== undefined) opacity *= +m[4];
    }
  }
  if (!hex) {
    warn(`paint ${v} isn't imported`);
    return undefined;
  }
  hex = hex.toUpperCase();
  if (opacity < 1) hex = hex.slice(0, 7) + hex2(opacity * (hex.length === 9 ? parseInt(hex.slice(7), 16) : 255));
  return hex as Color;
}

const num = (v: string | undefined, d = 0) => {
  const n = v === undefined ? NaN : parseFloat(v);
  return Number.isFinite(n) ? n : d;
};
const nums = (s: string) => (s.match(/-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/gi) ?? []).map(Number);

type Style = Record<string, string>;
const styleOf = (el: El, inherited: Style): Style => {
  const s: Style = { ...inherited };
  for (const k of ["fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity", "opacity", "font-size", "font-weight", "stroke-dasharray", "stroke-linecap", "stroke-linejoin"]) if (el.attrs[k] !== undefined) s[k] = el.attrs[k];
  for (const d of (el.attrs.style ?? "").split(";")) {
    const i = d.indexOf(":");
    if (i > 0) s[d.slice(0, i).trim()] = d.slice(i + 1).trim();
  }
  if (el.attrs.opacity === undefined && !/(^|;)\s*opacity\s*:/.test(el.attrs.style ?? "")) delete s.opacity; // opacity doesn't inherit
  return s;
};

/** Absolute M/L/C/Q/Z segments from any SVG path data; arcs become lines (with a warning). */
export function absPath(d: string, warn: (s: string) => void): { cmd: string; pts: [number, number][] }[] {
  const toks = d.match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/g) ?? [];
  const out: { cmd: string; pts: [number, number][] }[] = [];
  let i = 0, cmd = "", x = 0, y = 0, sx = 0, sy = 0;
  let lastC: [number, number] | null = null, lastQ: [number, number] | null = null;
  let arcWarned = false;
  const n = () => {
    const t = toks[i++];
    if (t === undefined || /[a-z]/i.test(t)) throw new SvgImportError(`path data "${d.slice(0, 40)}" is cut short`);
    return +t;
  };
  while (i < toks.length) {
    if (/[a-z]/i.test(toks[i])) cmd = toks[i++];
    else if (!cmd) throw new SvgImportError(`path data "${d.slice(0, 40)}" needs a command before a number`);
    const rel = cmd === cmd.toLowerCase() && cmd !== "z" ? true : false;
    const ox = rel ? x : 0, oy = rel ? y : 0;
    const C = cmd.toUpperCase();
    let nextC: [number, number] | null = null, nextQ: [number, number] | null = null;
    switch (C) {
      case "M": {
        x = ox + n(); y = oy + n(); sx = x; sy = y;
        out.push({ cmd: "M", pts: [[x, y]] });
        cmd = rel ? "l" : "L"; // further pairs are lines
        break;
      }
      case "L": x = ox + n(); y = oy + n(); out.push({ cmd: "L", pts: [[x, y]] }); break;
      case "H": x = ox + n(); out.push({ cmd: "L", pts: [[x, y]] }); break;
      case "V": y = oy + n(); out.push({ cmd: "L", pts: [[x, y]] }); break;
      case "C": {
        const p1: [number, number] = [ox + n(), oy + n()], p2: [number, number] = [ox + n(), oy + n()];
        x = ox + n(); y = oy + n();
        out.push({ cmd: "C", pts: [p1, p2, [x, y]] });
        nextC = p2;
        break;
      }
      case "S": {
        const p1: [number, number] = lastC ? [2 * x - lastC[0], 2 * y - lastC[1]] : [x, y];
        const p2: [number, number] = [ox + n(), oy + n()];
        x = ox + n(); y = oy + n();
        out.push({ cmd: "C", pts: [p1, p2, [x, y]] });
        nextC = p2;
        break;
      }
      case "Q": {
        const p1: [number, number] = [ox + n(), oy + n()];
        x = ox + n(); y = oy + n();
        out.push({ cmd: "Q", pts: [p1, [x, y]] });
        nextQ = p1;
        break;
      }
      case "T": {
        const p1: [number, number] = lastQ ? [2 * x - lastQ[0], 2 * y - lastQ[1]] : [x, y];
        x = ox + n(); y = oy + n();
        out.push({ cmd: "Q", pts: [p1, [x, y]] });
        nextQ = p1;
        break;
      }
      case "A": {
        for (let k = 0; k < 5; k++) n();
        x = ox + n(); y = oy + n();
        if (!arcWarned) warn("arcs are imported as straight lines");
        arcWarned = true;
        out.push({ cmd: "L", pts: [[x, y]] });
        break;
      }
      case "Z": x = sx; y = sy; out.push({ cmd: "Z", pts: [] }); cmd = ""; break;
      default: throw new SvgImportError(`path command ${cmd} isn't SVG`);
    }
    lastC = nextC;
    lastQ = nextQ;
  }
  return out;
}

const bboxOf = (pts: [number, number][]) => {
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const x = Math.min(...xs), y = Math.min(...ys);
  return { x, y, w: Math.max(1, Math.max(...xs) - x), h: Math.max(1, Math.max(...ys) - y) };
};

/**
 * The SVG's drawable elements as one group of design nodes at (x, y) on the
 * page, in paint order. ids mints node ids.
 */
export function importSvg(src: string, opts: { ids: () => string; x?: number; y?: number; name?: string }): { node: GroupNode; warnings: string[] } {
  const svg = parseSvg(src);
  const warnings: string[] = [];
  const warnOnce = new Set<string>();
  const warn = (s: string) => {
    if (!warnOnce.has(s)) warnings.push(s);
    warnOnce.add(s);
  };
  const vb = nums(svg.attrs.viewBox ?? "");
  const origin: [number, number] = vb.length === 4 ? [-vb[0], -vb[1]] : [0, 0];
  const out: DesignNode[] = [];
  let count = 0;

  const styled = (s: Style) => {
    const op = num(s.opacity, 1);
    const fill = colorOf(s.fill ?? "black", num(s["fill-opacity"], 1) * op, warn);
    const stroke = colorOf(s.stroke, num(s["stroke-opacity"], 1) * op, warn);
    const sw = num(s["stroke-width"], 1);
    return {
      ...(fill ? { fill } : {}),
      ...(stroke ? { stroke, stroke_width: r2(Math.max(0, Math.min(sw, 1000))) } : {}),
      ...(stroke && s["stroke-dasharray"] && s["stroke-dasharray"] !== "none" ? { dash: "dash" as const } : {}),
    };
  };
  const pathNode = (pts: { cmd: string; pts: [number, number][] }[], s: Style, name: string, t: [number, number]): PathNode | undefined => {
    const all = pts.flatMap((p) => p.pts).map(([px, py]) => [px + t[0], py + t[1]] as [number, number]);
    if (all.length < 2) return undefined;
    const b = bboxOf(all);
    let k = 0;
    const d = pts
      .map((p) => p.cmd + p.pts.map(() => {
        const [px, py] = all[k++];
        return `${r2(px - b.x)} ${r2(py - b.y)}`;
      }).join(" "))
      .join(" ");
    const cap = s["stroke-linecap"], join = s["stroke-linejoin"];
    return {
      id: opts.ids(), type: "path", name, x: r2(b.x), y: r2(b.y), w: r2(b.w), h: r2(b.h), d, ...styled(s),
      ...(cap === "round" || cap === "square" ? { cap } : {}), ...(join === "round" || join === "bevel" ? { join } : {}),
    } as PathNode;
  };

  const visit = (el: El, inherited: Style, t: [number, number]) => {
    if (++count > MAX_SVG_NODES) throw new SvgImportError(`the SVG has more than ${MAX_SVG_NODES} elements`);
    const s = styleOf(el, inherited);
    if (el.attrs.transform) {
      const m = el.attrs.transform.trim().match(/^translate\(\s*(-?[\d.e]+)(?:[\s,]+(-?[\d.e]+))?\s*\)$/);
      if (!m) {
        warn(`<${el.name}> with transform "${el.attrs.transform.slice(0, 40)}" is skipped (only translate is imported)`);
        return;
      }
      t = [t[0] + +m[1], t[1] + num(m[2], 0)];
    }
    if (s.display === "none" || s.visibility === "hidden") return;
    const a = el.attrs;
    const add = (n: DesignNode | undefined) => n && out.push(n);
    switch (el.name) {
      case "svg":
      case "g":
      case "a":
        for (const c of el.children) visit(c, s, t);
        return;
      case "title":
      case "desc":
      case "metadata":
        return;
      case "rect": {
        const w = num(a.width), h = num(a.height);
        if (!(w > 0 && h > 0)) return;
        const rx = num(a.rx, num(a.ry));
        add({ id: opts.ids(), type: "shape", shape: rx > 0 ? "roundRect" : "rect", name: a.id ?? "Rectangle", x: r2(num(a.x) + t[0]), y: r2(num(a.y) + t[1]), w: r2(w), h: r2(h), ...(rx > 0 ? { radius: r2(Math.min(rx, w / 2, h / 2)) } : {}), ...styled(s) } as ShapeNode);
        return;
      }
      case "circle":
      case "ellipse": {
        const rx = el.name === "circle" ? num(a.r) : num(a.rx), ry = el.name === "circle" ? num(a.r) : num(a.ry);
        if (!(rx > 0 && ry > 0)) return;
        add({ id: opts.ids(), type: "shape", shape: "ellipse", name: a.id ?? "Ellipse", x: r2(num(a.cx) - rx + t[0]), y: r2(num(a.cy) - ry + t[1]), w: r2(2 * rx), h: r2(2 * ry), ...styled(s) } as ShapeNode);
        return;
      }
      case "line":
        add(pathNode([{ cmd: "M", pts: [[num(a.x1), num(a.y1)]] }, { cmd: "L", pts: [[num(a.x2), num(a.y2)]] }], { ...s, fill: "none" }, a.id ?? "Line", t));
        return;
      case "polyline":
      case "polygon": {
        const v = nums(a.points ?? "");
        const pts: { cmd: string; pts: [number, number][] }[] = [];
        for (let k = 0; k + 1 < v.length; k += 2) pts.push({ cmd: k ? "L" : "M", pts: [[v[k], v[k + 1]]] });
        if (el.name === "polygon") pts.push({ cmd: "Z", pts: [] });
        add(pathNode(pts, el.name === "polyline" ? { ...s, fill: s.fill ?? "none" } : s, a.id ?? (el.name === "polygon" ? "Polygon" : "Polyline"), t));
        return;
      }
      case "path":
        if (a.d) add(pathNode(absPath(a.d, warn), s, a.id ?? "Path", t));
        return;
      case "text": {
        const text = (el.text + el.children.map((c) => c.text).join("")).replace(/\s+/g, " ").trim();
        if (!text) return;
        if (el.attrs["text-anchor"] && el.attrs["text-anchor"] !== "start") warn("text-anchor is imported as start");
        const size = Math.max(1, Math.min(num(s["font-size"], 16), 400));
        const wt = s["font-weight"] === "bold" ? 700 : Math.round(num(s["font-weight"], 400) / 100) * 100;
        const weight = ([400, 500, 600, 700] as const).reduce((b, c) => (Math.abs(c - wt) < Math.abs(b - wt) ? c : b), 400 as 400 | 500 | 600 | 700);
        const color = colorOf(s.fill ?? "black", num(s["fill-opacity"], 1) * num(s.opacity, 1), warn) ?? undefined;
        const x0 = num(a.x ?? el.children[0]?.attrs.x), y0 = num(a.y ?? el.children[0]?.attrs.y);
        // SVG's y is the baseline; a text node's box starts at the line's top.
        add({
          id: opts.ids(), type: "text", name: text.slice(0, 40), x: r2(x0 + t[0]), y: r2(y0 - size * 0.97 + t[1]), w: 1, h: r2(size * 1.2), sizing: { w: "hug", h: "hug" },
          paragraphs: [{ runs: [{ text: text.slice(0, 5000), size: r2(size), ...(weight !== 400 ? { weight } : {}), ...(color ? { color } : {}) }] }],
        } as TextNode);
        return;
      }
      default:
        warn(`<${el.name}> isn't imported`);
    }
  };
  visit(svg, {}, origin);
  if (!out.length) throw new SvgImportError("the SVG has nothing that can be imported (rect, circle, ellipse, line, polyline, polygon, path or text)");
  // The group's box is its children's; children are relative to it.
  const x0 = Math.min(...out.map((n) => (n.type === "connector" ? 0 : n.x))), y0 = Math.min(...out.map((n) => (n.type === "connector" ? 0 : n.y)));
  const x1 = Math.max(...out.map((n) => (n.type === "connector" ? 0 : n.x + n.w))), y1 = Math.max(...out.map((n) => (n.type === "connector" ? 0 : n.y + n.h)));
  const children = out.map((n) => (n.type === "connector" ? n : ({ ...n, x: r2(n.x - x0), y: r2(n.y - y0) } as DesignNode)));
  const node: GroupNode = { id: opts.ids(), type: "group", name: opts.name ?? "Imported SVG", x: r2(opts.x ?? 0), y: r2(opts.y ?? 0), w: r2(Math.max(1, x1 - x0)), h: r2(Math.max(1, y1 - y0)), children };
  return { node, warnings };
}
