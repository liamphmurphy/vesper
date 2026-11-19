import test from "node:test";
import assert from "node:assert/strict";
import { isPdfFence, parsePdfFence } from "./chat-pdf.ts";

test("isPdfFence matches only the pdf tag", () => {
  assert.equal(isPdfFence("pdf"), true);
  assert.equal(isPdfFence(" PDF title=Brief"), true);
  assert.equal(isPdfFence("pdfs"), false);
  assert.equal(isPdfFence(undefined), false);
});

test("parsePdfFence accepts a single UUID and rejects anything else", () => {
  const id = "11111111-2222-4333-8444-555555555555";
  assert.equal(parsePdfFence(`  ${id.toUpperCase()}\n`), id);
  assert.equal(parsePdfFence("not-a-uuid"), null);
  assert.equal(parsePdfFence(`${id}\nextra`), null);
});
