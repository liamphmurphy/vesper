/**
 * Preset shape geometry. One function turns (shape, frame) into a closed
 * outline and the rectangle text sits in; the editor, presentation, thumbnails
 * and PDF all draw from it, and the PPTX export writes the shape's name as a
 * native prstGeom. The formulas follow PowerPoint's presetShapeDefinitions.xml
 * with its default adjust values, so a PPTX opened in PowerPoint or
 * LibreOffice draws the same outline and wraps text in the same box.
 *
 * Self-contained (type-only imports) so node's test runner can load it.
 */
import type { Frame, ShapeKind } from "./schema.ts";

/** One path segment, in slide units. Arcs are already cubic Béziers. */
export type Seg = ["M", number, number] | ["L", number, number] | ["C", number, number, number, number, number, number] | ["Z"];
export type Geometry = { segs: Seg[]; text: Frame };

export type ShapeCategory = "Basics" | "Arrows & flow" | "Callouts" | "Accents";
export const SHAPES: { id: ShapeKind; label: string; category: ShapeCategory }[] = [
  { id: "rect", label: "Rectangle", category: "Basics" },
  { id: "roundRect", label: "Rounded rectangle", category: "Basics" },
  { id: "ellipse", label: "Ellipse", category: "Basics" },
  { id: "triangle", label: "Triangle", category: "Basics" },
  { id: "rtTriangle", label: "Right triangle", category: "Basics" },
  { id: "diamond", label: "Diamond", category: "Basics" },
  { id: "pentagon", label: "Pentagon", category: "Basics" },
  { id: "hexagon", label: "Hexagon", category: "Basics" },
  { id: "octagon", label: "Octagon", category: "Basics" },
  { id: "rightArrow", label: "Right arrow", category: "Arrows & flow" },
  { id: "leftArrow", label: "Left arrow", category: "Arrows & flow" },
  { id: "upArrow", label: "Up arrow", category: "Arrows & flow" },
  { id: "downArrow", label: "Down arrow", category: "Arrows & flow" },
  { id: "chevron", label: "Chevron", category: "Arrows & flow" },
  { id: "homePlate", label: "Pentagon arrow", category: "Arrows & flow" },
  { id: "wedgeRectCallout", label: "Rectangle callout", category: "Callouts" },
  { id: "wedgeRoundRectCallout", label: "Rounded callout", category: "Callouts" },
  { id: "star5", label: "Star", category: "Accents" },
  { id: "plus", label: "Plus", category: "Accents" },
  { id: "donut", label: "Donut", category: "Accents" },
  { id: "heart", label: "Heart", category: "Accents" },
];
export const SHAPE_CATEGORIES: ShapeCategory[] = ["Basics", "Arrows & flow", "Callouts", "Accents"];

/** The v1 shapes keep their own draw ops and full-frame text box, so v1 decks render unchanged. */
export const isPreset = (s: ShapeKind) => s !== "rect" && s !== "roundRect" && s !== "ellipse";

const KAPPA = 0.5522847498; // cubic Bézier handle for a quarter ellipse
const DEG = Math.PI / 180;
const pos = (v: number, a: number, b: number) => (v > 0 ? a : b); // the spec's "?:" operator
const pin = (lo: number, v: number, hi: number) => Math.max(lo, Math.min(v, hi));

/** A closed polygon. */
function poly(pts: [number, number][]): Seg[] {
  return [["M", ...pts[0]], ...pts.slice(1).map(([x, y]): Seg => ["L", x, y]), ["Z"]];
}

/** A quarter-ellipse corner from the current point (x0, y0) to (x1, y1), bulging towards (cx, cy). */
function corner(x0: number, y0: number, cx: number, cy: number, x1: number, y1: number): Seg {
  return ["C", x0 + KAPPA * (cx - x0), y0 + KAPPA * (cy - y0), x1 + KAPPA * (cx - x1), y1 + KAPPA * (cy - y1), x1, y1];
}

/** A whole ellipse; reverse winds it the other way, for a hole under the nonzero rule. */
function ellipse(cx: number, cy: number, rx: number, ry: number, reverse = false): Seg[] {
  const pts: [number, number][] = reverse
    ? [[cx + rx, cy], [cx, cy - ry], [cx - rx, cy], [cx, cy + ry], [cx + rx, cy]]
    : [[cx + rx, cy], [cx, cy + ry], [cx - rx, cy], [cx, cy - ry], [cx + rx, cy]];
  const segs: Seg[] = [["M", ...pts[0]]];
  for (let i = 0; i < 4; i++) {
    const [x0, y0] = pts[i], [x1, y1] = pts[i + 1];
    // The corner of the bounding box this quarter bulges towards.
    const c = x0 === cx ? [x1, y0] : [x0, y1];
    segs.push(corner(x0, y0, c[0], c[1], x1, y1));
  }
  segs.push(["Z"]);
  return segs;
}

/** Callout tail: the point and the edge it leaves from (wedgeRectCallout / wedgeRoundRectCallout). */
function wedge(w: number, h: number, adj1 = -20833, adj2 = 62500) {
  const dxPos = (w * adj1) / 100000, dyPos = (h * adj2) / 100000;
  const xPos = w / 2 + dxPos, yPos = h / 2 + dyPos;
  const dq = (dxPos * h) / w;
  const dz = Math.abs(dyPos) - Math.abs(dq);
  const x1 = (w * pos(dxPos, 7, 2)) / 12, x2 = (w * pos(dxPos, 10, 5)) / 12;
  const y1 = (h * pos(dyPos, 7, 2)) / 12, y2 = (h * pos(dyPos, 10, 5)) / 12;
  return {
    x1, x2, y1, y2,
    xl: pos(dz, 0, pos(dxPos, 0, xPos)), yl: pos(dz, y1, pos(dxPos, y1, yPos)),
    xt: pos(dz, pos(dyPos, x1, xPos), x1), yt: pos(dz, pos(dyPos, 0, yPos), 0),
    xr: pos(dz, w, pos(dxPos, xPos, w)), yr: pos(dz, y1, pos(dxPos, yPos, y1)),
    xb: pos(dz, pos(dyPos, xPos, x1), x1), yb: pos(dz, pos(dyPos, yPos, h), h),
  };
}

/** The outline in frame-local units (origin top-left) and the text rectangle. */
function local(shape: ShapeKind, w: number, h: number, radius: number): { segs: Seg[]; text: [number, number, number, number] } {
  const ss = Math.min(w, h), hc = w / 2, vc = h / 2, full: [number, number, number, number] = [0, 0, w, h];
  switch (shape) {
    case "rect":
      return { segs: poly([[0, 0], [w, 0], [w, h], [0, h]]), text: full };
    case "roundRect": {
      const r = Math.min(radius, w / 2, h / 2);
      return {
        segs: [["M", r, 0], ["L", w - r, 0], corner(w - r, 0, w, 0, w, r), ["L", w, h - r], corner(w, h - r, w, h, w - r, h), ["L", r, h], corner(r, h, 0, h, 0, h - r), ["L", 0, r], corner(0, r, 0, 0, r, 0), ["Z"]],
        text: full,
      };
    }
    case "ellipse":
      return { segs: ellipse(hc, vc, hc, vc), text: full };
    case "triangle":
      return { segs: poly([[hc, 0], [w, h], [0, h]]), text: [w / 4, vc, (3 * w) / 4, h] };
    case "rtTriangle":
      return { segs: poly([[0, h], [0, 0], [w, h]]), text: [w / 12, (7 * h) / 12, (7 * w) / 12, (11 * h) / 12] };
    case "diamond":
      return { segs: poly([[0, vc], [hc, 0], [w, vc], [hc, h]]), text: [w / 4, h / 4, (3 * w) / 4, (3 * h) / 4] };
    case "pentagon": {
      const swd2 = (hc * 105146) / 100000, shd2 = (vc * 110557) / 100000, svc = (vc * 110557) / 100000;
      const dx1 = swd2 * Math.cos(18 * DEG), dx2 = swd2 * Math.cos(54 * DEG);
      const y1 = svc - shd2 * Math.sin(18 * DEG), y2 = svc + shd2 * Math.sin(54 * DEG);
      const it = (y1 * dx2) / dx1;
      return { segs: poly([[hc - dx1, y1], [hc, 0], [hc + dx1, y1], [hc + dx2, y2], [hc - dx2, y2]]), text: [hc - dx2, it, hc + dx2, y2] };
    }
    case "hexagon": {
      const maxAdj = (50000 * w) / ss, a = pin(0, 25000, maxAdj);
      const shd2 = (vc * 115470) / 100000, x1 = (ss * a) / 100000, dy1 = shd2 * Math.sin(60 * DEG);
      const q1 = -maxAdj / 2, q2 = a + q1, q3 = pos(q2, 4, 2), q4 = pos(q2, 3, 2), q5 = pos(q2, q1, 0);
      const q8 = q3 - ((a + q5) / q1) * q4;
      const il = (w * q8) / 24, it = (h * q8) / 24;
      return { segs: poly([[0, vc], [x1, vc - dy1], [w - x1, vc - dy1], [w, vc], [w - x1, vc + dy1], [x1, vc + dy1]]), text: [il, it, w - il, h - it] };
    }
    case "octagon": {
      const x1 = (ss * 29289) / 100000, il = x1 / 2;
      return { segs: poly([[0, x1], [x1, 0], [w - x1, 0], [w, x1], [w, h - x1], [w - x1, h], [x1, h], [0, h - x1]]), text: [il, il, w - il, h - il] };
    }
    case "rightArrow": {
      const a2 = pin(0, 50000, (100000 * w) / ss), dx1 = (ss * a2) / 100000, x1 = w - dx1;
      const dy1 = h / 4, y1 = vc - dy1, y2 = vc + dy1, x2 = x1 + (y1 * dx1) / vc;
      return { segs: poly([[0, y1], [x1, y1], [x1, 0], [w, vc], [x1, h], [x1, y2], [0, y2]]), text: [0, y1, x2, y2] };
    }
    case "leftArrow": {
      const a2 = pin(0, 50000, (100000 * w) / ss), dx2 = (ss * a2) / 100000, x2 = dx2;
      const dy1 = h / 4, y1 = vc - dy1, y2 = vc + dy1, x1 = x2 - (y1 * dx2) / vc;
      return { segs: poly([[0, vc], [x2, 0], [x2, y1], [w, y1], [w, y2], [x2, y2], [x2, h]]), text: [x1, y1, w, y2] };
    }
    case "upArrow": {
      const a2 = pin(0, 50000, (100000 * h) / ss), dy2 = (ss * a2) / 100000, y2 = dy2;
      const dx1 = w / 4, x1 = hc - dx1, x2 = hc + dx1, y1 = y2 - (x1 * dy2) / hc;
      return { segs: poly([[0, y2], [hc, 0], [w, y2], [x2, y2], [x2, h], [x1, h], [x1, y2]]), text: [x1, y1, x2, h] };
    }
    case "downArrow": {
      const a2 = pin(0, 50000, (100000 * h) / ss), dy1 = (ss * a2) / 100000, y1 = h - dy1;
      const dx1 = w / 4, x1 = hc - dx1, x2 = hc + dx1, y2 = y1 + (x1 * dy1) / hc;
      return { segs: poly([[0, y1], [x1, y1], [x1, 0], [x2, 0], [x2, y1], [w, y1], [hc, h]]), text: [x1, 0, x2, y2] };
    }
    case "chevron": {
      const a = pin(0, 50000, (100000 * w) / ss), x1 = (ss * a) / 100000, x2 = w - x1, dx = x2 - x1;
      return { segs: poly([[0, 0], [x2, 0], [w, vc], [x2, h], [0, h], [x1, vc]]), text: [pos(dx, x1, 0), 0, pos(dx, x2, w), h] };
    }
    case "homePlate": {
      const a = pin(0, 50000, (100000 * w) / ss), x1 = w - (ss * a) / 100000;
      return { segs: poly([[0, 0], [x1, 0], [w, vc], [x1, h], [0, h]]), text: [0, 0, (x1 + w) / 2, h] };
    }
    case "wedgeRectCallout": {
      const t = wedge(w, h);
      return {
        segs: poly([[0, 0], [t.x1, 0], [t.xt, t.yt], [t.x2, 0], [w, 0], [w, t.y1], [t.xr, t.yr], [w, t.y2], [w, h], [t.x2, h], [t.xb, t.yb], [t.x1, h], [0, h], [0, t.y2], [t.xl, t.yl], [0, t.y1]]),
        text: full,
      };
    }
    case "wedgeRoundRectCallout": {
      const t = wedge(w, h), u1 = (ss * 16667) / 100000, u2 = w - u1, v2 = h - u1, il = (u1 * 29289) / 100000;
      return {
        segs: [
          ["M", 0, u1], corner(0, u1, 0, 0, u1, 0),
          ["L", t.x1, 0], ["L", t.xt, t.yt], ["L", t.x2, 0], ["L", u2, 0], corner(u2, 0, w, 0, w, u1),
          ["L", w, t.y1], ["L", t.xr, t.yr], ["L", w, t.y2], ["L", w, v2], corner(w, v2, w, h, u2, h),
          ["L", t.x2, h], ["L", t.xb, t.yb], ["L", t.x1, h], ["L", u1, h], corner(u1, h, 0, h, 0, v2),
          ["L", 0, t.y2], ["L", t.xl, t.yl], ["L", 0, t.y1], ["Z"],
        ],
        text: [il, il, w - il, h - il],
      };
    }
    case "star5": {
      const a = 19098, swd2 = (hc * 105146) / 100000, shd2 = (vc * 110557) / 100000, svc = (vc * 110557) / 100000;
      const dx1 = swd2 * Math.cos(18 * DEG), dx2 = swd2 * Math.cos(54 * DEG);
      const y1 = svc - shd2 * Math.sin(18 * DEG), y2 = svc + shd2 * Math.sin(54 * DEG);
      const iwd2 = (swd2 * a) / 50000, ihd2 = (shd2 * a) / 50000;
      const sdx1 = iwd2 * Math.cos(18 * DEG), sdx2 = iwd2 * Math.cos(54 * DEG);
      const sy1 = svc - ihd2 * Math.sin(54 * DEG), sy2 = svc + ihd2 * Math.sin(18 * DEG), sy3 = svc + ihd2;
      return {
        segs: poly([[hc - dx1, y1], [hc - sdx2, sy1], [hc, 0], [hc + sdx2, sy1], [hc + dx1, y1], [hc + sdx1, sy2], [hc + dx2, y2], [hc, sy3], [hc - dx2, y2], [hc - sdx1, sy2]]),
        text: [hc - sdx1, sy1, hc + sdx1, sy3],
      };
    }
    case "plus": {
      const x1 = ss / 4, x2 = w - x1, y2 = h - x1, d = w - h;
      return {
        segs: poly([[0, x1], [x1, x1], [x1, 0], [x2, 0], [x2, x1], [w, x1], [w, y2], [x2, y2], [x2, h], [x1, h], [x1, y2], [0, y2]]),
        text: [pos(d, 0, x1), pos(d, x1, 0), pos(d, w, x2), pos(d, y2, h)],
      };
    }
    case "donut": {
      const dr = ss / 4, idx = hc * Math.cos(45 * DEG), idy = vc * Math.sin(45 * DEG);
      return { segs: [...ellipse(hc, vc, hc, vc), ...ellipse(hc, vc, hc - dr, vc - dr, true)], text: [hc - idx, vc - idy, hc + idx, vc + idy] };
    }
    case "heart": {
      const dx1 = (w * 49) / 48, dx2 = (w * 10) / 48, y1 = -h / 3, hd4 = h / 4;
      return {
        segs: [["M", hc, hd4], ["C", hc + dx2, y1, hc + dx1, hd4, hc, h], ["C", hc - dx1, hd4, hc - dx2, y1, hc, hd4], ["Z"]],
        text: [w / 6, hd4, (5 * w) / 6, (2 * h) / 3],
      };
    }
  }
}

/** A shape's outline and text rectangle within its frame, in slide units. */
export function shapeGeometry(shape: ShapeKind, f: Frame, radius = 24): Geometry {
  const g = local(shape, f.w, f.h, radius);
  const segs = g.segs.map((s): Seg => {
    if (s[0] === "Z") return s;
    if (s[0] === "C") return ["C", s[1] + f.x, s[2] + f.y, s[3] + f.x, s[4] + f.y, s[5] + f.x, s[6] + f.y];
    return [s[0], s[1] + f.x, s[2] + f.y];
  });
  const [l, t, r, b] = g.text;
  return { segs, text: { x: f.x + l, y: f.y + t, w: r - l, h: b - t } };
}

const n = (v: number) => +v.toFixed(2);

/** SVG path data for an outline. */
export function svgPath(segs: Seg[]): string {
  return segs.map((s) => s[0] + s.slice(1).map((v) => n(v as number)).join(" ")).join("");
}
