import test from "node:test";
import assert from "node:assert/strict";
import {
  authorInitials,
  countReviewRequests,
  dismissReviewRequests,
  DISMISSED_STORAGE_KEY,
  excludeDismissedReviewRequests,
  filterReviewRequests,
  isReviewRequestDismissed,
  loadDismissedReviewRequests,
  loadReviewFilterPrefs,
  relativeAge,
  restoreReviewRequests,
  saveDismissedReviewRequests,
  saveReviewFilterPrefs,
} from "./github-reviews.ts";

test("filterReviewRequests respects direct and team switches", () => {
  const items = [
    { id: "a", direct: true, team: false },
    { id: "b", direct: false, team: true },
    { id: "c", direct: true, team: true },
  ];

  assert.deepEqual(
    filterReviewRequests(items, { direct: true, team: true }).map((i) => i.id),
    ["a", "b", "c"],
  );
  assert.deepEqual(
    filterReviewRequests(items, { direct: true, team: false }).map((i) => i.id),
    ["a", "c"],
  );
  assert.deepEqual(
    filterReviewRequests(items, { direct: false, team: true }).map((i) => i.id),
    ["b", "c"],
  );
  assert.deepEqual(filterReviewRequests(items, { direct: false, team: false }), []);
  assert.deepEqual(countReviewRequests(items), { direct: 2, team: 2 });
});

test("filter prefs round-trip through storage", () => {
  const map = new Map();
  const storage = {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => map.set(k, v),
  };

  assert.deepEqual(loadReviewFilterPrefs(storage), { direct: true, team: true });
  saveReviewFilterPrefs(storage, { direct: true, team: false });
  assert.deepEqual(loadReviewFilterPrefs(storage), { direct: true, team: false });

  map.set("vesper:pr-review-filters", "{bad-json");
  assert.deepEqual(loadReviewFilterPrefs(storage), { direct: true, team: true });
});

test("authorInitials and relativeAge format cleanly", () => {
  assert.equal(authorInitials("alex-kim"), "AK");
  assert.equal(authorInitials("maya"), "MA");
  assert.equal(authorInitials(""), "GH");

  const now = Date.parse("2026-11-16T13:30:00Z");
  assert.equal(relativeAge("2026-11-16T13:29:40Z", now), "just now");
  assert.equal(relativeAge("2026-11-16T13:12:00Z", now), "18m ago");
  assert.equal(relativeAge("2026-11-16T11:30:00Z", now), "2h ago");
  assert.equal(relativeAge("2026-11-14T13:30:00Z", now), "2d ago");
});

test("dismissed review requests round-trip through storage and tolerate bad data", () => {
  const map = new Map();
  const storage = {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => map.set(k, v),
  };

  assert.deepEqual(loadDismissedReviewRequests(storage), {});
  const saved = { "o/r#1": "2026-11-18T10:00:00Z", "o/r#2": "2026-11-18T11:00:00Z" };
  saveDismissedReviewRequests(storage, saved);
  assert.deepEqual(loadDismissedReviewRequests(storage), saved);

  for (const bad of ["{bad-json", "[]", '"str"', "123", "null"]) {
    map.set(DISMISSED_STORAGE_KEY, bad);
    assert.deepEqual(loadDismissedReviewRequests(storage), {});
  }

  map.set(DISMISSED_STORAGE_KEY, JSON.stringify({ "o/r#1": "2026-11-18T10:00:00Z", "o/r#2": 42, "o/r#3": "", "": "x" }));
  assert.deepEqual(loadDismissedReviewRequests(storage), { "o/r#1": "2026-11-18T10:00:00Z" });
});

test("dismissed PRs stay hidden while updated_at matches and reappear when updated_at changes", () => {
  const items = [
    { id: "o/r#1", direct: true, team: false, updated_at: "2026-11-18T10:00:00Z" },
    { id: "o/r#2", direct: false, team: true, updated_at: "2026-11-18T11:00:00Z" },
    { id: "o/r#3", direct: true, team: true, updated_at: "2026-11-18T12:00:00Z" },
  ];

  // Single-PR dismiss hides only o/r#1 and updates counts for active items.
  let dismissed = dismissReviewRequests({}, [items[0]]);
  assert.equal(isReviewRequestDismissed(items[0], dismissed), true);
  assert.equal(isReviewRequestDismissed(items[1], dismissed), false);
  let active = excludeDismissedReviewRequests(items, dismissed);
  assert.deepEqual(active.map((i) => i.id), ["o/r#2", "o/r#3"]);
  assert.deepEqual(countReviewRequests(active), { direct: 1, team: 2 });

  // Updating updated_at on GitHub brings o/r#1 back without altering other dismissed entries.
  const updated = [
    { ...items[0], updated_at: "2026-11-18T12:30:00Z" },
    items[1],
    items[2],
  ];
  assert.equal(isReviewRequestDismissed(updated[0], dismissed), false);
  active = excludeDismissedReviewRequests(updated, dismissed);
  assert.deepEqual(active.map((i) => i.id), ["o/r#1", "o/r#2", "o/r#3"]);

  // Re-dismissing updated PR records the new updated_at, and Clear all dismisses all visible items.
  dismissed = dismissReviewRequests(dismissed, updated);
  assert.deepEqual(excludeDismissedReviewRequests(updated, dismissed), []);
  assert.equal(dismissed["o/r#1"], "2026-11-18T12:30:00Z");

  // Restoring a subset leaves unrelated dismissed IDs intact.
  const restored = restoreReviewRequests(dismissed, [updated[0]]);
  assert.deepEqual(excludeDismissedReviewRequests(updated, restored).map((i) => i.id), ["o/r#1"]);
  assert.equal(isReviewRequestDismissed(updated[1], restored), true);
});

test("prototype property names and empty updated_at values are handled safely", () => {
  const item = { id: "toString", updated_at: "" };
  assert.equal(isReviewRequestDismissed(item, {}), false);
  const dismissed = dismissReviewRequests({}, [item]);
  assert.equal(isReviewRequestDismissed(item, dismissed), true);
  assert.equal(isReviewRequestDismissed({ id: "toString", updated_at: "2026-11-18T12:00:00Z" }, dismissed), false);
});
