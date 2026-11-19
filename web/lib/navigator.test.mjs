import test from "node:test";
import assert from "node:assert/strict";
import { AREAS, claimNavigator, currentArea, navigatorClaimed, subscribeNavigator } from "./navigator.ts";

test("a path selects its area on the icon row", () => {
  assert.equal(currentArea("/"), "chat");
  assert.equal(currentArea("/chat/abc"), "chat");
  assert.equal(currentArea("/spaces/s1"), "chat");
  assert.equal(currentArea("/runs/r1"), "work");
  assert.equal(currentArea("/tickets/WEB-1"), "work");
  assert.equal(currentArea("/epics/e1"), "work");
  // Knowledge and Library live on the main bar, not in the Apps flyout.
  assert.equal(currentArea("/knowledge/p1/notes"), "knowledge");
  assert.equal(currentArea("/library"), "library");
  assert.equal(currentArea("/library/item-1"), "library");
  // Decks and designs are Knowledge pages (LAZYAGENTS-212).
  assert.equal(currentArea("/apps/designs/d1"), "knowledge");
  assert.equal(currentArea("/apps/slides/s1"), "knowledge");
  // Apps and tools without an entry of their own are the Apps flyout's.
  for (const p of ["/apps", "/apps/habit-tracker", "/workflows", "/reports"]) assert.equal(currentArea(p), "apps", p);
  for (const p of ["/settings", "/customization", "/chatter"]) assert.equal(currentArea(p), null, p);
});

test("AREAS lists the top-level areas in order", () => {
  assert.deepEqual(AREAS.map((a) => a.area), ["chat", "work", "knowledge", "library"]);
});

test("the navigator is claimed while any screen holds it, and tells its listeners", () => {
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
  assert.equal(calls, 4); // two claims and two releases
  off();
});
