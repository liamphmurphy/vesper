import test from "node:test";
import assert from "node:assert/strict";
import {
  authorInitials,
  countReviewRequests,
  filterReviewRequests,
  loadReviewFilterPrefs,
  relativeAge,
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
