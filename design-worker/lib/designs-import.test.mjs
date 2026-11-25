import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { importFlowchart, parseFlowchart, MermaidError } from "./designs/mermaid.ts";
import { importSvg, SvgImportError } from "./designs/svgimport.ts";
import { importNode, WorkerError } from "./designs/worker.ts";
import { makeLayout } from "./designs/layout.ts";
import { pointsStillFit, segmentHits } from "./designs/route.ts";
import { normalize } from "./designs/schema.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const CHECKOUT = read("../../docs/design/fixtures/checkout.mmd");
const acceptance = () => normalize(read("../../docs/design/fixtures/acceptance-design.json")).design;
let seq = 0;
const ids = () => `n_t${++seq}`;
const blank = (mode = "light") => normalize(JSON.stringify({ schema: 1, mode, token_sets: {}, assets: {}, links: [], pages: [{ id: "p_one", name: "One", children: [] }] })).design;
const withNode = (d, node) => ({ ...d, pages: [{ ...d.pages[0], children: [...d.pages[0].children, node] }] });
const walk = (n, f) => (f(n), (n.children ?? []).forEach((c) => walk(c, f)));
const overlap = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

test("the checkout fixture imports as a readable, auto-laid-out diagram", async () => {
  const { section, warnings } = await importFlowchart(CHECKOUT, { design: blank(), ids, x: 100, y: 50 });
  const d = normalize(withNode(blank(), section)).design; // validates
  const shapes = [], sections = [], connectors = [];
  walk(section, (n) => (n.type === "shape" ? shapes : n.type === "connector" ? connectors : n !== section && n.type === "section" ? sections : []).push(n));
  assert.equal(shapes.length, 11);
  assert.deepEqual(sections.map((s) => s.name), ["Payment"]);
  assert.equal(sections[0].children.filter((c) => c.type === "shape").length, 4, "the subgraph's nodes are inside it");
  assert.equal(connectors.length, 11);
  assert.deepEqual(connectors.filter((c) => c.label).map((c) => c.label).sort(), ["Checkout", "no", "retry", "yes"]);
  assert.equal(connectors.filter((c) => c.dash).length, 2);
  assert.equal(connectors.filter((c) => c.end_arrow === "none").length, 1, "--- has no arrowhead");
  assert.equal(shapes.find((s) => s.name === "Card OK?").shape, "diamond");
  assert.equal(shapes.find((s) => s.name === "Done").shape, "ellipse");
  assert.ok(warnings.some((w) => /classDef/.test(w)) && warnings.some((w) => /cylinder/.test(w)) && warnings.some((w) => /asymmetric/.test(w)), warnings.join("\n"));

  // Readable: no two nodes overlap, every label fits its shape, and every
  // connector's route starts and ends on its nodes without crossing another.
  const laid = makeLayout(d).layoutPage(d.pages[0]);
  const boxes = shapes.map((s) => ({ id: s.id, ...laid.boxes.get(s.id) }));
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) assert.ok(!overlap(boxes[i], boxes[j]), `${boxes[i].id} overlaps ${boxes[j].id}`);
  assert.equal(laid.overflow.size, 0);
  const sec = laid.boxes.get(section.id);
  const containerOf = new Map();
  walk(section, (n) => (n.children ?? []).forEach((c) => containerOf.set(c.id, n)));
  for (const c of connectors) {
    const origin = laid.boxes.get(containerOf.get(c.id).id);
    const pts = c.points.map(([x, y]) => [origin.x + x, origin.y + y]);
    const others = boxes.filter((b) => b.id !== c.from.node && b.id !== c.to.node);
    assert.ok(pointsStillFit(pts, laid.boxes.get(c.from.node), laid.boxes.get(c.to.node), others), `${c.from.node} -> ${c.to.node} doesn't fit: ${JSON.stringify(pts)}`);
    for (const p of pts) assert.ok(p[0] >= sec.x && p[0] <= sec.x + sec.w && p[1] >= sec.y && p[1] <= sec.y + sec.h, "routes stay inside the import section");
  }
  // The drawn lines are the stored routes (kept, not re-routed), clipped to the diamond's outline.
  const drawn = laid.nodes[0].ops.filter((o) => o.op === "polyline");
  assert.equal(drawn.length, 11);
  const into = connectors.find((c) => c.to.node === shapes.find((s) => s.name === "Card OK?").id);
  const end = drawn.find((o) => o.el === into.id).points.at(-1);
  const db = laid.boxes.get(into.to.node);
  assert.ok(segmentHits(end, [db.x + db.w / 2, db.y + db.h / 2], db), "ends at the diamond, not short of it");
});

test("imported colours use the design's tokens when it has them", async () => {
  const { section } = await importFlowchart("flowchart TD\n a --> b", { design: acceptance(), ids });
  const shape = section.children.find((n) => n.type === "shape");
  assert.equal(shape.fill, "$surface");
  const { section: plain } = await importFlowchart("flowchart TD\n a --> b", { design: blank("dark"), ids });
  assert.match(plain.children.find((n) => n.type === "shape").fill, /^#[0-9A-F]{6}/);
});

test("Mermaid it can't parse is refused with the line and the problem", () => {
  const cases = [
    ["sequenceDiagram\n  A->>B: hi", /^line 1: .*only flowcharts can be imported/],
    ["flowchart LR\n  A -->", /^line 2: the edge has no target node/],
    ["flowchart LR\n  A[open --> B", /^line 2: node A opens \[ but never closes it with \]/],
    ["flowchart LR\n  A ~~> B", /^line 2: expected an edge .* or the end of the line: "~~> B"/],
    ["flowchart LR\n  subgraph x\n  A --> B", /^subgraph x has no 'end'/],
    ["flowchart LR\n  end", /^line 2: 'end' without a subgraph/],
    ["", /^line 1: the text is empty/],
    ["%% only a comment", /^line 1: the text is empty/],
  ];
  for (const [src, re] of cases) assert.throws(() => parseFlowchart(src), (e) => e instanceof MermaidError && re.test(e.message), src);
});

const doc = () => JSON.stringify({ ...acceptance() });

test("the worker's import refuses bad Mermaid with a named problem and returns no node", async () => {
  await assert.rejects(importNode({ body: doc(), page: acceptance().pages[0].id, mermaid: "flowchart LR\n  A -->" }), (e) => e instanceof WorkerError && e.status === 400 && e.message === 'mermaid: line 2: the edge has no target node: "A -->"');
  await assert.rejects(importNode({ body: doc(), page: acceptance().pages[0].id }), (e) => e instanceof WorkerError && /mermaid or svg/.test(e.message));
  await assert.rejects(importNode({ body: doc(), page: "p_nope", mermaid: "flowchart LR\n a" }), (e) => e instanceof WorkerError && /isn't in the design/.test(e.message));
});

test("the worker's import places the chart right of the page's content and it validates in place", async () => {
  const d = acceptance();
  const page = d.pages.find((p) => p.children.length);
  const box = makeLayout(d).layoutPage(page).box;
  const { node } = await importNode({ body: doc(), page: page.id, mermaid: CHECKOUT });
  assert.equal(node.type, "section");
  assert.equal(node.x, Math.round(box.x + box.w + 160));
  const at = await importNode({ body: doc(), page: page.id, mermaid: "flowchart LR\n a --> b", x: 10, y: 20 });
  assert.deepEqual([at.node.x, at.node.y], [10, 20]);
});

test("SVG imports rects, circles, paths, lines and text, and skips what it can't map with a warning", () => {
  const svg = `<?xml version="1.0"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
  <defs><linearGradient id="g"><stop offset="0"/></linearGradient></defs>
  <g transform="translate(10, 5)" fill="#3366cc">
    <rect x="0" y="0" width="80" height="40" rx="6" stroke="#000" stroke-width="2"/>
    <circle cx="120" cy="20" r="20" fill="rgb(255, 0, 0)" fill-opacity="0.5"/>
  </g>
  <path d="M10 60 h50 v20 q10 10 20 0 c5 -5 10 -5 15 0 a5 5 0 0 1 10 0 z" fill="none" stroke="#333"/>
  <line x1="0" y1="95" x2="200" y2="95" stroke="#999"/>
  <text x="100" y="80" font-size="14" font-weight="bold" fill="#111">Hello &amp; welcome</text>
  <g transform="rotate(45)"><rect width="10" height="10"/></g>
  <image href="x.png" width="10" height="10"/>
</svg>`;
  const { node, warnings } = importSvg(svg, { ids, x: 0, y: 0 });
  normalize(withNode(blank(), node));
  const kinds = node.children.map((n) => (n.type === "shape" ? n.shape : n.type));
  assert.deepEqual(kinds, ["roundRect", "ellipse", "path", "path", "text"]);
  const [rect, circle, path, , text] = node.children;
  assert.equal(rect.fill, "#3366CC", "fill inherited from the group");
  assert.equal(rect.stroke, "#000000");
  assert.equal(circle.fill, "#FF000080");
  assert.match(path.d, /^M[\d. ]+ L/);
  assert.ok(!/[HVAa]/.test(path.d));
  assert.equal(text.paragraphs[0].runs[0].text, "Hello & welcome");
  assert.equal(text.paragraphs[0].runs[0].weight, 700);
  assert.ok(warnings.some((w) => /<defs>/.test(w)));
  assert.ok(warnings.some((w) => /rotate/.test(w)));
  assert.ok(warnings.some((w) => /<image>/.test(w)));
  assert.ok(warnings.some((w) => /arcs/.test(w)));
});

test("SVG it can't read is refused with the problem named", () => {
  assert.throws(() => importSvg("<svg><rect></svg>", { ids }), (e) => e instanceof SvgImportError && /closes <rect>/.test(e.message));
  assert.throws(() => importSvg("<div/>", { ids }), (e) => e instanceof SvgImportError && /expected an <svg>/.test(e.message));
  assert.throws(() => importSvg("<svg><image href='a.png'/></svg>", { ids }), (e) => e instanceof SvgImportError && /nothing that can be imported/.test(e.message));
});

test("SVG close-path followed by a number is rejected without blocking the worker", async () => {
  const { spawnSync } = await import("node:child_process");
  const svgModule = new URL("./designs/svgimport.ts", import.meta.url).href;
  const result = spawnSync(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e", `
    import assert from 'node:assert/strict';
    import { importSvg, SvgImportError } from ${JSON.stringify(svgModule)};
    for (const command of ['Z', 'z']) {
      assert.throws(() => importSvg('<svg><path d="M0 0 L10 10 ' + command + ' 1"/></svg>', { ids: () => 'n_test' }),
        e => e instanceof SvgImportError && /needs a command before a number/.test(e.message));
    }
    const result = importSvg('<svg><path d="M0 0 L10 10 Z M20 20 L30 30 z"/></svg>', { ids: () => 'n_test' });
    assert.equal(result.node.children.length, 1);
  `], { timeout: 5000, encoding: "utf8" });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr);
});
