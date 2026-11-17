import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildCaptureRequest, captureResultHref, formatAccelerator, validateGlobalShortcut } from "../dist/capture.js";
import {
  buildMultipartBody,
  buildSendFilesRequest,
  classifyDroppedFiles,
  MAX_ATTACHMENT_BYTES,
  safeMultipartFilename,
} from "../dist/drop.js";
import {
  appBundlePath,
  documentWflow,
  filesScript,
  infoPlist,
  installServices,
  serviceSpecs,
  servicesInstalled,
  shQuote,
  textScript,
  uninstallServices,
} from "../dist/services.js";

const UUID = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b";

test("buildCaptureRequest builds the existing API call for each kind", () => {
  assert.deepEqual(buildCaptureRequest({ kind: "note", text: "  buy milk \r\n" }), {
    ok: true,
    request: { method: "POST", path: "/api/v1/knowledge/capture", body: { body_md: "buy milk" } },
  });
  assert.deepEqual(buildCaptureRequest({ kind: "message", text: "hi", personaId: UUID }).request.body, {
    persona_id: UUID,
    message: { body: "hi" },
  });
  assert.deepEqual(buildCaptureRequest({ kind: "message", text: "hi" }).request.body, { message: { body: "hi" } }, "default persona");
  assert.deepEqual(buildCaptureRequest({ kind: "ticket", text: "Fix login\nIt 500s on submit.\n", projectKey: "PAY" }).request, {
    method: "POST",
    path: "/api/v1/tickets",
    body: { project_key: "PAY", title: "Fix login", description_md: "It 500s on submit." },
  });
  assert.deepEqual(buildCaptureRequest({ kind: "ticket", text: "Just a title", projectKey: "PAY" }).request.body, {
    project_key: "PAY",
    title: "Just a title",
  });
});

test("buildCaptureRequest refuses empty text, bad ids and unknown kinds", () => {
  assert.equal(buildCaptureRequest({ kind: "note", text: "   " }).ok, false);
  assert.equal(buildCaptureRequest({ kind: "message", text: "x", personaId: "../admin" }).ok, false);
  assert.equal(buildCaptureRequest({ kind: "ticket", text: "x", projectKey: "pay/../x" }).ok, false);
  assert.equal(buildCaptureRequest({ kind: "ticket", text: "x" }).ok, false);
  assert.equal(buildCaptureRequest({ kind: "delete", text: "x" }).ok, false);
  assert.equal(buildCaptureRequest({ kind: "note", text: "x".repeat(100_001) }).ok, false);
});

test("captureResultHref only links validated ids", () => {
  assert.equal(captureResultHref("message", { id: UUID }), `/chat/${UUID}`);
  assert.equal(captureResultHref("ticket", { key: "PAY-12" }), "/tickets/PAY-12");
  assert.equal(captureResultHref("note", { id: UUID }), `/knowledge/${UUID}`);
  assert.equal(captureResultHref("ticket", { key: "../x" }), null);
  assert.equal(captureResultHref("message", null), null);
});

test("validateGlobalShortcut requires a real modifier and one key", () => {
  assert.deepEqual(validateGlobalShortcut("Alt+Shift+Space"), { ok: true, accelerator: "Alt+Shift+Space" });
  assert.deepEqual(validateGlobalShortcut("CommandOrControl+Shift+k"), { ok: true, accelerator: "CommandOrControl+Shift+K" });
  assert.equal(validateGlobalShortcut("Control+F5").ok, true);
  for (const bad of ["", "K", "Shift+K", "Alt+Alt+K", "Alt+", "Foo+K", "Alt+Shift", "Alt+Enterprise", 5]) {
    assert.equal(validateGlobalShortcut(bad).ok, false, String(bad));
  }
  assert.equal(formatAccelerator("Alt+Shift+Space"), "⌥⇧Space");
  assert.equal(formatAccelerator("CommandOrControl+K"), "⌘K");
});

test("classifyDroppedFiles mirrors the server's attachment rules", () => {
  const { accepted, rejected } = classifyDroppedFiles([
    { path: "/u/a.PDF", size: 10, isFile: true },
    { path: "/u/b.png", size: 10, isFile: true },
    { path: "/u/a.PDF", size: 10, isFile: true },
    { path: "/u/folder", size: 0, isFile: false },
    { path: "/u/c.exe", size: 10, isFile: true },
    { path: "/u/empty.txt", size: 0, isFile: true },
    { path: "/u/huge.zip", size: MAX_ATTACHMENT_BYTES + 1, isFile: true },
    { path: "/u/c.md", size: 1, isFile: true },
    { path: "/u/d.csv", size: 1, isFile: true },
    { path: "/u/e.json", size: 1, isFile: true },
    { path: "/u/f.txt", size: 1, isFile: true },
  ]);
  assert.deepEqual(accepted.map((a) => [a.name, a.mime]), [
    ["a.PDF", "application/pdf"],
    ["b.png", "image/png"],
    ["c.md", "text/markdown"],
    ["d.csv", "text/csv"],
    ["e.json", "application/json"],
  ]);
  assert.deepEqual(rejected.map((r) => r.name), ["folder", "c.exe", "empty.txt", "huge.zip", "f.txt"]);
  assert.match(rejected.at(-1).reason, /at most 5/);
});

test("buildMultipartBody encodes one file field with a safe filename", () => {
  const { body, contentType } = buildMultipartBody('we"ird\r\nname.txt', "text/plain", Buffer.from("hello"), "BOUNDARY");
  assert.equal(contentType, "multipart/form-data; boundary=BOUNDARY");
  assert.equal(
    body.toString("utf8"),
    '--BOUNDARY\r\nContent-Disposition: form-data; name="file"; filename="we_ird__name.txt"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--BOUNDARY--\r\n',
  );
  assert.equal(safeMultipartFilename(""), "file");
});

test("buildSendFilesRequest posts to a new or existing chat and validates ids", () => {
  assert.deepEqual(buildSendFilesRequest({ target: "new", attachmentIds: [UUID], message: "" }), {
    ok: true,
    path: "/api/v1/chats",
    body: { message: { body: "Here's this file.", attachment_ids: [UUID] } },
  });
  assert.deepEqual(buildSendFilesRequest({ target: UUID, attachmentIds: [UUID, UUID], message: " look " }), {
    ok: true,
    path: `/api/v1/chats/${UUID}/messages`,
    body: { body: "look", attachment_ids: [UUID, UUID] },
  });
  assert.equal(buildSendFilesRequest({ target: "../x", attachmentIds: [UUID] }).ok, false);
  assert.equal(buildSendFilesRequest({ target: "new", attachmentIds: ["nope"] }).ok, false);
  assert.equal(buildSendFilesRequest({ target: "new", attachmentIds: [] }).ok, false);
  assert.equal(buildSendFilesRequest({ target: "new", personaId: "x", attachmentIds: [UUID] }).ok, false);
});

test("Quick Action scripts quote the app path and never build URLs", () => {
  assert.equal(shQuote("/Applications/Ves'per.app"), "'/Applications/Ves'\\''per.app'");
  assert.equal(filesScript("/Applications/Vesper.app"), `open -a '/Applications/Vesper.app' "$@"\n`);
  const t = textScript("/Applications/Vesper.app");
  assert.match(t, /mktemp -d/);
  assert.match(t, /open -a '\/Applications\/Vesper\.app' "\$f"/);
  assert.doesNotMatch(t + filesScript("/x"), /vesper:\/\//);
});

test("Quick Action bundles declare a Services menu item and escape XML", () => {
  const [files, text] = serviceSpecs("/Applications/A&B <Vesper>.app");
  assert.match(infoPlist(files), /<string>Send to Vesper<\/string>/);
  assert.match(infoPlist(files), /NSSendFileTypes[\s\S]*public\.item/);
  assert.match(infoPlist(text), /NSSendTypes[\s\S]*NSStringPboardType/);
  const wflow = documentWflow(files);
  assert.match(wflow, /A&amp;B &lt;Vesper&gt;\.app/);
  assert.doesNotMatch(wflow, /A&B <Vesper>/);
  assert.match(wflow, /com\.apple\.Automator\.servicesMenu/);
  assert.match(documentWflow(text), /<integer>0<\/integer>/, "text arrives on stdin");
});

test("installServices writes both bundles and uninstallServices removes them", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-services-"));
  assert.equal(servicesInstalled(dir), false);
  const written = installServices("/Applications/Vesper.app", dir);
  assert.equal(written.length, 2);
  assert.equal(servicesInstalled(dir), true);
  uninstallServices(dir);
  assert.equal(servicesInstalled(dir), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("appBundlePath finds the .app around the executable", () => {
  assert.equal(appBundlePath("/Applications/Vesper.app/Contents/MacOS/Vesper"), "/Applications/Vesper.app");
  assert.equal(appBundlePath("/usr/local/bin/electron"), null);
});

test("systemShortcutConflict names shortcuts macOS keeps for itself", async () => {
  const { systemShortcutConflict } = await import("../dist/capture.js");
  assert.equal(systemShortcutConflict("CommandOrControl+Space"), "Spotlight");
  assert.equal(systemShortcutConflict("Cmd+Alt+Space"), "Finder search");
  assert.equal(systemShortcutConflict("Command+Shift+4"), "screenshots");
  assert.equal(systemShortcutConflict("Alt+Shift+Space"), null);
});
