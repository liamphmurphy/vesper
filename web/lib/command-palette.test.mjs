import assert from "node:assert/strict";
import test from "node:test";
import { MAX_RECENT, parseRecent, pushRecent, RECENT_KEY, recordRecent, SHORTCUTS } from "./command-palette.ts";

test("pushRecent dedupes by href, puts the latest first, and caps length", () => {
  const mk = (i) => ({ id: `id-${i}`, title: `Page ${i}`, href: `/knowledge/${i}`, kind: "page" });
  let list = [];
  for (let i = 0; i < MAX_RECENT + 3; i++) list = pushRecent(list, mk(i));
  assert.equal(list.length, MAX_RECENT);
  assert.equal(list[0].href, `/knowledge/${MAX_RECENT + 2}`);
  list = pushRecent(list, mk(4));
  assert.equal(list[0].href, "/knowledge/4");
  assert.equal(list.filter((r) => r.href === "/knowledge/4").length, 1);
});

test("parseRecent drops malformed entries and non-relative hrefs", () => {
  assert.deepEqual(parseRecent(null), []);
  assert.deepEqual(parseRecent("not-json"), []);
  assert.deepEqual(parseRecent(JSON.stringify({ nope: true })), []);
  const parsed = parseRecent(
    JSON.stringify([
      { id: "1", title: "Good", href: "/spaces/s1", kind: "space" },
      { id: "2", title: "External", href: "https://evil.test", kind: "space" },
      { id: 3, title: "Bad id", href: "/spaces/s3", kind: "space" },
    ]),
  );
  assert.deepEqual(parsed, [{ id: "1", title: "Good", href: "/spaces/s1", kind: "space" }]);
});

test("recordRecent persists to storage and ignores storage failures", () => {
  const mem = new Map();
  const store = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  recordRecent(store, { id: "a", title: "Alpha", href: "/apps/alpha", kind: "app" });
  assert.equal(parseRecent(mem.get(RECENT_KEY)).length, 1);
  assert.doesNotThrow(() =>
    recordRecent(
      { getItem: () => null, setItem: () => { throw new Error("quota"); } },
      { id: "a", title: "Alpha", href: "/apps/alpha", kind: "app" },
    ),
  );
});

test("SHORTCUTS contains no removed Work or Ticket sections", () => {
  const sections = SHORTCUTS.map((s) => s.section);
  assert.ok(!sections.includes("Work"));
  assert.ok(!sections.includes("Ticket"));
});
