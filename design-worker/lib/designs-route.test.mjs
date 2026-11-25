import test from "node:test";
import assert from "node:assert/strict";
import { CLEARANCE, STUB, clipEnd, connectorPath, pointsStillFit, routeOrthogonal, segmentHits } from "./designs/route.ts";
import { makeLayout } from "./designs/layout.ts";
import { normalize } from "./designs/schema.ts";

const orthogonal = (pts) => pts.slice(1).every((p, i) => p[0] === pts[i][0] || p[1] === pts[i][1]);
const crosses = (pts, box) => pts.slice(1).some((p, i) => segmentHits(pts[i], p, box));
const inflate = (b, m) => ({ x: b.x - m, y: b.y - m, w: b.w + 2 * m, h: b.h + 2 * m });

const A = { x: 0, y: 0, w: 100, h: 60 };
const B = { x: 400, y: 0, w: 100, h: 60 };

test("with nothing in the way the route is a straight run between the facing anchors", () => {
  const pts = routeOrthogonal(A, "right", B, "left", []);
  assert.deepEqual(pts, [[100, 30], [400, 30]]);
});

test("routes orthogonally around a node in the way, keeping clearance", () => {
  const wall = { x: 200, y: -80, w: 60, h: 220 };
  const pts = routeOrthogonal(A, "right", B, "left", [wall]);
  assert.ok(orthogonal(pts), JSON.stringify(pts));
  assert.deepEqual(pts[0], [100, 30]);
  assert.deepEqual(pts.at(-1), [400, 30]);
  assert.ok(!crosses(pts, inflate(wall, CLEARANCE - 0.5)), `crosses the wall: ${JSON.stringify(pts)}`);
  // The arrowhead sits on a straight end segment at least STUB long.
  const [p, q] = pts.slice(-2);
  assert.ok(Math.hypot(q[0] - p[0], q[1] - p[1]) >= STUB);
});

test("finds a way through a gap between obstacles rather than around everything", () => {
  const top = { x: 200, y: -300, w: 60, h: 300 }; // ends at y=0
  const bottom = { x: 200, y: 90, w: 60, h: 300 }; // starts at y=90, leaving a 90 px gap
  const pts = routeOrthogonal(A, "right", B, "left", [top, bottom]);
  assert.ok(!crosses(pts, top) && !crosses(pts, bottom), JSON.stringify(pts));
  const ys = pts.map((p) => p[1]);
  assert.ok(Math.min(...ys) > -100 && Math.max(...ys) < 200, `went the long way: ${JSON.stringify(pts)}`);
});

test("a route doesn't cut back through its own end nodes", () => {
  // Target is behind the source: leaving right, arriving at the target's right side.
  const T = { x: -300, y: 200, w: 100, h: 60 };
  const pts = routeOrthogonal(A, "right", T, "right", []);
  assert.ok(orthogonal(pts));
  assert.ok(!crosses(pts.slice(1), A), JSON.stringify(pts));
  assert.ok(!crosses(pts.slice(0, -1), T), JSON.stringify(pts));
});

test("stored points are kept while they fit and dropped when an end moves", () => {
  const stored = [[100, 30], [250, 30], [250, 20], [400, 20]];
  assert.ok(pointsStillFit(stored, A, B, []));
  const moved = { ...B, y: 300 };
  assert.ok(!pointsStillFit(stored, A, moved, []));
  const pts = connectorPath({ from: A, to: moved }, { points: stored });
  assert.deepEqual(pts.at(-1), [400, 330], "re-routed to the moved node's facing (left) anchor");
  // An obstacle dropped across the stored route also re-routes it.
  assert.ok(!pointsStillFit(stored, A, B, [{ x: 220, y: 0, w: 40, h: 60 }]));
});

test("end points are clipped onto diamond and ellipse outlines", () => {
  const d = { x: 0, y: 0, w: 100, h: 60 };
  // Entering from above at the centre: the diamond's top vertex.
  assert.deepEqual(clipEnd([50, 0], [50, -40], d, "diamond"), [50, 0]);
  // Entering from above a quarter of the way in: half way down the diamond's upper edge.
  assert.deepEqual(clipEnd([25, 0], [25, -40], d, "diamond"), [25, 15]);
  // From the left at the centre line: the ellipse's leftmost point.
  assert.deepEqual(clipEnd([0, 30], [-40, 30], d, "ellipse"), [0, 30]);
  assert.deepEqual(clipEnd([0, 10], [-40, 10], d, "box"), [0, 10]);
});

const design = (children) =>
  normalize(JSON.stringify({ schema: 1, mode: "light", token_sets: {}, assets: {}, links: [], pages: [{ id: "p_one", name: "One", children }] })).design;
const shape = (id, x, y) => ({ id, type: "shape", shape: "rect", x, y, w: 100, h: 60 });
const polyline = (laid, id) => laid.connectors.find((o) => o.op === "polyline" && o.el === id)?.points;

test("the layout routes page connectors around other nodes and re-routes when an end moves", () => {
  const conn = { id: "n_c", type: "connector", from: { node: "n_a" }, to: { node: "n_b" } };
  const before = design([shape("n_a", 0, 0), shape("n_b", 400, 0), { id: "n_wall", type: "shape", shape: "rect", x: 200, y: -80, w: 60, h: 220 }, conn]);
  const laid = makeLayout(before).layoutPage(before.pages[0]);
  const pts = polyline(laid, "n_c");
  assert.ok(pts && !crosses(pts, { x: 200, y: -80, w: 60, h: 220 }), JSON.stringify(pts));

  const after = design([shape("n_a", 0, 0), shape("n_b", 0, 300), { id: "n_wall", type: "shape", shape: "rect", x: 200, y: -80, w: 60, h: 220 }, conn]);
  const moved = polyline(makeLayout(after).layoutPage(after.pages[0]), "n_c");
  assert.deepEqual(moved[0], [50, 60], "leaves the bottom of A now that B is below it");
  assert.ok(Math.abs(moved.at(-1)[1] - 300) < 10, `ends at B's top (arrowhead shortens the line): ${JSON.stringify(moved)}`);
});

test("a connector inside a section avoids the section's other nodes, and moving the section moves it along", () => {
  const sec = (x) => ({
    id: "n_s", type: "section", name: "S", x, y: 0, w: 700, h: 300,
    children: [shape("n_a", 20, 60), shape("n_b", 520, 60), { id: "n_mid", type: "shape", shape: "rect", x: 280, y: 30, w: 60, h: 140 }, { id: "n_c", type: "connector", from: { node: "n_a" }, to: { node: "n_b" } }],
  });
  const d1 = design([sec(0)]);
  const p1 = makeLayout(d1).layoutPage(d1.pages[0]).nodes[0].ops.find((o) => o.op === "polyline").points;
  assert.ok(!crosses(p1, { x: 280, y: 30, w: 60, h: 140 }), JSON.stringify(p1));
  const d2 = design([sec(1000)]);
  const p2 = makeLayout(d2).layoutPage(d2.pages[0]).nodes[0].ops.find((o) => o.op === "polyline").points;
  assert.deepEqual(p2, p1.map(([x, y]) => [x + 1000, y]));
});

test("routing a busy page stays fast", () => {
  const kids = [];
  for (let i = 0; i < 20; i++) for (let j = 0; j < 10; j++) kids.push(shape(`n_s${i}_${j}`, i * 180, j * 120));
  for (let k = 0; k < 40; k++) kids.push({ id: `n_k${k}`, type: "connector", from: { node: `n_s${k % 20}_0` }, to: { node: `n_s${19 - (k % 20)}_9` } });
  const d = design(kids);
  const t0 = performance.now();
  makeLayout(d).layoutPage(d.pages[0]);
  const ms = performance.now() - t0;
  assert.ok(ms < 1500, `took ${ms.toFixed(0)} ms`);
});

test("close obstacles shorten stubs without being discarded", () => {
  const source = { x: 0, y: 0, w: 100, h: 100 };
  const target = { x: 300, y: 0, w: 100, h: 100 };
  for (const wall of [{ x: 110, y: 20, w: 40, h: 60 }, { x: 250, y: 20, w: 40, h: 60 }]) {
    const pts = routeOrthogonal(source, "right", target, "left", [wall]);
    assert.ok(orthogonal(pts));
    assert.deepEqual(pts[0], [100, 50]);
    assert.deepEqual(pts.at(-1), [300, 50]);
    for (const box of [source, target, wall]) assert.ok(!crosses(pts, box), JSON.stringify(pts));
  }
});

test("moving a node onto a cached endpoint invalidates a route that crosses its interior", () => {
  const from = { x: 100, y: 0, w: 100, h: 100 };
  const to = { x: 300, y: 0, w: 100, h: 100 };
  const points = [[100, 50], [300, 50]];
  assert.equal(pointsStillFit(points, from, to, []), false);
  for (const anchors of [{}, { fromAnchor: "right", toAnchor: "left" }]) {
    const pts = connectorPath({ from, to, ...anchors }, { points });
    assert.deepEqual(pts, [[200, 50], [300, 50]]);
    assert.ok(!crosses(pts, from));
  }
});

test("cached routes respect explicit anchors even when they touch another edge", () => {
  const points = [[50, 0], [50, -40], [450, -40], [450, 0]];
  assert.equal(pointsStillFit(points, A, B, []), true);
  const pts = connectorPath({ from: A, to: B, fromAnchor: "right", toAnchor: "left" }, { points });
  assert.deepEqual(pts, [[100, 30], [400, 30]]);
});
