import test from "node:test";
import assert from "node:assert/strict";
import { claimNavigator, currentArea, navigatorClaimed, navigatorSlot, setNavigatorSlot, subscribeNavigator } from "./navigator.ts";

test("a path selects its area on the icon row", () => {
  assert.equal(currentArea("/"), "chat");
  assert.equal(currentArea("/chat/abc"), "chat");
  assert.equal(currentArea("/spaces/s1"), "chat");
  assert.equal(currentArea("/runs/r1"), "runs");
  assert.equal(currentArea("/tickets/WEB-1"), "tickets");
  assert.equal(currentArea("/epics/e1"), "tickets");
  assert.equal(currentArea("/knowledge/p1/notes"), "knowledge");
  // Decks and designs are Knowledge pages (LAZYAGENTS-212).
  assert.equal(currentArea("/apps/designs/d1"), "knowledge");
  assert.equal(currentArea("/apps/slides/s1"), "knowledge");
  // Apps and tools without an entry of their own are the Apps flyout's.
  for (const p of ["/apps/finance", "/library", "/workflows", "/reports"]) assert.equal(currentArea(p), "apps", p);
  for (const p of ["/settings", "/customization", "/chatter"]) assert.equal(currentArea(p), null, p);
});

test("the column's middle is claimed while any screen holds it, and tells its listeners", () => {
  let calls = 0;
  const off = subscribeNavigator(() => calls++);
  assert.equal(navigatorClaimed(), false);
  const a = claimNavigator();
  const b = claimNavigator();
  a();
  a(); // releasing twice is harmless
  assert.equal(navigatorClaimed(), true);
  b();
  assert.equal(navigatorClaimed(), false);
  const el = {};
  setNavigatorSlot(el);
  setNavigatorSlot(el); // the same element again is no change
  assert.equal(navigatorSlot(), el);
  setNavigatorSlot(null);
  assert.equal(calls, 6); // two claims, two releases, the slot set and cleared
  off();
});
