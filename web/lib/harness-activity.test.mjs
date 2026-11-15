import test from "node:test";
import assert from "node:assert/strict";
import { checkedAgo, connectedHarnesses, harnessWorking, resetLabel, usageTone, sessionPercent, usageSub } from "./harness-activity.ts";

const harness = (h, over = {}) => ({ harness: h, label: { codex: "Codex", antigravity: "Antigravity" }[h] ?? "Claude", running: 0, usage_available: false, windows: [], ...over });
const session = (used, resets_at) => ({ id: "five_hour", kind: "session", label: "Session", used_percent: used, resets_at });
const weekly = (used) => ({ id: "seven_day", kind: "weekly", label: "Weekly", used_percent: used });
test("only connected harnesses show, in a stable order, and a working one is never hidden", () => {
  const claude = harness("claude-code", { connected: true });
  const codex = harness("codex", { connected: false });
  const agy = harness("antigravity", { connected: true });
  assert.deepEqual(connectedHarnesses([agy, codex, claude]).map((h) => h.harness), ["claude-code", "antigravity"]);
  assert.deepEqual(connectedHarnesses([codex]), []);
  assert.deepEqual(connectedHarnesses([]), []);
  // Runs already underway on a harness whose key was removed keep it visible.
  const busy = { ...codex, running: 2 };
  assert.deepEqual(connectedHarnesses([agy, busy, claude]).map((h) => h.harness), ["claude-code", "codex", "antigravity"]);
  assert.equal(harnessWorking(busy), true);
  assert.equal(harnessWorking({ ...busy, limited_until: "2026-11-09T21:20:00Z" }), false);
  assert.equal(harnessWorking(undefined), false);
});

test("meters show the session window, full while limited, nothing when unread", () => {
  assert.equal(sessionPercent(harness("claude-code", { usage_available: true, windows: [weekly(61), session(38.4)] })), 38);
  assert.equal(sessionPercent(harness("codex", { limited_until: "2026-11-09T21:20:00Z" })), 100);
  assert.equal(sessionPercent(harness("codex")), null);
  assert.equal(sessionPercent(undefined), null);
  assert.equal(sessionPercent(harness("claude-code", { usage_available: true, windows: [session(0)] })), 0);
});

test("meters warn near the limit and turn red once it's hit", () => {
  assert.equal(usageTone(harness("claude-code", { usage_available: true, windows: [session(79.4)] })), "ok");
  assert.equal(usageTone(harness("claude-code", { usage_available: true, windows: [session(80)] })), "warn");
  assert.equal(usageTone(harness("codex", { limited_until: "2026-11-09T21:20:00Z" })), "limited");
  assert.equal(usageTone(harness("codex")), "ok");
  assert.equal(usageTone(undefined), "ok");
});

test("usage lines", () => {
  const now = new Date("2026-11-09T18:00:00");
  const claude = harness("claude-code", { usage_available: true, usage_checked_at: "2026-11-09T17:59:20", windows: [session(38, "2026-11-09T21:20:00"), weekly(61)] });
  const codex = harness("codex", { limited_until: "2026-11-09T21:20:00" });
  assert.match(usageSub(claude, [claude, codex], now), /^5h · resets 9:20\s?PM · weekly 61%$/);
  assert.match(usageSub(codex, [claude, codex], now), /^Limited until 9:20\s?PM · falls back to Claude$/);
  assert.equal(usageSub(harness("codex"), [], now), "Usage not checked yet");
  assert.equal(usageSub(harness("codex", { usage_checked_at: "2026-11-09T17:00:00" }), [], now), "Usage unavailable · check Usage settings");
  assert.match(resetLabel("2026-11-12T08:00:00", now), /^Thu 8:00\s?AM$/);
  assert.equal(checkedAgo([claude, codex], now.getTime()), "checked 40s ago");
  assert.equal(checkedAgo([codex], now.getTime()), "not checked yet");
  // A check in flight: first readings say so, later ones keep their figures.
  assert.equal(usageSub(harness("codex", { usage_checking: true }), [], now), "Checking usage…");
  assert.equal(usageSub(harness("codex", { usage_checking: true, usage_checked_at: "2026-11-09T17:00:00" }), [], now), "Checking usage…");
  assert.match(usageSub({ ...claude, usage_checking: true }, [claude], now), /^5h · resets/);
  assert.equal(checkedAgo([claude, { ...codex, usage_checking: true }], now.getTime()), "checking…");
});

test("Antigravity displays usage windows when reported and falls back cleanly when unavailable", () => {
  const agyUnknown = harness("antigravity", { usage_checked_at: "2026-11-09T18:00:00Z" });
  assert.equal(sessionPercent(agyUnknown), null);
  assert.equal(usageTone(agyUnknown), "ok");
  assert.match(usageSub(agyUnknown, [agyUnknown]), /^Usage unknown/);
  assert.equal(usageSub(harness("antigravity", { usage_checking: true }), []), "Checking usage…");

  const now = new Date("2026-11-09T18:00:00");
  const agyLive = harness("antigravity", {
    usage_available: true,
    windows: [
      { id: "agy_gemini", kind: "other", label: "Gemini", used_percent: 28.4, resets_at: "2026-11-09T21:20:00" },
      { id: "agy_claude", kind: "other", label: "Claude", used_percent: 45 },
    ],
  });
  assert.equal(sessionPercent(agyLive), 28);
  assert.match(usageSub(agyLive, [agyLive], now), /^Gemini · resets 9:20\s?PM · Claude 45%$/);
  // Claude's wording is unchanged.
  assert.equal(usageSub(harness("claude-code"), []), "Usage not checked yet");
});
