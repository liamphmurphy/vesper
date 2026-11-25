import test from "node:test";
import assert from "node:assert/strict";
import { harnessHealth, orList, systemBanner } from "./setup.ts";

const groups = (anthropic, openai) => [
  { harness: "claude-code", label: "Claude Code", available: anthropic, ...(anthropic ? {} : { unavailable_reason: "no harness:anthropic secret" }) },
  { harness: "codex", label: "Codex", available: openai, ...(openai ? {} : { unavailable_reason: "No harness:openai secret" }) },
];

test("harness health names missing secrets once, by name only", () => {
  assert.equal(harnessHealth(undefined), undefined);
  const down = harnessHealth(groups(false, false));
  assert.equal(down.ready, false);
  assert.deepEqual(down.secrets, ["harness:anthropic", "harness:openai"]);
  assert.equal(down.reasons[0], "Claude Code: no harness:anthropic secret");
  assert.equal(harnessHealth(groups(true, false)).ready, true);
  assert.equal(harnessHealth([{ harness: "x", label: "X", available: false }]).reasons[0], "X: not configured");
});

test("orList joins names for a sentence", () => {
  assert.equal(orList(["a"]), "a");
  assert.equal(orList(["a", "b"]), "a or b");
  assert.equal(orList(["a", "b", "c"]), "a, b or c");
});

test("the shell banner prefers the harness problem, then the runner", () => {
  assert.equal(systemBanner(harnessHealth(groups(false, false)), true), "harness");
  assert.equal(systemBanner(harnessHealth(groups(true, false)), false), "runner");
  assert.equal(systemBanner(harnessHealth(groups(true, false)), true), undefined);
  // Unknown runner state (still loading or failed) doesn't raise a banner.
  assert.equal(systemBanner(undefined, undefined), undefined);
});

test("pending discovery is distinct from an unavailable harness", () => {
  const health = harnessHealth([
    { harness: "claude-code", label: "Claude Code", available: false, checking: true },
    ...groups(false, false).slice(1),
  ]);
  assert.equal(health.ready, false);
  assert.equal(health.checking, true);
  assert.equal(systemBanner(health, true), undefined);
  assert.equal(systemBanner(health, false), "runner");
});

test("a starting runner suppresses the offline banner", () => {
  const ready = harnessHealth(groups(true, false));
  assert.equal(systemBanner(ready, false, true), undefined);
  assert.equal(systemBanner(ready, false, false), "runner");
});
