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

import { SPEECH_WAIT_MS, setPopoutOpen, setSpeechPlayer, setVoiceMuted } from "./companion-store.ts";

test("a spoken reply waits for its voice, then reveals in time with it", async () => {
  let stopped = 0;
  setSpeechPlayer(async () => ({ words: 4, seconds: 0.2, stop: () => stopped++ }));
  startReveal("v1", "m", "one two three four", 1, { url: "/s", mode: "always" });
  assert.equal(companionState("v1"), "talking", "talking while the voice loads");
  await sleep(10);
  await sleep(320);
  assert.equal(companionState("v1"), "idle", "4 words over 0.2s of audio finish fast, not at 1 word/s");
  assert.equal(stopped, 0, "a voice that finishes isn't cut off");
});

test("pop-out voices speak only while the pop-out is open, and mute wins", async () => {
  let plays = 0;
  setSpeechPlayer(async () => {
    plays++;
    return { words: 1, seconds: 0.05, stop() {} };
  });
  startReveal("v2", "a", "hi", 0, { url: "/s", mode: "popout" });
  assert.equal(plays, 0, "pop-out closed: silent");
  setPopoutOpen("v2", true);
  startReveal("v2", "b", "hi", 0, { url: "/s", mode: "popout" });
  await sleep(5);
  assert.equal(plays, 1, "pop-out open: spoken");
  setVoiceMuted(true);
  startReveal("v2", "c", "hi", 0, { url: "/s", mode: "always" });
  await sleep(5);
  assert.equal(plays, 1, "muted: never fetched");
  setVoiceMuted(false);
});

test("skipping a spoken reply stops its voice, and a failed voice reveals silently", async () => {
  let stopped = 0;
  setSpeechPlayer(async () => ({ words: 100, seconds: 30, stop: () => stopped++ }));
  startReveal("v3", "m", "a long spoken reply", 15, { url: "/s", mode: "always" });
  await sleep(5);
  finishReveal("v3");
  assert.equal(stopped, 1);
  setSpeechPlayer(async () => null);
  startReveal("v3", "n", "fallback text here", 40, { url: "/s", mode: "always" });
  await sleep(5);
  assert.equal(companionState("v3"), "talking", "revealing at the persona's pace instead");
  assert.ok(SPEECH_WAIT_MS >= 5000);
  finishReveal("v3");
});
