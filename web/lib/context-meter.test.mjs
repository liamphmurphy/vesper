import test from "node:test";
import assert from "node:assert/strict";
import { collapsedReplyPreview, contextMeterState, formatTokenCount, isFoldableReply } from "./context-meter.ts";

test("formatTokenCount formats compact k suffixes", () => {
  assert.equal(formatTokenCount(0), "0");
  assert.equal(formatTokenCount(850), "850");
  assert.equal(formatTokenCount(12_500), "12.5k");
  assert.equal(formatTokenCount(42_000), "42k");
  assert.equal(formatTokenCount(160_000), "160k");
});

test("contextMeterState computes ratio, tone, and disabled label", () => {
  const low = contextMeterState(40_000, 160_000);
  assert.equal(low.tone, "neutral");
  assert.equal(low.label, "40k / 160k");

  const warn = contextMeterState(128_000, 160_000);
  assert.equal(warn.tone, "warning");

  const high = contextMeterState(150_000, 160_000);
  assert.equal(high.tone, "danger");

  const off = contextMeterState(25_000, 0);
  assert.equal(off.tone, "neutral");
  assert.equal(off.label, "25k tok");
});

test("isFoldableReply detects long prose and collapsedReplyPreview truncates cleanly", () => {
  assert.equal(isFoldableReply("Short reply"), false);
  assert.equal(isFoldableReply("a".repeat(2400)), true);
  assert.equal(isFoldableReply(Array.from({ length: 45 }, (_, i) => `Line ${i}`).join("\n")), true);
  assert.ok(collapsedReplyPreview("Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6", 3).includes("Line 3"));
});
