import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { apiErrorMessage, apiRequest, joinApiUrl } from "../dist/api.js";
import { loadAppState, saveAppState } from "../dist/appstate.js";

test("joinApiUrl only builds same-origin API URLs", () => {
  assert.equal(joinApiUrl("http://localhost:8080/", "/api/v1/inbox"), "http://localhost:8080/api/v1/inbox");
  assert.throws(() => joinApiUrl("http://localhost:8080", "https://evil.example/api/v1/x"));
  assert.throws(() => joinApiUrl("http://localhost:8080", "/events"));
});

test("apiRequest sends JSON and returns parsed data", async () => {
  const calls = [];
  const res = await apiRequest(
    async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ id: "x" }), { status: 201 });
    },
    "http://localhost:8080",
    "POST",
    "/api/v1/knowledge/capture",
    { body_md: "hi" },
  );
  assert.deepEqual(res, { ok: true, status: 201, data: { id: "x" } });
  assert.equal(calls[0].url, "http://localhost:8080/api/v1/knowledge/capture");
  assert.equal(calls[0].init.headers["Content-Type"], "application/json");
  assert.equal(calls[0].init.body, JSON.stringify({ body_md: "hi" }));
});

test("apiRequest reports the server's message, refusals and network failures", async () => {
  const conflict = await apiRequest(async () => new Response(JSON.stringify({ code: "conflict", message: "already decided" }), { status: 409 }), "http://h", "POST", "/api/v1/approvals/x/approve");
  assert.deepEqual(conflict, { ok: false, status: 409, error: "already decided" });
  const refused = await apiRequest(async () => new Response("", { status: 200 }), "http://h", "GET", "/not-api");
  assert.equal(refused.ok, false);
  assert.equal(refused.status, 0);
  const down = await apiRequest(async () => {
    throw new TypeError("fetch failed");
  }, "http://h", "GET", "/api/v1/inbox");
  assert.deepEqual(down, { ok: false, status: 0, error: "Vesper isn't reachable." });
  assert.equal(apiErrorMessage(401, null), "Vesper isn't signed in.");
  assert.equal(apiErrorMessage(500, "nope"), "The server answered 500.");
});

test("apiRequest sends a raw multipart body with its content type", async () => {
  let seen;
  await apiRequest(
    async (_url, init) => {
      seen = init;
      return new Response("{}", { status: 201 });
    },
    "http://h",
    "POST",
    "/api/v1/chat-attachments",
    undefined,
    { rawBody: { data: Buffer.from("abc"), contentType: "multipart/form-data; boundary=B" } },
  );
  assert.equal(seen.headers["Content-Type"], "multipart/form-data; boundary=B");
  assert.deepEqual([...seen.body], [97, 98, 99]);
});

test("app state round-trips and ignores junk", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-appstate-"));
  const file = path.join(dir, "app-state.json");
  assert.deepEqual(loadAppState(file), {});
  saveAppState(file, { lastVersion: "0.2.0", lastUpdateCheckAt: 5, announcedUpdate: "0.3.0" });
  assert.deepEqual(loadAppState(file), { lastVersion: "0.2.0", lastUpdateCheckAt: 5, announcedUpdate: "0.3.0" });
  fs.writeFileSync(file, JSON.stringify({ lastVersion: 3, lastUpdateCheckAt: "x", extra: true }));
  assert.deepEqual(loadAppState(file), {});
  fs.rmSync(dir, { recursive: true, force: true });
});
