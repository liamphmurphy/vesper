import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildMetrics } from "./designs/inter-metrics-gen.ts";
import { face, measure } from "./designs/measure.ts";
import { constrain, makeLayout, pageOps, settle } from "./designs/layout.ts";
import { normalize } from "./designs/schema.ts";
import { makeLayout as pocLayout } from "../../docs/design/poc/layout.mjs";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const acceptance = () => normalize(read("../../docs/design/fixtures/acceptance-design.json")).design;

test("inter-metrics.json matches the shipped TTFs (npm run gen:inter-metrics)", () => {
  const dir = new URL("../fonts/designs/", import.meta.url);
  const fresh = buildMetrics((f) => readFileSync(new URL(f, dir)));
  assert.deepEqual(JSON.parse(read("./designs/inter-metrics.json")), JSON.parse(JSON.stringify(fresh)));
});

test("measuring is arithmetic over the table, weight and italic aware", () => {
  assert.ok(measure("Hello", 700, false, 16) > measure("Hello", 400, false, 16));
  assert.equal(measure("", 400, false, 16), 0);
  assert.equal(measure("ab", 400, false, 20), 2 * measure("ab", 400, false, 10));
});

test("text lands where the approved PoC layout put it", () => {
  const d = acceptance();
  const mine = makeLayout(d).layoutPage(d.pages[0]);
  const poc = pocLayout(d, { measure, face }).layoutPage(d.pages[0].id);
  const texts = (ops) => ops.filter((o) => o.op === "text").map((o) => `${o.text}@${o.x},${o.y}`);
  assert.deepEqual(texts(pageOps(mine)), texts(poc.ops));
});

const frame = (al, kids) => ({
  schema: 1, mode: "light", token_sets: {}, assets: {}, links: [],
  pages: [{ id: "p_1", name: "P", children: [{ id: "n_f", type: "frame", x: 0, y: 0, w: 300, h: 200, auto_layout: al, children: kids }] }],
});
const box = (id, w, h, extra = {}) => ({ id, type: "shape", shape: "rect", x: 0, y: 0, w, h, ...extra });
const kidBoxes = (d) => {
  const { local } = makeLayout(d).layoutPage(d.pages[0]);
  return ["n_a", "n_b"].map((id) => local.get(id));
};

test("path positioning accepts uppercase and lowercase exponents", () => {
  const d = frame(undefined, [{ id: "n_path", type: "path", x: 10, y: 20, w: 100, h: 100, d: "M1E1 2e1 L3E1 4E1" }]);
  const path = pageOps(makeLayout(d).layoutPage(d.pages[0])).find((op) => op.op === "path");
  assert.equal(path.d, "M20 40 L40 60");
});

test("auto layout reflows children when padding changes", () => {
  const al = { direction: "vertical", gap: 10, padding: [8, 8, 8, 8] };
  assert.deepEqual(kidBoxes(frame(al, [box("n_a", 50, 20), box("n_b", 50, 30)])), [{ x: 8, y: 8, w: 50, h: 20 }, { x: 8, y: 38, w: 50, h: 30 }]);
  const wider = { ...al, padding: [24, 0, 0, 16] };
  assert.deepEqual(kidBoxes(frame(wider, [box("n_a", 50, 20), box("n_b", 50, 30)])), [{ x: 16, y: 24, w: 50, h: 20 }, { x: 16, y: 54, w: 50, h: 30 }]);
});

test("auto layout reflows children when gap or direction changes", () => {
  const kids = [box("n_a", 50, 20), box("n_b", 60, 30)];
  assert.deepEqual(kidBoxes(frame({ direction: "horizontal", gap: 12 }, kids)), [{ x: 0, y: 0, w: 50, h: 20 }, { x: 62, y: 0, w: 60, h: 30 }]);
  assert.deepEqual(kidBoxes(frame({ direction: "horizontal", gap: 40 }, kids)), [{ x: 0, y: 0, w: 50, h: 20 }, { x: 90, y: 0, w: 60, h: 30 }]);
  assert.deepEqual(kidBoxes(frame({ direction: "vertical", gap: 40 }, kids)), [{ x: 0, y: 0, w: 50, h: 20 }, { x: 0, y: 60, w: 60, h: 30 }]);
});

test("fill shares the leftover space; align and justify place the run", () => {
  const kids = [box("n_a", 50, 20, { sizing: { w: "fill" } }), box("n_b", 100, 30)];
  assert.deepEqual(kidBoxes(frame({ direction: "horizontal", gap: 10, padding: [0, 10, 0, 10], align: "center" }, kids)), [{ x: 10, y: 90, w: 170, h: 20 }, { x: 190, y: 85, w: 100, h: 30 }]);
  const between = kidBoxes(frame({ direction: "horizontal", justify: "space-between" }, [box("n_a", 50, 20), box("n_b", 50, 20)]));
  assert.equal(between[1].x, 250);
});

test("a hug container grows with its children and settle() writes the cache", () => {
  const d = frame({ direction: "vertical", gap: 10, padding: [5, 5, 5, 5] }, [box("n_a", 50, 20), box("n_b", 80, 30)]);
  d.pages[0].children[0].sizing = { w: "hug", h: "hug" };
  const s = settle(d);
  const f = s.pages[0].children[0];
  assert.equal(f.w, 90);
  assert.equal(f.h, 70);
  assert.equal(f.children[1].y, 35);
  assert.equal(settle(s), s, "a settled design is returned unchanged");
});

test("the acceptance design is settled as stored, apart from the cache", () => {
  const d = acceptance();
  const s = settle(d);
  assert.equal(settle(s), s);
  assert.equal(normalize(s).design.pages.length, d.pages.length);
});

test("constraints move and stretch children of a resized container", () => {
  const c = { id: "n_c", type: "shape", shape: "rect", x: 10, y: 10, w: 20, h: 20 };
  assert.deepEqual(constrain({ ...c, constraints: { h: "right", v: "bottom" } }, 100, 100, 200, 150), { ...c, x: 110, y: 60, constraints: { h: "right", v: "bottom" } });
  assert.deepEqual(constrain({ ...c, constraints: { h: "left-right", v: "center" } }, 100, 100, 200, 150), { ...c, w: 120, y: 35, constraints: { h: "left-right", v: "center" } });
  assert.deepEqual(constrain({ ...c, constraints: { h: "scale" } }, 100, 100, 200, 100), { ...c, x: 20, w: 40, constraints: { h: "scale" } });
  const plain = { ...c };
  assert.equal(constrain(plain, 100, 100, 200, 200), plain);
});

test("hidden nodes draw nothing; rotation wraps a node's ops", () => {
  const d = frame(undefined, [box("n_a", 50, 20, { visible: false, fill: "#FF0000" }), box("n_b", 50, 20, { rotation: 45, fill: "#00FF00" })]);
  const ops = pageOps(makeLayout(d).layoutPage(d.pages[0]));
  assert.ok(!ops.some((o) => o.el === "n_a"));
  const i = ops.findIndex((o) => o.op === "rotate");
  assert.equal(ops[i].deg, 45);
  assert.equal(ops[i + 1].el, "n_b");
  assert.equal(ops[i + 2].op, "unrotate");
});

test("tokens resolve per mode, with fallbacks when the set lacks one", () => {
  const d = acceptance();
  const lay = makeLayout(d);
  const set = d.token_sets[d.tokens_ref.set];
  const name = Object.keys(set.modes.light ?? {}).find((k) => set.modes.light[k].kind === "color" && set.modes.light[k].value !== set.modes.dark[k]?.value);
  assert.ok(name);
  assert.equal(lay.color(`$${name}`, "light"), set.modes.light[name].value);
  assert.equal(lay.color(`$${name}`, "dark"), set.modes.dark[name].value);
  assert.match(lay.color("$no-such-token", "dark"), /^#/);
});

test("every node type in the acceptance design renders", () => {
  const d = acceptance();
  const lay = makeLayout(d);
  const seen = new Set();
  for (const p of d.pages) for (const o of pageOps(lay.layoutPage(p))) seen.add(o.op);
  for (const op of ["rect", "ellipse", "path", "polyline", "image", "text", "clip"]) assert.ok(seen.has(op), `no ${op} op`);
});
