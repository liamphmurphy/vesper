import test from "node:test";
import assert from "node:assert/strict";
import { driveDraft, draftChanged, draftProblem, driveSecretChoices, driveStatus, folderIdFrom } from "./drive-backup.ts";

const defaults = { enabled: false, folder_id: "", at_time: "03:00", timezone: "", retention: 7, revision: 0 };

test("an unsaved backup starts in the browser's time zone; a saved one keeps its own", () => {
  assert.equal(driveDraft(defaults, "Europe/London").timezone, "Europe/London");
  assert.equal(driveDraft(defaults, "Europe/London").secret_id, null);
  assert.equal(driveDraft({ ...defaults, timezone: "UTC", revision: 3 }, "Europe/London").timezone, "UTC");
});

test("draftChanged notices any edited field", () => {
  const d = driveDraft(defaults, "UTC");
  assert.equal(draftChanged(d, { ...d }), false);
  assert.equal(draftChanged(d, { ...d, retention: 3 }), true);
});

test("only OAuth secrets are offered, ready ones first, with why the others can't upload", () => {
  const scopes = (s) => ({ scopes: s, signed_in_at: "2026-11-01T00:00:00Z", error: "" });
  const got = driveSecretChoices([
    { id: "a", name: "static", kind: "static" },
    { id: "b", name: "gmail", kind: "oauth", oauth: scopes(["https://www.googleapis.com/auth/gmail.readonly"]) },
    { id: "c", name: "drive", kind: "oauth", oauth: scopes(["https://www.googleapis.com/auth/drive.file"]) },
    { id: "d", name: "lapsed", kind: "oauth", oauth: { ...scopes(["https://www.googleapis.com/auth/drive"]), error: "invalid_grant" } },
    { id: "e", name: "new", kind: "oauth", oauth: { scopes: [], error: "" } },
  ]);
  assert.deepEqual(got.map((c) => [c.id, c.ready, c.reason]), [
    ["c", true, ""],
    ["b", false, "needs drive.file scope"],
    ["d", false, "sign in again"],
    ["e", false, "not signed in"],
  ]);
});

test("draftProblem requires a secret, folder and zone only while enabled", () => {
  const d = driveDraft(defaults, "UTC");
  assert.equal(draftProblem(d), "");
  assert.match(draftProblem({ ...d, enabled: true }), /sign-in/);
  assert.match(draftProblem({ ...d, enabled: true, secret_id: "c" }), /folder/);
  assert.equal(draftProblem({ ...d, enabled: true, secret_id: "c", folder_id: "abc" }), "");
  assert.match(draftProblem({ ...d, retention: 1001 }), /1000/);
  assert.match(draftProblem({ ...d, at_time: "25:00" }), /time/);
});

test("folderIdFrom takes an ID or a pasted folder link", () => {
  assert.equal(folderIdFrom(" 1AbC_d-9 "), "1AbC_d-9");
  assert.equal(folderIdFrom("https://drive.google.com/drive/folders/1AbC_d-9?usp=sharing"), "1AbC_d-9");
  assert.equal(folderIdFrom("https://drive.google.com/drive/u/0/folders/XyZ"), "XyZ");
  assert.equal(folderIdFrom("https://drive.google.com/open?id=Q1w2"), "Q1w2");
});

test("driveStatus says whether a backup runs, worked, failed or never ran", () => {
  assert.equal(driveStatus({ running: true, last_status: "failed" }).tone, "running");
  assert.equal(driveStatus({ running: false, last_status: "succeeded" }).tone, "ok");
  assert.equal(driveStatus({ running: false, last_status: "failed" }).tone, "failed");
  assert.equal(driveStatus({ running: false, last_status: "" }).tone, "idle");
});
