import test from "node:test";
import assert from "node:assert/strict";
import { TABS, badgeLabel, currentTab, hidesTabBar, moreLabel, moreSections } from "./tab-bar.ts";
import { NAV_GROUPS } from "./project-scope.ts";

const counts = { inbox: 0, runs: 0, scheduled: 0, wiki: 0, settings: 0 };

test("the bar has Chat, Needs you, Work and More", () => {
  assert.deepEqual(TABS.map((t) => t.label), ["Chat", "Needs you", "Work", "More"]);
});

test("a path selects its section's tab, and anything else selects More", () => {
  assert.equal(currentTab("/"), "chat");
  assert.equal(currentTab("/chat/abc"), "chat");
  assert.equal(currentTab("/inbox"), "needs");
  assert.equal(currentTab("/runs"), "runs");
  assert.equal(currentTab("/tickets"), "runs");
  assert.equal(currentTab("/more"), "more");
  assert.equal(currentTab("/apps/docs"), "more");
  assert.equal(currentTab("/settings"), "more");
  assert.equal(currentTab("/runsx"), "more");
});

test("run, ticket and epic detail screens hide the bar; their lists keep it", () => {
  assert.equal(hidesTabBar("/runs/123"), true);
  assert.equal(hidesTabBar("/tickets/WEB-3"), true);
  assert.equal(hidesTabBar("/tickets/new"), true);
  assert.equal(hidesTabBar("/runs"), false);
  assert.equal(hidesTabBar("/tickets"), false);
  assert.equal(hidesTabBar("/epics/EP-1"), true);
  assert.equal(hidesTabBar("/work"), false);
  assert.equal(hidesTabBar("/chat/abc"), false);
});

test("counts reach the link name for Inbox and Runs only", () => {
  assert.equal(badgeLabel("Needs you", "inbox", { ...counts, inbox: 3 }), "Needs you 3 waiting");
  assert.equal(badgeLabel("Runs", "runs", { ...counts, runs: 2 }), "Runs 2 running");
  assert.equal(badgeLabel("Inbox", "inbox", counts), "Inbox");
  assert.equal(badgeLabel("Wiki", "wiki", { ...counts, wiki: 1 }), "Wiki");
  assert.equal(badgeLabel("Chat", undefined, counts), "Chat");
});

test("More lists every NAV_GROUPS item the bar has no tab for, in the sidebar's order", () => {
  const tabbed = new Set(TABS.map((t) => t.href));
  const listed = moreSections().flatMap((g) => g.items.map((i) => i.href));
  const expected = NAV_GROUPS.flatMap((g) => g.items).map((i) => i.href).filter((h) => !tabbed.has(h));
  assert.deepEqual(listed, expected);
  // Runs and Tickets are tabs, so Work has nothing left for More.
  assert.deepEqual(moreSections().map((g) => g.label), ["Apps", "Tools", "You"]);
});

test("a new nav item shows up in More", () => {
  const groups = [{ label: "Tools", items: [{ href: "/inbox", label: "Inbox", icon: "inbox" }, { href: "/new", label: "New", icon: "plus" }] }];
  assert.deepEqual(moreSections(groups), [{ label: "Tools", items: [{ href: "/new", label: "New", icon: "plus" }] }]);
});

test("More's badges reach the row's name", () => {
  assert.equal(moreLabel("Wiki", "wiki", { ...counts, wiki: 2 }), "Wiki, 2 suggested edits to review");
  assert.equal(moreLabel("Scheduled", "scheduled", { ...counts, scheduled: 1 }), "Scheduled, 1 needs you");
  assert.equal(moreLabel("Settings", "settings", { ...counts, settings: 1 }), "Settings: a setting runs need is missing");
  assert.equal(moreLabel("Wiki", "wiki", counts), "Wiki");
});
