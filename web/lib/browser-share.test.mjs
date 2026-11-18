import assert from "node:assert/strict";
import test from "node:test";
import { shareDetail, shareLabel } from "./browser-share.ts";

const base = {
  id: "s1",
  chat_id: "c1",
  chat_title: "Chat",
  url: "https://www.github.com/liamphmurphy/vesper/pull/42/",
  title: "",
  until: "page",
  include_screenshot: false,
  started_at: "2026-11-18T10:00:00Z",
  snapshot_at: "2026-11-18T10:00:00Z",
  stopped_at: null,
  stop_reason: "",
  reads: [],
};

test("a share is labelled by its title, else its host and path", () => {
  assert.equal(shareLabel({ ...base, title: "  Fix the tray  " }), "Fix the tray");
  assert.equal(shareLabel(base), "github.com/liamphmurphy/vesper/pull/42");
  assert.equal(shareLabel({ ...base, url: "not a url" }), "not a url");
});

test("the detail says what is shared, for how long, and who read it", () => {
  const now = Date.parse("2026-11-18T10:10:00Z");
  assert.equal(shareDetail(base, now), "Page text only, until you leave the page · not read yet");
  const read = { persona: "Meow", url: base.url, read_at: "2026-11-18T10:05:00Z" };
  assert.equal(
    shareDetail({ ...base, until: "stop", include_screenshot: true, reads: [read, read] }, now),
    "Text and a screenshot, until you stop · Meow read it 2 times, last 5m ago",
  );
  assert.match(shareDetail({ ...base, reads: Array(20).fill(read) }, now), /read it 20\+ times/);
});
