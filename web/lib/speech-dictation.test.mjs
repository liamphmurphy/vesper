import test from "node:test";
import assert from "node:assert/strict";
import { HOLD_THRESHOLD_MS, resolveMicRelease, stitchDictation } from "./speech-dictation.ts";

test("stitchDictation joins base draft and spoken words cleanly", () => {
  assert.equal(stitchDictation("", "hello world"), "hello world");
  assert.equal(stitchDictation("Check", "the logs"), "Check the logs");
  assert.equal(stitchDictation("Check ", "the logs"), "Check the logs");
  assert.equal(stitchDictation("Line 1\n", "Line 2"), "Line 1\nLine 2");
  assert.equal(stitchDictation("Keep me", "   "), "Keep me");
});

test("resolveMicRelease distinguishes push-to-talk hold from toggle tap", () => {
  assert.equal(resolveMicRelease({ elapsedMs: 120, wasListeningBeforePress: false }), "keep-listening");
  assert.equal(resolveMicRelease({ elapsedMs: HOLD_THRESHOLD_MS, wasListeningBeforePress: false }), "stop");
  assert.equal(resolveMicRelease({ elapsedMs: 650, wasListeningBeforePress: false }), "stop");
  assert.equal(resolveMicRelease({ elapsedMs: 90, wasListeningBeforePress: true }), "stop");
});
