import test from "node:test";
import assert from "node:assert/strict";
import { NAV_GROUPS, RAIL_APP_ITEMS, currentProject, hasFilters, inAppsMenu, isActive, pickerHref, projectSection, resolveProject, switchHref, withProject } from "./project-scope.ts";

const web = { key: "WEB", name: "Web app", color: "#6e56cf", archived: false };
const ops = { key: "OPS", name: "Operations", color: "#3e9bff", archived: false };
const old = { key: "OLD", name: "Legacy", color: "#888888", archived: true };
const projects = [web, ops, old];

test("one menu: Work, the Apps flyout's Apps and Tools, and the footer, with unique hrefs", () => {
  const labels = NAV_GROUPS.map((g) => [g.label, g.items.map((i) => i.label)]);
  assert.deepEqual(labels, [
    ["Work", ["Runs", "Tickets"]],
    ["Apps", ["Knowledge", "Finance", "Library"]],
    ["Tools", ["Workflows", "Scheduled", "Learn", "Reports"]],
    ["You", ["Customization", "Settings"]],
  ]);
  const hrefs = NAV_GROUPS.flatMap((g) => g.items.map((i) => i.href));
  assert.equal(new Set(hrefs).size, hrefs.length);
  // Work-mode pages that were merged or cut aren't in the menu.
  for (const gone of ["/dashboard", "/board", "/epics", "/plans", "/artifacts", "/costs", "/agents"]) assert.ok(!hrefs.includes(gone), gone);
});

test("the Apps row is current on any page its flyout opens that has no rail entry of its own", () => {
  for (const p of ["/apps/finance", "/library", "/workflows/1", "/scheduled", "/learn/2"]) assert.equal(inAppsMenu(p), true, p);
  for (const p of ["/", "/chat/1", "/inbox", "/tickets", "/customization"]) assert.equal(inAppsMenu(p), false, p);
  // Knowledge has its own rail entry, which reads as current instead, also for decks' and designs'
  // old addresses, which lead to their Knowledge pages (LAZYAGENTS-212).
  for (const p of ["/knowledge/abc/the-old-harbour", "/apps/designs/d1", "/apps/slides/s1"]) assert.equal(inAppsMenu(p), false, p);
  assert.deepEqual(RAIL_APP_ITEMS.map((i) => i.label), ["Knowledge"]);
});

test("isActive matches the section, and / only itself", () => {
  assert.equal(isActive("/", "/"), true);
  assert.equal(isActive("/tickets", "/"), false);
  assert.equal(isActive("/runs/abc", "/runs"), true);
  assert.equal(isActive("/runsx", "/runs"), false);
});

test("projectSection finds the project route of detail pages", () => {
  assert.equal(projectSection("/tickets"), "/tickets");
  assert.equal(projectSection("/chat/123"), undefined);
  assert.equal(projectSection("/tickets/WEB-1"), "/tickets");
  assert.equal(projectSection("/inbox"), undefined);
  assert.equal(projectSection("/"), undefined);
});

test("withProject only scopes project routes", () => {
  assert.equal(withProject("/tickets", "WEB"), "/tickets?project=WEB");
  assert.equal(withProject("/tickets", null), "/tickets");
  assert.equal(withProject("/runs", "WEB"), "/runs");
});

test("resolveProject reads the URL first, then the remembered project", () => {
  assert.deepEqual(resolveProject("OPS", "WEB", projects), { state: "project", project: ops });
  assert.deepEqual(resolveProject(null, "WEB", projects), { state: "redirect", key: "WEB" });
  assert.deepEqual(resolveProject("", null, projects), { state: "none" });
});

test("resolveProject never resolves archived or unknown projects", () => {
  assert.deepEqual(resolveProject("OLD", "WEB", projects), { state: "unavailable", key: "OLD", archived: old });
  assert.deepEqual(resolveProject("NOPE", "WEB", projects), { state: "unavailable", key: "NOPE", archived: undefined });
  assert.deepEqual(resolveProject(null, "OLD", projects), { state: "none" });
  assert.deepEqual(resolveProject(null, "GONE", projects), { state: "none" });
});

test("switchHref rewrites the current project route and drops project-bound params", () => {
  const q = (s) => new URLSearchParams(s);
  assert.equal(switchHref("/tickets", q("layout=board&project=WEB&epic=e1&assignee=builder&ticket=WEB-1"), "OPS"), "/tickets?layout=board&assignee=builder&project=OPS");
  assert.equal(switchHref("/tickets", q("project=WEB&view=all"), null), "/tickets?view=all");
  assert.equal(switchHref("/plans", q("id=p1&project=WEB"), "OPS"), "/plans?project=OPS");
  assert.equal(switchHref("/chat/123", q("project=WEB"), "OPS"), null);
  assert.equal(switchHref("/tickets/WEB-1", q(""), "OPS"), "/tickets?project=OPS");
  assert.equal(switchHref("/tickets/new", q("project=WEB"), "OPS"), null);
  assert.equal(switchHref("/inbox", q(""), "OPS"), null);
});

test("a page's picker switches project routes, and only changes ?project= elsewhere", () => {
  const q = (s) => new URLSearchParams(s);
  assert.equal(pickerHref("/tickets", q("layout=board&project=WEB&epic=e1"), "OPS"), "/tickets?layout=board&project=OPS");
  assert.equal(pickerHref("/runs", q("tab=costs&range=7&project=WEB"), "OPS"), "/runs?tab=costs&range=7&project=OPS");
  assert.equal(pickerHref("/runs", q("tab=costs&project=WEB"), null), "/runs?tab=costs");
  assert.equal(pickerHref("/tickets/new", q("project=WEB"), "OPS"), null);
});

test("currentProject prefers the URL on project routes and hides archived projects", () => {
  const q = (s) => new URLSearchParams(s);
  assert.equal(currentProject("/tickets", q("layout=board&project=OPS"), "WEB", projects), ops);
  assert.equal(currentProject("/inbox", q("project=OPS"), "WEB", projects), web);
  assert.equal(currentProject("/tickets", q("project=OLD"), "WEB", projects), undefined);
  assert.equal(currentProject("/inbox", q(""), "OLD", projects), undefined);
  assert.equal(currentProject("/inbox", q(""), null, projects), undefined);
  assert.equal(currentProject("/tickets/WEB-1", q(""), "WEB", projects), web);
});

test("cross-project links on optional routes show All projects, bare routes the remembered one", () => {
  const q = (s) => new URLSearchParams(s);
  assert.equal(hasFilters(q("project=WEB")), false);
  assert.equal(hasFilters(q("view=all&assignee=builder")), true);
  assert.equal(currentProject("/tickets", q("view=all&assignee=builder"), "WEB", projects), undefined);
  assert.equal(currentProject("/tickets", q("layout=epics&status=done"), "WEB", projects), undefined);
  assert.equal(currentProject("/tickets", q(""), "WEB", projects), web);
  // Picking a layout isn't a filter: /epics and /board redirect here without a project.
  assert.equal(hasFilters(q("layout=epics")), false);
  assert.equal(hasFilters(q("tab=costs")), false);
  assert.equal(hasFilters(q("source=projects")), false);
  assert.equal(currentProject("/tickets", q("layout=epics"), "WEB", projects), web);
  // The board always needs one project.
  assert.equal(currentProject("/tickets", q("layout=board&epic=e1"), "WEB", projects), web);
});
