import test from "node:test";
import assert from "node:assert/strict";
import { findInThread, stepFindIndex } from "./chat-find.ts";

test("findInThread finds case-insensitive matches across messages and skips system rows", () => {
  const hits = findInThread(
    [
      { id: "m1", role: "user", body_md: "Check guardDial for SSRF" },
      { id: "s1", role: "system", body_md: "guardDial system notice" },
      { id: "m2", role: "assistant", body_md: "guardDial checks public IPs; guardDial blocks loopback." },
    ],
    "guarddial",
  );
  assert.equal(hits.length, 3);
  assert.equal(hits[0].messageId, "m1");
  assert.equal(hits[1].messageId, "m2");
  assert.equal(hits[1].occurrence, 0);
  assert.equal(hits[2].messageId, "m2");
  assert.equal(hits[2].occurrence, 1);
  assert.deepEqual(findInThread([{ id: "m1", role: "user", body_md: "abc" }], "   "), []);
});

test("stepFindIndex wraps cleanly in both directions", () => {
  assert.equal(stepFindIndex(0, 1, 3), 1);
  assert.equal(stepFindIndex(2, 1, 3), 0);
  assert.equal(stepFindIndex(0, -1, 3), 2);
  assert.equal(stepFindIndex(-1, 1, 3), 0);
  assert.equal(stepFindIndex(0, 1, 0), -1);
});
