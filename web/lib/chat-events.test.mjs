import assert from "node:assert/strict";
import test from "node:test";
import { createEventWindowSelector } from "./chat-events.ts";

const seqs = (events) => events.map((e) => e.seq);
const ev = (seq, at, type = "tool_call", payload = {}) => ({ seq, at, type, payload });

test("createEventWindowSelector keeps the same array reference when later-turn events are appended", () => {
  const select = createEventWindowSelector("2026-11-22T10:00:00Z", "2026-11-22T10:01:00Z");
  const initial = [
    ev(1, "2026-11-22T09:59:00Z", "tool_call", { id: "t0", tool: "read_page" }),
    ev(2, "2026-11-22T10:00:10Z", "tool_call", { id: "t1", tool: "read_page" }),
    ev(3, "2026-11-22T10:00:20Z", "tool_result", { id: "t1" }),
  ];
  const first = select(initial);
  assert.deepEqual(seqs(first), [2, 3]);

  // Live poll appends events from a newer turn after `until`.
  const afterLaterTurn = [
    ...initial,
    ev(4, "2026-11-22T10:02:00Z", "tool_call", { id: "t2", tool: "search_knowledge" }),
    ev(5, "2026-11-22T10:02:05Z", "tool_result", { id: "t2" }),
  ];
  const second = select(afterLaterTurn);
  assert.equal(second, first, "closed turn must keep exact slice identity across later-turn polls");
});

test("createEventWindowSelector pairs cross-boundary tool_call/tool_result and handles out-of-order inserts", () => {
  const select = createEventWindowSelector("2026-11-22T10:00:00Z", "2026-11-22T10:01:00Z");
  const base = [
    ev(1, "2026-11-22T09:59:55Z", "tool_call", { id: "early", tool: "save_memory" }),
    ev(2, "2026-11-22T10:00:05Z", "tool_result", { id: "early" }),
    ev(3, "2026-11-22T10:00:58Z", "tool_call", { id: "late", tool: "WebSearch" }),
  ];
  const first = select(base);
  // Includes the pre-window tool_call paired with the in-window tool_result.
  assert.deepEqual(seqs(first), [1, 2, 3]);

  // A matching tool_result arriving just after `until` is included.
  const withLateResult = [...base, ev(4, "2026-11-22T10:01:02Z", "tool_result", { id: "late" })];
  const second = select(withLateResult);
  assert.deepEqual(seqs(second), [1, 2, 3, 4]);

  // Out-of-order insertion inside the window falls back to a full scan and picks it up.
  const withOutOfOrder = [
    base[0],
    base[1],
    ev(2.5, "2026-11-22T10:00:30Z", "tool_call", { id: "mid", tool: "get_ticket" }),
    base[2],
    withLateResult[3],
  ];
  assert.deepEqual(seqs(select(withOutOfOrder)), [1, 2, 2.5, 3, 4]);
});
