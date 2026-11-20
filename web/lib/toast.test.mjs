import assert from "node:assert/strict";
import test from "node:test";
import { MAX_TOASTS, clearToasts, currentToasts, dismissToast, toast, undoable } from "./toast.ts";

const live = () => currentToasts().filter((t) => !t.leaving);
const flush = () => new Promise((r) => setTimeout(r, 0));
function reset() {
  delete globalThis.window;
  clearToasts();
}

function installNativeShell() {
  const posted = [];
  const win = new EventTarget();
  win.__VESPER_NATIVE__ = { v: 1, platform: "macos" };
  win.webkit = { messageHandlers: { vesper: { postMessage: (m) => posted.push(m) } } };
  globalThis.window = win;
  const send = (cmd) => win.dispatchEvent(new CustomEvent("vesper-native", { detail: cmd }));
  return { posted, send };
}

test("a toast with a known id replaces it instead of stacking", () => {
  reset();
  toast({ id: "finance", title: "One" });
  toast({ id: "finance", title: "Two" });
  assert.deepEqual(live().map((t) => t.title), ["Two"]);
});

test("errors stay longer than other toasts by default", () => {
  reset();
  const ok = toast("Saved");
  const bad = toast({ title: "Failed", tone: "error" });
  const byId = Object.fromEntries(live().map((t) => [t.id, t.duration]));
  assert.ok(byId[bad] > byId[ok]);
});

test("newer toasts push out the oldest, and the pushed-out one still closes", () => {
  reset();
  const closed = [];
  const first = toast({ title: "first", onClose: (why) => closed.push(why) });
  for (let i = 0; i < MAX_TOASTS; i++) toast(`more ${i}`);
  assert.equal(live().length, MAX_TOASTS);
  assert.ok(!live().some((t) => t.id === first));
  assert.deepEqual(closed, ["replaced"]);
});

test("undoable hides at once and commits only when the toast goes", async () => {
  reset();
  const log = [];
  const id = undoable({ title: "Removed", hide: () => log.push("hide"), restore: () => log.push("restore"), commit: async () => { log.push("commit"); } });
  assert.deepEqual(log, ["hide"]);
  dismissToast(id, "timeout");
  await flush();
  assert.deepEqual(log, ["hide", "commit"]);
});

test("Undo restores and never commits", async () => {
  reset();
  const log = [];
  const id = undoable({ title: "Removed", hide: () => log.push("hide"), restore: () => log.push("restore"), commit: async () => { log.push("commit"); } });
  live().find((t) => t.id === id).action.onClick();
  dismissToast(id, "action");
  await flush();
  assert.deepEqual(log, ["hide", "restore"]);
});

test("a failed commit restores the item and says so", async () => {
  reset();
  const log = [];
  const id = undoable({ title: "Removed", failed: "Couldn't remove it", hide: () => log.push("hide"), restore: () => log.push("restore"), commit: async () => { throw new Error("offline"); } });
  dismissToast(id);
  await flush();
  assert.deepEqual(log, ["hide", "restore"]);
  const error = live().find((t) => t.tone === "error");
  assert.equal(error?.title, "Couldn't remove it");
  assert.equal(error?.description, "offline");
});

test("native shell routes plain-text toasts over the bridge and drives undoable actions", async () => {
  reset();
  const { posted, send } = installNativeShell();
  const log = [];
  const id = undoable({
    title: "Archived note",
    description: "In Inbox",
    hide: () => log.push("hide"),
    restore: () => log.push("restore"),
    commit: async () => {
      log.push("commit");
    },
  });
  assert.equal(live().length, 0);
  assert.equal(posted[0].type, "toast.show");
  assert.equal(posted[0].id, id);
  assert.equal(posted[0].title, "Archived note");
  assert.equal(posted[0].actionLabel, "Undo");

  send({ v: 1, type: "toast.event", id, event: "action" });
  await flush();
  assert.deepEqual(log, ["hide", "restore"]);

  const id2 = undoable({
    title: "Archived second",
    hide: () => log.push("hide2"),
    restore: () => log.push("restore2"),
    commit: async () => {
      log.push("commit2");
    },
  });
  send({ v: 1, type: "toast.event", id: id2, event: "timeout" });
  await flush();
  assert.deepEqual(log, ["hide", "restore", "hide2", "commit2"]);

  const id3 = toast("Saved");
  dismissToast(id3, "dismissed");
  assert.equal(posted.at(-1)?.type, "toast.dismiss");
  assert.equal(posted.at(-1)?.id, id3);

  reset();
});
