// Orthogonal connector routing (ADR-designs §3.8, LAZYAGENTS-152). Pure, so
// the editor, the design worker and node's test runner share it.
//
// A connector leaves its source anchor with a short stub, travels along a
// sparse grid built from the obstacles' (inflated) edges, and enters its
// target anchor with a stub, so the arrowhead always sits on a straight end
// segment clear of other nodes. A* picks the path with the least length plus
// a penalty per bend. Stored `points` (an import's ELK route) are a cache:
// they're used only while both ends still touch their nodes and no segment
// crosses an obstacle, so moving an attached node re-routes the connector.

export type Box = { x: number; y: number; w: number; h: number };
export type Pt = [number, number];
export type Anchor = "top" | "right" | "bottom" | "left";
/** The outline a connector end is clipped to; anything else is its box. */
export type Outline = "box" | "diamond" | "ellipse";

/** Preferred straight segment length at each end; shortened in narrow gaps. */
export const STUB = 20;
/** Clearance kept around obstacles. */
export const CLEARANCE = 14;
/** Cost of one bend, in pixels of length. */
export const BEND = 36;
/** How far beyond the two ends' boxes a route may wander to get round obstacles. */
const REACH = 240;
/** Above this many obstacles in reach, fall back to the simple route (keeps a frame of dragging cheap). */
const MAX_OBSTACLES = 300;

const DIRS: Record<Anchor, Pt> = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };

export const anchorPoint = (b: Box, a: Anchor): Pt =>
  ({ top: [b.x + b.w / 2, b.y], bottom: [b.x + b.w / 2, b.y + b.h], left: [b.x, b.y + b.h / 2], right: [b.x + b.w, b.y + b.h / 2] })[a] as Pt;

/** The side of `from` that faces `to`. */
export function autoAnchor(from: Box, to: Box): Anchor {
  const dx = to.x + to.w / 2 - (from.x + from.w / 2);
  const dy = to.y + to.h / 2 - (from.y + from.h / 2);
  return Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : dy > 0 ? "bottom" : "top";
}

const inflate = (b: Box, m: number): Box => ({ x: b.x - m, y: b.y - m, w: b.w + 2 * m, h: b.h + 2 * m });
const overlaps = (a: Box, b: Box) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
const strictlyInside = (p: Pt, b: Box) => p[0] > b.x && p[0] < b.x + b.w && p[1] > b.y && p[1] < b.y + b.h;

/** Whether an axis-aligned (or any) segment passes through a box's interior. */
export function segmentHits(a: Pt, b: Pt, box: Box): boolean {
  const x0 = Math.min(a[0], b[0]), x1 = Math.max(a[0], b[0]);
  const y0 = Math.min(a[1], b[1]), y1 = Math.max(a[1], b[1]);
  const e = 0.01;
  if (x1 <= box.x + e || x0 >= box.x + box.w - e || y1 <= box.y + e || y0 >= box.y + box.h - e) return false;
  if (a[0] === b[0] || a[1] === b[1]) return true;
  // A diagonal (a straight connector): sample, which is plenty for a validity check.
  for (let i = 0; i <= 32; i++) {
    const t = i / 32;
    if (strictlyInside([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t], box)) return true;
  }
  return false;
}

/** Drops repeated points and the middle of three collinear ones. */
export function simplify(pts: Pt[]): Pt[] {
  const out: Pt[] = [];
  for (const p of pts) {
    const last = out.at(-1);
    if (last && last[0] === p[0] && last[1] === p[1]) continue;
    if (out.length >= 2) {
      const [a, b] = [out.at(-2)!, out.at(-1)!];
      if ((a[0] === b[0] && b[0] === p[0]) || (a[1] === b[1] && b[1] === p[1])) out.pop();
    }
    out.push(p);
  }
  return out;
}

/** The stub-and-elbow route with no obstacle avoidance: the fallback. */
export function simpleRoute(fb: Box, fa: Anchor, tb: Box, ta: Anchor): Pt[] {
  const p0 = anchorPoint(fb, fa), p3 = anchorPoint(tb, ta);
  const [fdx, fdy] = DIRS[fa], [tdx, tdy] = DIRS[ta];
  const p1: Pt = [p0[0] + fdx * STUB, p0[1] + fdy * STUB];
  const p2: Pt = [p3[0] + tdx * STUB, p3[1] + tdy * STUB];
  const pts: Pt[] = [p0, p1];
  const fh = fdx !== 0, th = tdx !== 0;
  if (fh && th) pts.push([(p1[0] + p2[0]) / 2, p1[1]], [(p1[0] + p2[0]) / 2, p2[1]]);
  else if (!fh && !th) {
    const ymid = fdy === tdy ? (fdy > 0 ? Math.max(p1[1], p2[1]) : Math.min(p1[1], p2[1])) : (p1[1] + p2[1]) / 2;
    pts.push([p1[0], ymid], [p2[0], ymid]);
  } else if (fh) pts.push([p2[0], p1[1]]);
  else pts.push([p1[0], p2[1]]);
  pts.push(p2, p3);
  return simplify(pts);
}

/** A small binary min-heap of [priority, value]. */
class Heap {
  private a: [number, number][] = [];
  get size() {
    return this.a.length;
  }
  push(p: number, v: number) {
    const a = this.a;
    a.push([p, v]);
    let i = a.length - 1;
    while (i > 0) {
      const j = (i - 1) >> 1;
      if (a[j][0] <= a[i][0]) break;
      [a[i], a[j]] = [a[j], a[i]];
      i = j;
    }
  }
  pop(): [number, number] {
    const a = this.a;
    const top = a[0];
    const last = a.pop()!;
    if (a.length) {
      a[0] = last;
      let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < a.length && a[l][0] < a[m][0]) m = l;
        if (r < a.length && a[r][0] < a[m][0]) m = r;
        if (m === i) break;
        [a[i], a[m]] = [a[m], a[i]];
        i = m;
      }
    }
    return top;
  }
}

/**
 * An orthogonal route from fb's anchor to tb's anchor that keeps CLEARANCE
 * away from obstacles where space permits (reduced near crowded anchors),
 * and stays outside the two end nodes apart from the stubs. Falls back to simpleRoute when the ends overlap or no clear path
 * exists within reach.
 */
export function routeOrthogonal(fb: Box, fa: Anchor, tb: Box, ta: Anchor, obstacles: Box[] = []): Pt[] {
  const p0 = anchorPoint(fb, fa), p3 = anchorPoint(tb, ta);
  const fd = DIRS[fa], td = DIRS[ta];
  // Near an anchor, reduce clearance to leave a channel in a narrow gap.
  // Keep every unrelated obstacle: dropping one containing a nominal stub
  // would let both the stub and the grid path cross the node itself.
  const distance = (p: Pt, b: Box) => Math.max(b.x - p[0], p[0] - b.x - b.w, b.y - p[1], p[1] - b.y - b.h, 0);
  const otherBlocks = obstacles.map((o) => inflate(o, Math.min(CLEARANCE, distance(p0, o) / 2, distance(p3, o) / 2)));
  const stub = (p: Pt, d: Pt, blocks: Box[]): Pt => {
    let len = STUB;
    for (const b of blocks) {
      const horizontal = d[0] !== 0;
      const cross = horizontal ? p[1] : p[0];
      const low = horizontal ? b.y : b.x, size = horizontal ? b.h : b.w;
      if (cross <= low || cross >= low + size) continue;
      const along = horizontal ? p[0] : p[1], dir = horizontal ? d[0] : d[1];
      const near = horizontal ? b.x : b.y, extent = horizontal ? b.w : b.h;
      const gap = dir > 0 ? near - along : along - near - extent;
      if (gap >= 0) len = Math.min(len, gap / 2);
    }
    return [p[0] + d[0] * len, p[1] + d[1] * len];
  };
  const p1 = stub(p0, fd, [tb, ...otherBlocks]);
  const p2 = stub(p3, td, [fb, ...otherBlocks]);
  const reach = inflate(
    { x: Math.min(fb.x, tb.x), y: Math.min(fb.y, tb.y), w: Math.max(fb.x + fb.w, tb.x + tb.w) - Math.min(fb.x, tb.x), h: Math.max(fb.y + fb.h, tb.y + tb.h) - Math.min(fb.y, tb.y) },
    REACH,
  );
  // The ends' own boxes are obstacles too, so a route doesn't double back over its node.
  const blocks = [
    inflate(fb, Math.min(CLEARANCE, Math.abs(p1[0] - p0[0]) + Math.abs(p1[1] - p0[1]))),
    inflate(tb, Math.min(CLEARANCE, Math.abs(p2[0] - p3[0]) + Math.abs(p2[1] - p3[1]))),
    ...otherBlocks.filter((o) => overlaps(o, reach)),
  ];
  if (blocks.length > MAX_OBSTACLES) return simpleRoute(fb, fa, tb, ta);

  const xsSet = new Set<number>([p1[0], p2[0], (p1[0] + p2[0]) / 2, reach.x, reach.x + reach.w]);
  const ysSet = new Set<number>([p1[1], p2[1], (p1[1] + p2[1]) / 2, reach.y, reach.y + reach.h]);
  for (const b of blocks) {
    xsSet.add(b.x).add(b.x + b.w);
    ysSet.add(b.y).add(b.y + b.h);
  }
  const xs = [...xsSet].sort((a, b) => a - b);
  const ys = [...ysSet].sort((a, b) => a - b);
  // Channels halfway between neighbouring lines keep routes centred in gaps.
  const mids = (v: number[]) => v.slice(1).map((x, i) => (x + v[i]) / 2);
  const X = [...new Set([...xs, ...mids(xs)])].sort((a, b) => a - b);
  const Y = [...new Set([...ys, ...mids(ys)])].sort((a, b) => a - b);
  const nx = X.length, ny = Y.length;
  const xi = new Map(X.map((x, i) => [x, i])), yi = new Map(Y.map((y, i) => [y, i]));

  // blockedH[j*nx+i]: the segment (i,j)-(i+1,j) crosses an obstacle; blockedV[j*nx+i]: (i,j)-(i,j+1).
  // Grid lines include every obstacle edge, so a segment is either wholly in an obstacle's interior or out of it.
  const blockedH = new Uint8Array(nx * ny), blockedV = new Uint8Array(nx * ny);
  const lo = (v: number[], t: number) => {
    let a = 0, b = v.length;
    while (a < b) {
      const m = (a + b) >> 1;
      if (v[m] < t) a = m + 1;
      else b = m;
    }
    return a;
  };
  for (const b of blocks) {
    const i0 = lo(X, b.x), i1 = lo(X, b.x + b.w), j0 = lo(Y, b.y), j1 = lo(Y, b.y + b.h);
    for (let j = j0; j <= j1 && j < ny; j++) {
      const insideY = Y[j] > b.y && Y[j] < b.y + b.h;
      for (let i = i0; i <= i1 && i < nx; i++) {
        const insideX = X[i] > b.x && X[i] < b.x + b.w;
        if (insideY && i < i1) blockedH[j * nx + i] = 1;
        if (insideX && j < j1) blockedV[j * nx + i] = 1;
      }
    }
  }

  const s = (yi.get(p1[1])! * nx + xi.get(p1[0])!);
  const g = (yi.get(p2[1])! * nx + xi.get(p2[0])!);
  // State: node * 4 + heading (0 right, 1 down, 2 left, 3 up).
  const STEP: Pt[] = [[1, 0], [0, 1], [-1, 0], [0, -1]];
  const headingOf = (d: Pt) => STEP.findIndex((h) => h[0] === d[0] && h[1] === d[1]);
  const startH = headingOf(fd);
  const goalH = headingOf([-td[0], -td[1]] as Pt);
  const cost = new Float64Array(nx * ny * 4).fill(Infinity);
  const prev = new Int32Array(nx * ny * 4).fill(-1);
  const heur = (n: number) => Math.abs(X[n % nx] - p2[0]) + Math.abs(Y[Math.floor(n / nx)] - p2[1]);
  const heap = new Heap();
  cost[s * 4 + startH] = 0;
  heap.push(heur(s), s * 4 + startH);
  let found = -1;
  while (heap.size) {
    const [f, st] = heap.pop();
    const n = st >> 2, h = st & 3;
    if (f - heur(n) > cost[st] + 1e-9) continue;
    if (n === g) {
      found = st;
      break;
    }
    const i = n % nx, j = Math.floor(n / nx);
    for (let k = 0; k < 4; k++) {
      if (k === ((h + 2) & 3)) continue; // no U-turns
      const [dx, dy] = STEP[k];
      const ni = i + dx, nj = j + dy;
      if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
      if (dx && blockedH[j * nx + Math.min(i, ni)]) continue;
      if (dy && blockedV[Math.min(j, nj) * nx + i]) continue;
      const m = nj * nx + ni;
      let c = cost[st] + Math.abs(X[ni] - X[i]) + Math.abs(Y[nj] - Y[j]) + (k !== h ? BEND : 0);
      if (m === g && k !== goalH) c += BEND; // turning into the end stub
      const ns = m * 4 + k;
      if (c < cost[ns] - 1e-9) {
        cost[ns] = c;
        prev[ns] = st;
        heap.push(c + heur(m), ns);
      }
    }
  }
  if (found < 0) return simpleRoute(fb, fa, tb, ta);
  const path: Pt[] = [];
  for (let st = found; st >= 0; st = prev[st]) {
    const n = st >> 2;
    path.push([X[n % nx], Y[Math.floor(n / nx)]]);
  }
  path.reverse();
  return simplify([p0, ...path, p3]);
}

/**
 * Moves an end point along its (axis-aligned) end segment onto a diamond or
 * ellipse outline; ELK ends edges on the bounding box (ADR §5.5 finding 4).
 */
export function clipEnd(end: Pt, prev: Pt, b: Box, outline: Outline): Pt {
  if (outline === "box" || !(b.w > 0 && b.h > 0)) return end;
  const cx = b.x + b.w / 2, cy = b.y + b.h / 2, rx = b.w / 2, ry = b.h / 2;
  if (end[0] === prev[0]) {
    // Vertical end segment at x = end[0].
    const u = Math.min(1, Math.abs(end[0] - cx) / rx);
    const dy = outline === "diamond" ? ry * (1 - u) : ry * Math.sqrt(1 - u * u);
    return [end[0], prev[1] < cy ? cy - dy : cy + dy];
  }
  if (end[1] === prev[1]) {
    const u = Math.min(1, Math.abs(end[1] - cy) / ry);
    const dx = outline === "diamond" ? rx * (1 - u) : rx * Math.sqrt(1 - u * u);
    return [prev[0] < cx ? cx - dx : cx + dx, end[1]];
  }
  return end;
}

const onEdge = (p: Pt, b: Box, tol = 1) => {
  const inX = p[0] >= b.x - tol && p[0] <= b.x + b.w + tol, inY = p[1] >= b.y - tol && p[1] <= b.y + b.h + tol;
  return (inX && (Math.abs(p[1] - b.y) <= tol || Math.abs(p[1] - b.y - b.h) <= tol)) || (inY && (Math.abs(p[0] - b.x) <= tol || Math.abs(p[0] - b.x - b.w) <= tol));
};

/**
 * Whether stored points (absolute) still fit: the first touches the source
 * box, the last the target box, and no segment crosses an obstacle. When they
 * don't, the connector is re-routed.
 */
export function pointsStillFit(pts: Pt[], fb: Box, tb: Box, obstacles: Box[], fromAnchor?: Anchor, toAnchor?: Anchor): boolean {
  if (pts.length < 2 || !onEdge(pts[0], fb) || !onEdge(pts.at(-1)!, tb)) return false;
  const matchesAnchor = (p: Pt, b: Box, a?: Anchor) => !a || (p[0] === anchorPoint(b, a)[0] && p[1] === anchorPoint(b, a)[1]);
  if (!matchesAnchor(pts[0], fb, fromAnchor) || !matchesAnchor(pts.at(-1)!, tb, toAnchor)) return false;
  const blocks = [fb, tb, ...obstacles];
  for (let i = 1; i < pts.length; i++) for (const o of blocks) if (segmentHits(pts[i - 1], pts[i], o)) return false;
  return true;
}

/** The connector's absolute polyline: stored points while they fit, else a fresh route, with ends clipped to their outlines. */
export function connectorPath(
  ends: { from: Box; to: Box; fromAnchor?: Anchor | "auto"; toAnchor?: Anchor | "auto"; fromOutline?: Outline; toOutline?: Outline },
  opts: { straight?: boolean; points?: Pt[]; obstacles?: Box[] },
): Pt[] {
  const { from: fb, to: tb } = ends;
  const obstacles = opts.obstacles ?? [];
  const fa = !ends.fromAnchor || ends.fromAnchor === "auto" ? autoAnchor(fb, tb) : ends.fromAnchor;
  const ta = !ends.toAnchor || ends.toAnchor === "auto" ? autoAnchor(tb, fb) : ends.toAnchor;
  let pts: Pt[];
  if (opts.points && pointsStillFit(opts.points, fb, tb, obstacles, ends.fromAnchor === "auto" ? undefined : ends.fromAnchor, ends.toAnchor === "auto" ? undefined : ends.toAnchor)) pts = opts.points.map((p) => [...p] as Pt);
  else if (opts.straight) return [anchorPoint(fb, fa), anchorPoint(tb, ta)];
  else pts = routeOrthogonal(fb, fa, tb, ta, obstacles);
  if (pts.length >= 2) {
    pts[0] = clipEnd(pts[0], pts[1], fb, ends.fromOutline ?? "box");
    pts[pts.length - 1] = clipEnd(pts.at(-1)!, pts.at(-2)!, tb, ends.toOutline ?? "box");
  }
  return pts;
}
