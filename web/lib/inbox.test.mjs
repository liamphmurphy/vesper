import test from "node:test";
import assert from "node:assert/strict";
import { approvalId, isExternalHref, groupItems, isOpen, nextSelection, step, trayAction, trayItems, waited } from "./inbox.ts";

const at = (min) => new Date(Date.UTC(2026, 10, 7, 12, 0) - min * 60_000).toISOString();
const item = (id, kind, min, extra = {}) => ({ id, kind, created_at: at(min), resolved: false, read: false, ...extra });

test("groups follow urgency order and the longest wait comes first", () => {
  const items = [
    item("m1", "mention", 5),
    item("s1", "stalled", 40),
    item("q1", "question", 10),
    item("a2", "approval", 30),
    item("a1", "approval", 60),
    item("f1", "blocked", 300),
    item("old", "approval", 90, { resolved: true }),
  ];
  const groups = groupItems(items, "open", "oldest");
  assert.deepEqual(groups.map((g) => g.label), ["Approvals", "Questions", "Failed & stalled runs", "Mentions"]);
  assert.deepEqual(groups[0].items.map((i) => i.id), ["a1", "a2"]);
  assert.deepEqual(groups[2].items.map((i) => i.id), ["f1", "s1"]);
  assert.deepEqual(groupItems(items, "open", "newest")[0].items.map((i) => i.id), ["a2", "a1"]);
  assert.deepEqual(groupItems(items, "done", "oldest").flatMap((g) => g.items.map((i) => i.id)), ["old"]);
});

test("done or resolved items are not open", () => {
  assert.equal(isOpen(item("x", "approval", 1)), true);
  assert.equal(isOpen(item("x", "approval", 1, { read: true })), false);
  assert.equal(isOpen(item("x", "approval", 1, { resolved: true })), false);
});

test("focus keeps its slot when the selected item leaves", () => {
  assert.equal(nextSelection(["a", "b", "c"], "b", 1), "b");
  // b resolved: the next item takes its slot.
  assert.equal(nextSelection(["a", "c"], "b", 1), "c");
  // The last item resolved: the previous one.
  assert.equal(nextSelection(["a", "b"], "c", 2), "b");
  assert.equal(nextSelection([], "c", 2), undefined);
  assert.equal(nextSelection(["a"], undefined, 0), "a");
});

test("j/k wrap around", () => {
  assert.equal(step(["a", "b"], "b", 1), "a");
  assert.equal(step(["a", "b"], "a", -1), "b");
  assert.equal(step(["a", "b"], undefined, 1), "a");
  assert.equal(step([], "a", 1), undefined);
});

test("wait time reads in minutes, hours and days", () => {
  const now = Date.UTC(2026, 10, 7, 12, 0);
  assert.equal(waited(at(0), now), "now");
  assert.equal(waited(at(42), now), "42m");
  assert.equal(waited(at(65), now), "1h 5m");
  assert.equal(waited(at(180), now), "3h");
  assert.equal(waited(at(60 * 50), now), "2d");
});

test("the tray splits Needs you (urgency, longest wait) from Updates (newest), and leaves cleared items out of both", () => {
  const items = [
    item("m-ask", "mention", 5, { needs_you: true }),
    item("q1", "question", 10, { needs_you: true }),
    item("a2", "approval", 30, { needs_you: true }),
    item("a1", "approval", 60, { needs_you: true }),
    item("gate", "workflow_gate", 70, { needs_you: true }),
    item("done", "approval", 90, { needs_you: true, resolved: true }),
    item("m-fyi", "mention", 3, { needs_you: false }),
    item("pr", "merged", 20, { needs_you: false, read: true }),
    item("sched", "scheduled", 1, { needs_you: false }),
  ];
  const t = trayItems(items);
  assert.deepEqual(t.needs.map((i) => i.id), ["a1", "a2", "q1", "m-ask", "gate"]);
  // A read (cleared) update leaves the tab; the limit counts only what is still listed.
  assert.deepEqual(t.updates.map((i) => i.id), ["sched", "m-fyi"]);
  assert.deepEqual(trayItems(items, 1).updates.map((i) => i.id), ["sched"]);
  // Cleared until it changes: the server reports it unread again, and it is back.
  assert.deepEqual(trayItems(items.map((i) => ({ ...i, read: false }))).updates.map((i) => i.id), ["sched", "m-fyi", "pr"]);
});

test("each kind gets its inline tray action", () => {
  assert.deepEqual(trayAction("approval"), { type: "approve" });
  assert.deepEqual(trayAction("question"), { type: "reply" });
  assert.deepEqual(trayAction("question", false), { type: "open", label: "Open" });
  assert.deepEqual(trayAction("dispatch"), { type: "dispatch" });
  assert.deepEqual(trayAction("review"), { type: "open", label: "Open review" });
  assert.deepEqual(trayAction("planning"), { type: "open", label: "Review plan" });
  assert.equal(approvalId("approval:abc"), "abc");
  assert.equal(approvalId("question:abc"), undefined);
});

test("a pull request's GitHub URL is external, an app route is not", () => {
  assert.equal(isExternalHref("https://github.com/o/r/pull/1"), true);
  assert.equal(isExternalHref("/tickets/WEB-4"), false);
  assert.equal(trayAction("pr_approved").label, "Open on GitHub");
  assert.deepEqual(trayAction("pr_ci_failed"), { type: "open", label: "Fix CI" });
  assert.deepEqual(trayAction("pr_review_comments"), { type: "open", label: "Address comments" });
  const g = groupItems([item("pr_approved:1", "pr_approved", 5)], "open", "oldest");
  assert.deepEqual(g.map((x) => x.key), ["pr_approved"]);
  const fbGroups = groupItems([item("ci1", "pr_ci_failed", 10), item("rev1", "pr_review_comments", 5), item("m1", "mockup", 20)], "open", "oldest");
  assert.deepEqual(fbGroups.map((x) => x.key), ["pr_feedback", "mockup"]);
  assert.deepEqual(fbGroups[0].items.map((x) => x.id), ["ci1", "rev1"]);
});
