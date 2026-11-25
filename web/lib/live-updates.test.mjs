import assert from "node:assert/strict";
import test from "node:test";
import { invalidatedBy, invalidatedKeys } from "./live-updates.ts";

test("a change hint invalidates its entity's queries and the overview counts", () => {
  assert.deepEqual(invalidatedBy("chat.updated"), ["chats", "canvases", "videos", "audio", "push-requests", "dock", "dashboard"]);
  assert.deepEqual(invalidatedBy("artifact.updated").slice(0, 2), ["artifacts", "wiki"]);
});

test("harness log lines and video and audio progress refetch only their own queries", () => {
  assert.deepEqual(invalidatedBy("run.events"), ["runs"]);
  assert.deepEqual(invalidatedBy("video.updated"), ["videos"]);
  assert.deepEqual(invalidatedBy("audio.updated"), ["audio"]);
  assert.deepEqual(invalidatedBy("custom_app.updated"), ["custom-apps"]);
  assert.deepEqual(invalidatedBy("browser_share.updated"), ["browser-shares"]);
  assert.deepEqual(invalidatedBy("pr_feedback.updated"), ["push-requests", "inbox", "bootstrap", "spaces"]);
});

test("approval hints also refresh chat tool approvals", () => {
  assert.deepEqual(invalidatedBy("approval.updated"), ["runs", "chats", "inbox", "bootstrap", "dashboard"]);
});

test("an unknown hint refetches only the overview counts", () => {
  assert.deepEqual(invalidatedBy("nope.updated"), ["dashboard"]);
});

// designKeys (lib/api/designs-hooks.ts) live under "canvases": the design, its versions and its suggestions.
test("a persona's patch on a design refreshes the open design mid-turn, not when the turn ends", () => {
  assert.ok(invalidatedBy("design.updated").includes("canvases"));
});

test("run.events invalidates only matching run and chat-run keys when ids are present", () => {
  assert.deepEqual(invalidatedKeys({ type: "run.events", ids: ["run-1", "run-2"] }), [
    ["runs", "run-1"],
    ["runs", "chat", "run-1"],
    ["runs", "run-2"],
    ["runs", "chat", "run-2"],
  ]);
  assert.deepEqual(invalidatedKeys({ type: "run.events", ids: [] }), [["runs"]]);
  assert.deepEqual(invalidatedKeys({ type: "run.events" }), [["runs"]]);
  assert.deepEqual(invalidatedKeys({ type: "video.updated", ids: ["v1"] }), [["videos"]]);
});
