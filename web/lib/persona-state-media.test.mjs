import assert from "node:assert/strict";
import test from "node:test";
import { hasLoops, loopFor, loopStateFor } from "./persona-state-media.ts";

const summary = (loops) => ({ loops, generating: false });

test("each character state maps to the loop the server stores", () => {
  assert.equal(loopStateFor("static"), "idle");
  assert.equal(loopStateFor("working"), "coding");
  assert.equal(loopStateFor("needs_you"), "needs_you");
  assert.equal(loopStateFor("reading"), "reading");
});

test("a state plays its own loop when it has one", () => {
  const s = summary({ idle: "/i", reading: "/r", thinking: "/t" });
  assert.deepEqual(loopFor(s, "reading"), { state: "reading", url: "/r" });
});

test("a work state without a loop falls back to thinking, then idle", () => {
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t" }), "coding"), { state: "thinking", url: "/t" });
  assert.deepEqual(loopFor(summary({ idle: "/i" }), "working"), { state: "idle", url: "/i" });
});

test("needs-you never borrows the thinking loop", () => {
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t" }), "needs_you"), { state: "idle", url: "/i" });
});

test("any loop beats none, and no loops means fall back to the avatar", () => {
  assert.deepEqual(loopFor(summary({ creating: "/c" }), "idle"), { state: "creating", url: "/c" });
  assert.equal(loopFor(summary({}), "idle"), undefined);
  assert.equal(loopFor(undefined, "idle"), undefined);
  assert.equal(hasLoops(summary({})), false);
  assert.equal(hasLoops(summary({ idle: "/i" })), true);
});
