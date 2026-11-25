import test from "node:test";
import assert from "node:assert/strict";
import { APP_ITEMS, DEV_TOOL_ITEM, TOOL_ITEMS, toolItems, RAIL_APP_ITEMS, inAppsMenu, isActive } from "./project-scope.ts";

test("Apps and Tools entries have unique hrefs and no removed Work-mode pages", () => {
  const hrefs = [...APP_ITEMS, ...TOOL_ITEMS].map((i) => i.href);
  assert.equal(new Set(hrefs).size, hrefs.length);
  for (const gone of ["/work", "/tickets", "/dashboard", "/board", "/epics", "/plans", "/runs", "/artifacts", "/costs", "/agents", "/customization"]) {
    assert.ok(!hrefs.includes(gone), gone);
  }
});

test("the Apps row is current on any page its flyout opens that has no rail entry of its own", () => {
  for (const p of ["/apps", "/apps/habit-tracker", "/workflows/1", "/scheduled", "/learn/2", "/reports", "/http", "/dev"]) assert.equal(inAppsMenu(p), true, p);
  for (const p of ["/", "/chat/1", "/spaces", "/inbox", "/settings"]) assert.equal(inAppsMenu(p), false, p);
  // Knowledge and Library have their own rail entries, which read as current instead, also for
  // decks' and designs' old addresses, which lead to their Knowledge pages (LAZYAGENTS-212).
  for (const p of ["/knowledge/abc/the-old-harbour", "/library", "/library/item-1", "/apps/designs/d1", "/apps/slides/s1"]) assert.equal(inAppsMenu(p), false, p);
  assert.deepEqual(RAIL_APP_ITEMS.map((i) => i.label), ["Knowledge", "Library"]);
});

test("the Dev workspace is a tool only while enabled", () => {
  assert.equal(toolItems(false), TOOL_ITEMS);
  assert.deepEqual(toolItems(true), [...TOOL_ITEMS, DEV_TOOL_ITEM]);
});

test("isActive matches the section, and / only itself", () => {
  assert.equal(isActive("/", "/"), true);
  assert.equal(isActive("/spaces", "/"), false);
  assert.equal(isActive("/spaces/abc", "/spaces"), true);
  assert.equal(isActive("/spacesx", "/spaces"), false);
});
