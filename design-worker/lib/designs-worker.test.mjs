import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { deps, handleInspect, handleLayout, handleRender, MAX_CONCURRENT } from "./designs/worker.ts";

const fx = (p) => new URL(`../../docs/design/fixtures/${p}`, import.meta.url);
const body = readFileSync(fx("acceptance-design.json"), "utf8");
const assets = () => ({ [Object.keys(JSON.parse(body).assets)[0]]: `data:image/png;base64,${readFileSync(fx("landscape.png")).toString("base64")}` });
const TOKEN = "test-token";
process.env.DESIGN_WORKER_TOKEN = TOKEN;

const call = (handler, payload, token = TOKEN) =>
  handler(new Request("http://x/internal/designs", { method: "POST", headers: token === null ? {} : { authorization: `Bearer ${token}` }, body: JSON.stringify(payload) }));
const png = (res) => res.arrayBuffer().then((b) => Buffer.from(b));

test("refuses a missing or wrong token, and everything when no token is configured", async () => {
  assert.equal((await call(handleRender, { body }, null)).status, 401);
  assert.equal((await call(handleRender, { body }, "nope")).status, 401);
  assert.equal((await call(handleLayout, { body }, "")).status, 401);
  delete process.env.DESIGN_WORKER_TOKEN;
  try {
    assert.equal((await call(handleRender, { body }, "")).status, 401);
    assert.equal((await call(handleLayout, { body }, "undefined")).status, 401);
  } finally {
    process.env.DESIGN_WORKER_TOKEN = TOKEN;
  }
});

test("renders a node to a PNG at the scaled size", async () => {
  const r1 = await call(handleRender, { body, node: "n_pay", assets: assets() });
  assert.equal(r1.status, 200);
  assert.equal(r1.headers.get("content-type"), "image/png");
  const w = Number(r1.headers.get("x-design-width")), h = Number(r1.headers.get("x-design-height"));
  const b = await png(r1);
  assert.equal(b.subarray(1, 4).toString(), "PNG");
  assert.equal(b.readUInt32BE(16), w);
  assert.equal(b.readUInt32BE(20), h);
  const r2 = await call(handleRender, { body, node: "n_pay", scale: 2, assets: assets() });
  assert.equal(Number(r2.headers.get("x-design-width")), Math.round(w * 2));
});

test("renders the first page by default and a named page", async () => {
  const first = await call(handleRender, { body });
  assert.equal(first.status, 200);
  const page = JSON.parse(body).pages[0].id;
  const named = await call(handleRender, { body, page });
  assert.equal(named.headers.get("x-design-width"), first.headers.get("x-design-width"));
});

test("bad requests are 400 with a message", async () => {
  for (const p of [
    { body: "not json" },
    { body: 5 },
    { body, node: "n_nope" },
    { body, page: "p_nope" },
    { body, node: "n_pay", page: "p_x" },
    { body, scale: 0.5 },
    { body, scale: 4 },
    { body, assets: { a_1: "http://example.com/x.png" } },
  ]) {
    const r = await call(handleRender, p);
    assert.equal(r.status, 400, JSON.stringify(p).slice(0, 60));
    assert.equal(typeof (await r.json()).message, "string");
  }
});

test("an output over 4096 px on its longest edge is refused", async () => {
  const big = JSON.stringify({ schema: 1, mode: "light", token_sets: {}, assets: {}, links: [], pages: [{ id: "p_a", name: "A", children: [{ id: "n_big", type: "frame", name: "Big", x: 0, y: 0, w: 1500, h: 100, fill: "#FFFFFF", children: [] }] }] });
  const over = await call(handleRender, { body: big, scale: 3 });
  assert.equal(over.status, 400);
  assert.match((await over.json()).message, /4096/);
  assert.equal((await call(handleRender, { body: big, scale: 2 })).status, 200);
});

test("a fifth concurrent render is 503, and a slow one is 504", async () => {
  const real = deps.rasterize;
  let release;
  const gate = new Promise((r) => (release = r));
  deps.rasterize = async (...a) => (await gate, real(...a));
  try {
    const held = Array.from({ length: MAX_CONCURRENT }, () => call(handleRender, { body, node: "n_pay", assets: assets() }));
    await new Promise((r) => setTimeout(r, 50));
    const busy = await call(handleRender, { body, node: "n_pay", assets: assets() });
    assert.equal(busy.status, 503);
    release();
    for (const r of await Promise.all(held)) assert.equal(r.status, 200);
    assert.equal((await call(handleRender, { body, node: "n_pay", assets: assets() })).status, 200);
  } finally {
    deps.rasterize = real;
  }
  const realTimeout = AbortSignal.timeout;
  AbortSignal.timeout = () => AbortSignal.abort();
  deps.rasterize = () => new Promise(() => {});
  try {
    assert.equal((await call(handleRender, { body, node: "n_pay" })).status, 504);
  } finally {
    AbortSignal.timeout = realTimeout;
    deps.rasterize = real;
  }
});

test("layout returns absolute boxes for every stored node", async () => {
  const r = await call(handleLayout, { body });
  assert.equal(r.status, 200);
  const { pages } = await r.json();
  const design = JSON.parse(body);
  assert.equal(pages.length, design.pages.length);
  const ids = [];
  const walk = (ns) => ns.forEach((n) => (n.type !== "connector" && ids.push(n.id), walk(n.children ?? [])));
  walk(design.pages[0].children);
  for (const id of ids) {
    const b = pages[0].boxes[id];
    assert.ok(b && ["x", "y", "w", "h"].every((k) => typeof b[k] === "number"), id);
  }
  assert.ok(!Object.keys(pages[0].boxes).some((k) => k.includes("/")));
  const only = await (await call(handleLayout, { body, page: design.pages[0].id })).json();
  assert.equal(only.pages.length, 1);
  assert.equal((await call(handleLayout, { body, page: "p_nope" })).status, 400);
});

test("inspect returns the node's code, tokens and assets", async () => {
  const r = await call(handleInspect, { body, node: "n_pay", target: "tailwind" });
  assert.equal(r.status, 200);
  const out = await r.json();
  assert.equal(out.node.id, "n_pay");
  assert.ok(out.code.includes("bg-panel"));
  assert.ok(out.tokens.some((t) => t.name === "bg-panel"));
  assert.equal((await call(handleInspect, { body, node: "n_nope" })).status, 400);
  assert.equal((await call(handleInspect, { body, node: "n_pay", target: "swift" })).status, 400);
  assert.equal((await call(handleInspect, { body, node: "n_pay" }, "wrong")).status, 401);
});
