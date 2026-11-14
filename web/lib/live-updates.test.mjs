import assert from "node:assert/strict";
import test from "node:test";
import { invalidatedBy } from "./live-updates.ts";

test("a change hint invalidates its entity's queries and the overview counts", () => {
  assert.deepEqual(invalidatedBy("chat.updated"), ["chats", "canvases", "videos", "audio", "dock", "dashboard", "epics", "agent-overviews"]);
  assert.deepEqual(invalidatedBy("ticket.updated").slice(0, 2), ["planning", "tickets"]);
});

test("harness log lines and video and audio progress refetch only their own queries", () => {
  assert.deepEqual(invalidatedBy("run.events"), ["runs"]);
  assert.deepEqual(invalidatedBy("video.updated"), ["videos"]);
  assert.deepEqual(invalidatedBy("audio.updated"), ["audio"]);
  assert.deepEqual(invalidatedBy("custom_app.updated"), ["custom-apps"]);
});

test("an unknown hint refetches only the overview counts", () => {
  assert.deepEqual(invalidatedBy("nope.updated"), ["dashboard", "epics", "agent-overviews"]);
});

// designKeys (lib/api/designs-hooks.ts) live under "canvases": the design, its versions and its suggestions.
test("a persona's patch on a design refreshes the open design mid-turn, not when the turn ends", () => {
  assert.ok(invalidatedBy("design.updated").includes("canvases"));
});
