import { test } from "node:test";
import assert from "node:assert/strict";

const listeners = new Map();
globalThis.window = {
  addEventListener: (t, f) => listeners.set(f, t),
  removeEventListener: (t, f) => listeners.delete(f),
};
const { addLeaveGuard, hasUnsavedChanges } = await import("./leave-guard.ts");

test("no guards: nothing unsaved", () => {
  assert.equal(hasUnsavedChanges(), false);
});

test("a guard that prevents default reports unsaved changes until removed", () => {
  let dirty = true;
  const remove = addLeaveGuard((e) => {
    if (dirty) e.preventDefault();
  });
  assert.equal(listeners.size, 1, "also a real beforeunload listener for browsers");
  assert.equal(typeof window.__vesperHasUnsavedChanges, "function");
  assert.equal(hasUnsavedChanges(), true);
  dirty = false;
  assert.equal(hasUnsavedChanges(), false);
  remove();
  dirty = true;
  assert.equal(hasUnsavedChanges(), false);
  assert.equal(listeners.size, 0);
});

test("legacy returnValue assignment counts, a throwing guard doesn't block", () => {
  const a = addLeaveGuard(() => {
    throw new Error("broken");
  });
  assert.equal(hasUnsavedChanges(), false);
  const b = addLeaveGuard((e) => {
    e.returnValue = "";
  });
  assert.equal(hasUnsavedChanges(), true);
  a();
  b();
});
