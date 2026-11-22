import assert from "node:assert/strict";
import test from "node:test";
import { COMPLETE_MS, companionState, finishReveal, markRevealed, setCompanionWork, startReveal } from "./companion-store.ts";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("idle until a turn works, then the turn's state", () => {
  assert.equal(companionState("a"), "idle");
  setCompanionWork("a", "coding");
  assert.equal(companionState("a"), "coding");
  setCompanionWork("a", undefined);
  assert.equal(companionState("a"), "idle", "no reply yet, so no complete beat");
});

test("a reply after real work talks, then plays complete, then idles", async () => {
  setCompanionWork("b", "thinking");
  setCompanionWork("b", undefined);
  startReveal("b", "m1", "one two three four", 100);
  assert.equal(companionState("b"), "talking");
  finishReveal("b");
  assert.equal(companionState("b"), "complete");
  setCompanionWork("b", "reading");
  assert.equal(companionState("b"), "reading", "a new turn takes over at once");
  setCompanionWork("b", undefined);
});

test("a reply with no work behind it, or after a stopped turn, never celebrates", () => {
  startReveal("c", "m1", "hi", 0);
  assert.equal(companionState("c"), "idle");
  setCompanionWork("c", "coding");
  setCompanionWork("c", "static");
  setCompanionWork("c", undefined);
  startReveal("c", "m2", "stopped", 0);
  assert.equal(companionState("c"), "idle");
});

test("an instant reply after work still celebrates, and history never replays", async () => {
  setCompanionWork("d", "creating");
  setCompanionWork("d", undefined);
  markRevealed("d", ["old"]);
  startReveal("d", "old", "already seen", 50);
  assert.equal(companionState("d"), "idle", "a reply seen on open isn't revealed again");
  startReveal("d", "new", "fresh", 0);
  assert.equal(companionState("d"), "complete");
  await sleep(COMPLETE_MS + 60);
  assert.equal(companionState("d"), "idle");
});
