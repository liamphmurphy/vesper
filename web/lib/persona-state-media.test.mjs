import assert from "node:assert/strict";
import test from "node:test";
import { hasLoops, loopFor, loopStateFor, revealSlice, revealWordsPerSecond } from "./persona-state-media.ts";

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

test("talking plays its own loop, else idle, never thinking", () => {
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t", talking: "/k" }), "talking"), { state: "talking", url: "/k" });
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t" }), "talking"), { state: "idle", url: "/i" });
});

test("auto paces only a persona with a talking loop", () => {
  assert.equal(revealWordsPerSecond("auto", summary({ idle: "/i" })), 0);
  assert.equal(revealWordsPerSecond("auto", summary({ talking: "/k" })), 15);
  assert.equal(revealWordsPerSecond(undefined, undefined), 0);
  assert.equal(revealWordsPerSecond("off", summary({ talking: "/k" })), 0);
  assert.equal(revealWordsPerSecond("deliberate", undefined), 8);
  assert.equal(revealWordsPerSecond("relaxed", undefined), 25);
});

test("a reveal cuts after whole words and finishes", () => {
  const text = "Hello there, general Kenobi.";
  assert.deepEqual(revealSlice(text, 0, 10), { text: "", done: false });
  assert.deepEqual(revealSlice(text, 100, 10), { text: "Hello ", done: false });
  assert.deepEqual(revealSlice(text, 250, 10), { text: "Hello there, ", done: false });
  assert.deepEqual(revealSlice(text, 400, 10), { text, done: true });
  assert.deepEqual(revealSlice(text, 0, 0), { text, done: true }, "pace 0 is instant");
});

test("complete plays its own loop, else idle, never thinking", () => {
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t", complete: "/c" }), "complete"), { state: "complete", url: "/c" });
  assert.deepEqual(loopFor(summary({ idle: "/i", thinking: "/t" }), "complete"), { state: "idle", url: "/i" });
});
