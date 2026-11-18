import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import { isNativeShell, nativeConfirm, nativeContextMenu, onCommand, post, postDeduped, request, resetDedupe } from "./bridge.ts";

let posted;
let win;

function install({ native = true } = {}) {
  posted = [];
  win = new EventTarget();
  if (native) {
    win.__VESPER_NATIVE__ = { v: 1, platform: "macos" };
    win.webkit = { messageHandlers: { vesper: { postMessage: (m) => posted.push(m) } } };
  }
  globalThis.window = win;
  resetDedupe();
}
const send = (cmd) => win.dispatchEvent(new CustomEvent("vesper-native", { detail: cmd }));

beforeEach(() => install());

test("isNativeShell needs the marker and the handler", () => {
  assert.equal(isNativeShell(), true);
  win.__VESPER_NATIVE__ = { v: 2 };
  assert.equal(isNativeShell(), false);
  install({ native: false });
  assert.equal(isNativeShell(), false);
  delete globalThis.window;
  assert.equal(isNativeShell(), false);
});

test("post sends valid messages in the shell and nothing elsewhere", () => {
  post({ v: 1, type: "ready", path: "/" });
  post({ v: 1, type: "bogus" });
  assert.deepEqual(posted, [{ v: 1, type: "ready", path: "/" }]);
  install({ native: false });
  post({ v: 1, type: "ready", path: "/" });
  assert.deepEqual(posted, []);
});

test("postDeduped skips an equal message of the same type", () => {
  postDeduped({ v: 1, type: "title", title: "A" });
  postDeduped({ v: 1, type: "title", title: "A" });
  postDeduped({ v: 1, type: "title", title: "B" });
  postDeduped({ v: 1, type: "title", title: "A" });
  assert.deepEqual(posted.map((m) => m.title), ["A", "B", "A"]);
});

test("onCommand delivers valid commands, ignores others, and unsubscribes", () => {
  const got = [];
  const off = onCommand((c) => got.push(c));
  send({ v: 1, type: "command", name: "newChat" });
  send({ v: 1, type: "navigate", path: "//evil" });
  send({ v: 2, type: "command", name: "newChat" });
  send("junk");
  win.dispatchEvent(new Event("vesper-native"));
  assert.deepEqual(got, [{ v: 1, type: "command", name: "newChat" }]);
  off();
  send({ v: 1, type: "command", name: "find" });
  assert.equal(got.length, 1);
});

test("request resolves with the reply that carries its id", async () => {
  const p = request({ type: "confirmApproval", scope: "run_approvals" });
  const sent = posted[0];
  assert.equal(sent.type, "confirmApproval");
  assert.equal(sent.v, 1);
  assert.match(sent.requestId, /\S/);
  send({ v: 1, type: "reply", requestId: "other", ok: false });
  send({ v: 1, type: "reply", requestId: sent.requestId, ok: true });
  assert.equal((await p).ok, true);
});

test("ids differ between requests", () => {
  request({ type: "openWorkspaceMenu", folder: "/a" }, { timeoutMs: 5 }).catch(() => {});
  request({ type: "openWorkspaceMenu", folder: "/b" }, { timeoutMs: 5 }).catch(() => {});
  assert.notEqual(posted[0].requestId, posted[1].requestId);
});

test("request rejects on timeout and outside the shell", async () => {
  await assert.rejects(request({ type: "openWorkspaceMenu", folder: "/w" }, { timeoutMs: 10 }), /didn't answer/);
  install({ native: false });
  await assert.rejects(request({ type: "openWorkspaceMenu", folder: "/w" }), /native shell/);
});

test("nativeContextMenu gives the chosen id, null when dismissed or outside the shell", async () => {
  const p = nativeContextMenu([{ id: "a", label: "A" }], 4, 5);
  assert.deepEqual([posted[0].type, posted[0].x, posted[0].y], ["contextMenu", 4, 5]);
  send({ v: 1, type: "reply", requestId: posted[0].requestId, ok: true, selectedId: "a" });
  assert.equal(await p, "a");
  const q = nativeContextMenu([], 0, 0);
  send({ v: 1, type: "reply", requestId: posted[1].requestId, ok: true, selectedId: null });
  assert.equal(await q, null);
  install({ native: false });
  assert.equal(await nativeContextMenu([], 0, 0), null);
});

test("nativeConfirm asks for a sheet and is true only when the person confirms", async () => {
  const p = nativeConfirm({ title: "Delete it?", body: "Gone for good.", confirmLabel: "Delete", destructive: true });
  assert.deepEqual(
    { type: posted[0].type, title: posted[0].title, body: posted[0].body, confirmLabel: posted[0].confirmLabel, destructive: posted[0].destructive },
    { type: "confirm", title: "Delete it?", body: "Gone for good.", confirmLabel: "Delete", destructive: true },
  );
  send({ v: 1, type: "reply", requestId: posted[0].requestId, ok: true });
  assert.equal(await p, true);
  const q = nativeConfirm({ title: "Delete it?", confirmLabel: "Delete", destructive: true });
  send({ v: 1, type: "reply", requestId: posted[1].requestId, ok: false });
  assert.equal(await q, false);
  install({ native: false });
  assert.equal(await nativeConfirm({ title: "x", confirmLabel: "y", destructive: false }), false);
});
