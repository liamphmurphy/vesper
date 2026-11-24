import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { exportItems, exportPdf, exportSvg, fileName, frameFor, pathSegs, pngTooLarge, renderQuery, usedFaces } from "./designs/export.ts";
import { normalize } from "./designs/schema.ts";

const fixtures = new URL("../../docs/design/fixtures/", import.meta.url);
const design = normalize(readFileSync(new URL("acceptance-design.json", fixtures), "utf8")).design;
const load = {
  font: async (face, kind) => new Uint8Array(readFileSync(new URL(`../public/fonts/designs/Inter-${face}.${kind}`, import.meta.url))),
  assets: { a_landscape: `data:image/png;base64,${readFileSync(new URL("landscape.png", fixtures)).toString("base64")}` },
};

async function pdfPages(bytes) {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const doc = await pdfjs.getDocument({ data: bytes, disableFontFace: true, verbosity: 0 }).promise;
  const pages = [];
  for (let i = 1; i <= doc.numPages; i++) {
    const p = await doc.getPage(i);
    const text = (await p.getTextContent()).items.map((t) => t.str).join(" ");
    pages.push({ size: [p.view[2] - p.view[0], p.view[3] - p.view[1]], text });
  }
  await doc.loadingTask.destroy();
  return pages;
}

test("each scope covers what it names", () => {
  const ids = (scope, at) => exportItems(design, scope, at).map((i) => i.node ?? `page:${i.page}`);
  // All frames: every page's top-level frames, in page order then layer order (sections and components aren't frames).
  assert.deepEqual(ids("frames", {}), ["n_cart", "n_ship", "n_pay", "n_done"]);
  // The frame holding the selection, else the page's first frame.
  const nested = exportItems(design, "selection", { selected: ["n_pay"] })[0].ops.length;
  assert.ok(nested > 0);
  assert.equal(frameFor(design, "p_flows", [])?.frame.id, "n_cart");
  assert.deepEqual(ids("page", { page: "p_diagrams" }), ["page:p_diagrams"]);
  assert.deepEqual(ids("selection", { selected: ["n_state", "n_missing", "n_pay"] }), ["n_state", "n_pay"]);
  assert.deepEqual(ids("frame", { page: "p_diagrams", selected: ["n_state"] }), []);
  const pay = exportItems(design, "frame", { page: "p_flows", selected: ["n_pay"] })[0];
  assert.deepEqual([pay.name, pay.box], ["Payment", { x: 946, y: 0, w: 393, h: 852 }]);
});

test("a nested node exports as its region of its top-level node", () => {
  let nested;
  const walk = (ns) => ns.forEach((n) => (n.type === "text" && !nested ? (nested = n.id) : walk(n.children ?? [])));
  walk(design.pages[0].children.find((n) => n.id === "n_pay").children);
  const [it] = exportItems(design, "selection", { selected: [nested] });
  const [frame] = exportItems(design, "selection", { selected: ["n_pay"] });
  assert.deepEqual(it.ops, frame.ops);
  assert.ok(it.box.w < frame.box.w && it.box.x >= frame.box.x);
  assert.equal(renderQuery(it, 2), `node=${nested}&scale=2`);
  assert.equal(renderQuery(exportItems(design, "page", { page: "p_flows" })[0], 3), "page=p_flows&scale=3");
});

test("a PNG over the renderer's limit is refused before it's asked for", () => {
  const [page] = exportItems(design, "page", { page: "p_flows" });
  assert.equal(pngTooLarge(page, 1), undefined);
  assert.match(pngTooLarge(page, 3), /would be 5436×2556 px at 3×; a PNG is at most 4096 px/);
});

test("file names drop characters file systems refuse", () => {
  assert.equal(fileName("Check/out: v2", "Pay?"), "Check out v2 - Pay");
  assert.equal(fileName("", ""), "Design");
});

test("SVG export keeps text as text and embeds only the faces it uses", async () => {
  const [state] = exportItems(design, "selection", { selected: ["n_state"] });
  const svg = await exportSvg(state, load);
  assert.ok(svg.startsWith('<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 420"'));
  assert.match(svg, /<text [^>]*>Paid<\/text>/);
  const faces = [...svg.matchAll(/@font-face\{[^}]*font-weight:(\d+);font-style:(\w+)\}/g)].map((m) => `${m[1]} ${m[2]}`).sort();
  assert.deepEqual(faces, usedFaces([state]).map(([w, i]) => `${w} ${i ? "italic" : "normal"}`).sort());
  assert.ok(!faces.includes("400 italic"));
  assert.match(svg, /font-family="&quot;Vesper Designs Inter&quot;, Inter, sans-serif"/);
  const [pay] = exportItems(design, "selection", { selected: ["n_pay"] });
  assert.match(await exportSvg(pay, load), /<image href="data:image\/png;base64,/);
});

test("PDF export has one page per frame at its size, in page order", async () => {
  const frames = exportItems(design, "frames", {});
  const pages = await pdfPages(await exportPdf(frames, load));
  assert.equal(pages.length, 4);
  for (const p of pages) assert.deepEqual(p.size, [393 * 0.75, 852 * 0.75]);
  // Each page carries its own frame's text, in order.
  frames.forEach((f, i) => assert.ok(pages[i].text.startsWith(f.ops.find((o) => o.op === "text").text), `page ${i + 1}: ${pages[i].text}`));
  assert.ok(pages[2].text.startsWith("Payment"));
  // Mixed sizes and orientations keep their own page size.
  const mixed = await pdfPages(await exportPdf([...exportItems(design, "selection", { selected: ["n_state", "n_pay"] })], load));
  assert.deepEqual(mixed.map((p) => p.size), [[540, 315], [294.75, 639]]);
  await assert.rejects(exportPdf([], load), /nothing to export/);
});

test("path data becomes PDF operators, quadratics as cubics", () => {
  assert.deepEqual(pathSegs("M1E-3 2e-3 3E2 4e2 5e1 6E1"), [
    { op: "m", c: [0.001, 0.002] },
    { op: "l", c: [300, 400] },
    { op: "l", c: [50, 60] },
  ]);
  assert.deepEqual(pathSegs("M0 0 L10 0 10 10Z"), [
    { op: "m", c: [0, 0] },
    { op: "l", c: [10, 0] },
    { op: "l", c: [10, 10] },
    { op: "h", c: [] },
  ]);
  assert.deepEqual(pathSegs("M0,0 Q 3 6 6 0"), [
    { op: "m", c: [0, 0] },
    { op: "c", c: [2, 4, 4, 4, 6, 0] },
  ]);
  assert.deepEqual(pathSegs("m1 1 l2 0 c1 1 2 2 3 3"), [
    { op: "m", c: [1, 1] },
    { op: "l", c: [3, 1] },
    { op: "c", c: [4, 2, 5, 3, 6, 4] },
  ]);
});
