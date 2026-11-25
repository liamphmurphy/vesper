import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CAPS, normalize, problem } from "./designs/schema.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const shared = "./designs/fixtures/";

test("the acceptance design and the shared minimal body are valid", () => {
  for (const f of ["../../docs/design/fixtures/acceptance-design.json", shared + "valid-minimal.json", "../../docs/design/poc/evidence/mermaid/checkout.design.json"]) {
    const { json } = normalize(read(f));
    assert.equal(normalize(json).json, json, `${f} changes when normalised twice`);
  }
});

test("a link whose target frame is gone is kept as broken; one to a non-frame is refused", () => {
  const body = read("../../docs/design/fixtures/acceptance-design.json");
  assert.equal(problem(body.replace('"to": "n_done"', '"to": "n_gone"')), null);
  assert.match(problem(body.replace('"to": "n_done"', '"to": "n_pay_btn"')) ?? "", /isn't a top-level frame/);
});

test("normalising matches the server byte for byte", () => {
  // server/internal/design writes this golden file (go test -run Golden -update).
  assert.equal(normalize(read("../../docs/design/fixtures/acceptance-design.json")).json, read(shared + "acceptance.normalized.json"));
});

test("the shared invalid bodies are refused with the server's reason", () => {
  const cases = JSON.parse(read(shared + "invalid/cases.json"));
  assert.ok(cases.length >= 12);
  for (const c of cases) {
    const msg = problem(read(shared + "invalid/" + c.file));
    assert.ok(msg, `${c.file} was accepted`);
    assert.ok(msg.includes(c.want), `${c.file}: ${msg} doesn't mention ${c.want}`);
  }
});

test("normalising rounds, upper-cases hex, maps bold and drops defaults", () => {
  const d = JSON.parse(read(shared + "valid-minimal.json"));
  const home = d.pages[0].children[0];
  Object.assign(home, { fill: "#a1b2c3", x: 1.23456, rotation: 0, visible: true });
  Object.assign(home.children[0].paragraphs[0].runs[0], { bold: true, italic: false });
  const { json } = normalize(d);
  for (const want of ['"fill":"#A1B2C3"', '"x":1.23', '"weight":700']) assert.ok(json.includes(want), want);
  for (const gone of ['"rotation"', '"visible"', '"bold"', '"italic"']) assert.ok(!json.includes(gone), gone);
});

test("caps: body size and node count", () => {
  assert.match(problem(`{"x":"${"a".repeat(CAPS.body)}"}`), /at most 2048 KB/);
  const d = JSON.parse(read(shared + "valid-minimal.json"));
  d.pages[0].children[1].children = Array.from({ length: CAPS.nodes }, (_, i) => ({ id: `n_s${i}`, type: "shape", shape: "rect", x: 0, y: 0, w: 1, h: 1 }));
  assert.match(problem(d), /nodes; the cap is 10000/);
});
