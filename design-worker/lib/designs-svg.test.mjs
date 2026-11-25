import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { makeLayout, pageOps } from "./designs/layout.ts";
import { normalize } from "./designs/schema.ts";
import { toSvg } from "./designs/svg.ts";

const acceptance = () => normalize(readFileSync(new URL("../../docs/design/fixtures/acceptance-design.json", import.meta.url), "utf8")).design;

test("toSvg frames the box and draws each text piece with kerning off", () => {
  const svg = toSvg(
    [
      { op: "rect", x: 1, y: 2, w: 30, h: 20, r: 4, fill: "#FF000080", stroke: "#000000", sw: 2, dash: "4 3", el: "a" },
      { op: "text", x: 5, y: 15, text: "A & <B>", weight: 600, italic: true, size: 12, fill: "#111111", el: "t" },
      { op: "clip", x: 0, y: 0, w: 10, h: 10, r: 0 },
      { op: "rotate", deg: 30, cx: 5, cy: 5 },
      { op: "ellipse", x: 0, y: 0, w: 8, h: 4, fill: { angle: 90, stops: ["#000000", "#FFFFFF"] }, stroke: undefined, sw: 0, el: "e" },
    ],
    { box: { x: 0, y: 0, w: 40, h: 30 }, background: "#FFFFFF", scale: 2 },
  );
  assert.match(svg, /viewBox="0 0 40 30" width="80" height="60"/);
  assert.match(svg, /font-kerning:none/);
  assert.match(svg, /fill="#FF0000" fill-opacity="0.502"/);
  assert.match(svg, /stroke-dasharray="4 3"/);
  assert.match(svg, />A &amp; &lt;B&gt;<\/text>/);
  assert.match(svg, /font-style="italic"/);
  assert.match(svg, /<linearGradient/);
  // open groups are closed even without unclip/unrotate ops
  assert.equal(svg.match(/<g[ >]/g).length, svg.match(/<\/g>/g).length);
  assert.ok(!svg.includes("<script"));
});

test("images use the asset data URI, and an unknown asset draws empty", () => {
  const op = { op: "image", asset: "a_x", x: 0, y: 0, w: 10, h: 10, r: 0, src: { x: 0, y: 0, w: 10, h: 10 }, iw: 10, ih: 10, alt: 'say "hi"', el: "i" };
  const box = { x: 0, y: 0, w: 10, h: 10 };
  assert.match(toSvg([op], { box, assets: { a_x: "data:image/png;base64,AAAA" } }), /href="data:image\/png;base64,AAAA"/);
  assert.match(toSvg([op], { box }), /href=""/);
});

test("the acceptance page converts without error", () => {
  const d = acceptance();
  const laid = makeLayout(d).layoutPage(d.pages[0]);
  const svg = toSvg(pageOps(laid), { box: laid.box, background: laid.background });
  assert.ok(svg.startsWith("<svg") && svg.endsWith("</svg>"));
  assert.ok(svg.includes("<text"));
});
