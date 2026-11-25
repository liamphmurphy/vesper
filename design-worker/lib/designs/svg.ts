// Display list -> one SVG string (ADR-designs §3.8). The same drawing as
// <DesignSvg> in render.tsx: kerning off, one <text> per measured piece,
// images as data URIs. Pure (no DOM), so the design worker (resvg) and the
// SVG export share it.
import { FAMILY } from "./measure.ts";
import type { Box, Op, ResolvedPaint } from "./layout.ts";

export type SvgOptions = {
  /** The region drawn: becomes the viewBox. */
  box: Box;
  /** Page colour, drawn over the whole box first. */
  background?: string;
  /** Asset id -> data URI; an image whose asset is missing is drawn empty. */
  assets?: Record<string, string>;
  /** Output pixels per design px (width/height attributes); default 1. */
  scale?: number;
  /** Extra CSS, e.g. @font-face rules for a browser. */
  css?: string;
  /** Prefix for ids, so several SVGs can share one document. */
  uid?: string;
};

const esc = (s: unknown) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const num = (n: number) => String(Math.round(n * 1000) / 1000);
const alpha = (hex: string) => num(parseInt(hex.slice(7), 16) / 255);

function fill(p: ResolvedPaint | undefined, id: string, defs: string[]): string {
  if (!p) return 'fill="none"';
  if (typeof p === "string") return p.length === 9 ? `fill="${esc(p.slice(0, 7))}" fill-opacity="${alpha(p)}"` : `fill="${esc(p)}"`;
  const a = (p.angle * Math.PI) / 180;
  defs.push(
    `<linearGradient id="${id}" x1="${0.5 - Math.cos(a) / 2}" y1="${0.5 - Math.sin(a) / 2}" x2="${0.5 + Math.cos(a) / 2}" y2="${0.5 + Math.sin(a) / 2}"><stop offset="0" stop-color="${esc(p.stops[0])}"/><stop offset="1" stop-color="${esc(p.stops[1])}"/></linearGradient>`,
  );
  return `fill="url(#${id})"`;
}

function stroke(o: { stroke?: string; sw: number; dash?: string; cap?: string; join?: string }): string {
  if (!o.stroke || !o.sw) return "";
  const s = o.stroke.length === 9 ? `stroke="${esc(o.stroke.slice(0, 7))}" stroke-opacity="${alpha(o.stroke)}"` : `stroke="${esc(o.stroke)}"`;
  return ` ${s} stroke-width="${num(o.sw)}"${o.dash ? ` stroke-dasharray="${esc(o.dash)}"` : ""}${o.cap ? ` stroke-linecap="${esc(o.cap)}"` : ""}${o.join ? ` stroke-linejoin="${esc(o.join)}"` : ""}`;
}

/** The ops as SVG markup (no <svg> wrapper) plus the defs they need. */
export function opsToSvg(ops: Op[], assets: Record<string, string> = {}, uid = ""): { defs: string; body: string } {
  const defs: string[] = [];
  const body: string[] = [];
  const open: ("g")[] = [];
  ops.forEach((o, i) => {
    const gid = `${uid}g${i}`;
    const cid = `${uid}c${i}`;
    const opacity = "opacity" in o && o.opacity !== undefined && o.opacity < 1 ? ` opacity="${num(o.opacity)}"` : "";
    switch (o.op) {
      case "rect":
        body.push(`<rect x="${num(o.x)}" y="${num(o.y)}" width="${num(Math.max(0, o.w))}" height="${num(Math.max(0, o.h))}"${o.r ? ` rx="${num(o.r)}"` : ""} ${fill(o.fill, gid, defs)}${stroke(o)}${opacity}/>`);
        break;
      case "ellipse":
        body.push(`<ellipse cx="${num(o.x + o.w / 2)}" cy="${num(o.y + o.h / 2)}" rx="${num(Math.max(0, o.w / 2))}" ry="${num(Math.max(0, o.h / 2))}" ${fill(o.fill, gid, defs)}${stroke(o)}${opacity}/>`);
        break;
      case "path":
        body.push(`<path d="${esc(o.d)}" ${fill(o.fill, gid, defs)}${stroke(o)}${opacity}/>`);
        break;
      case "polyline":
        body.push(`<polyline points="${o.points.map((p) => p.join(",")).join(" ")}" fill="none"${stroke(o)}${opacity}/>`);
        break;
      case "image": {
        const sx = o.w / o.src.w, sy = o.h / o.src.h;
        defs.push(`<clipPath id="${cid}"><rect x="${num(o.x)}" y="${num(o.y)}" width="${num(o.w)}" height="${num(o.h)}"${o.r ? ` rx="${num(o.r)}"` : ""}/></clipPath>`);
        body.push(
          `<g${opacity}><g clip-path="url(#${cid})"><image href="${esc(assets[o.asset] ?? "")}" x="${num(o.x - o.src.x * sx)}" y="${num(o.y - o.src.y * sy)}" width="${num(o.iw * sx)}" height="${num(o.ih * sy)}" preserveAspectRatio="none"><title>${esc(o.alt)}</title></image></g></g>`,
        );
        break;
      }
      case "text":
        body.push(`<text x="${num(o.x)}" y="${num(o.y)}" font-family="${esc(`"${FAMILY}", Inter, sans-serif`)}" font-size="${num(o.size)}" font-weight="${o.weight}"${o.italic ? ' font-style="italic"' : ""} ${fill(o.fill, gid, defs)}${opacity} xml:space="preserve">${esc(o.text)}</text>`);
        break;
      case "clip":
        defs.push(`<clipPath id="${cid}"><rect x="${num(o.x)}" y="${num(o.y)}" width="${num(o.w)}" height="${num(o.h)}"${o.r ? ` rx="${num(o.r)}"` : ""}/></clipPath>`);
        body.push(`<g clip-path="url(#${cid})">`);
        open.push("g");
        break;
      case "rotate":
        body.push(`<g transform="rotate(${num(o.deg)} ${num(o.cx)} ${num(o.cy)})">`);
        open.push("g");
        break;
      case "unclip":
      case "unrotate":
        if (open.pop()) body.push("</g>");
        break;
    }
  });
  while (open.pop()) body.push("</g>");
  return { defs: defs.join(""), body: body.join("") };
}

const TEXT_CSS = 'text{font-kerning:none;font-feature-settings:"kern" 0;text-rendering:geometricPrecision}';

/** One SVG document for the ops, framed on opts.box. */
export function toSvg(ops: Op[], opts: SvgOptions): string {
  const { box } = opts;
  const w = Math.max(1, box.w), h = Math.max(1, box.h);
  const s = opts.scale ?? 1;
  const { defs, body } = opsToSvg(ops, opts.assets, opts.uid);
  const bg = opts.background ? `<rect x="${num(box.x)}" y="${num(box.y)}" width="${num(w)}" height="${num(h)}" fill="${esc(opts.background)}"/>` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${num(box.x)} ${num(box.y)} ${num(w)} ${num(h)}" width="${num(w * s)}" height="${num(h * s)}"><style>${TEXT_CSS}${opts.css ?? ""}</style><defs>${defs}</defs>${bg}${body}</svg>`;
}
