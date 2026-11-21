import test from "node:test";
import assert from "node:assert/strict";
import { buildSavedViewsSection, parseSavedViewCommand, parseSavedViewTitleAction, savedViewMenu, workViewPatch, workViewQuery } from "./models/saved-views.ts";
import { buildTicketsNavModel, parseTicketsRow } from "./models/tickets.ts";
import { buildBoardExtras, buildTicketsListExtras, buildTicketsToolbar, parseBoardToggle, parseTicketsListAction, parseTicketsToolbarAction } from "./models/tickets-toolbar.ts";
import { buildEpicToolbar, buildTicketToolbar, parseTicketToolbarAction } from "./models/work-toolbars.ts";
import { workHeader } from "./models/work.ts";
import { findNavItem } from "./nav-model.ts";

const json = (m) => assert.equal(JSON.stringify(m), JSON.stringify(JSON.parse(JSON.stringify(m))));
const act = (actionId, itemId, menuItemId) => ({ v: 1, type: "nav.action", navigatorId: "tickets", actionId, itemId, menuItemId });

test("saved views: a row per view with a context menu, Save view… on the header", () => {
  const s = buildSavedViewsSection([{ id: "a", name: "Mine", href: "/tickets?sv=a" }, { id: "b", name: "Late" }]);
  assert.equal(s.title, "Saved views");
  assert.deepEqual(s.items.map((i) => [i.id, i.title, i.href]), [["sv:a", "Mine", "/tickets?sv=a"], ["sv:b", "Late", undefined]]);
  assert.deepEqual(s.items[0].contextMenu.map((m) => m.label), ["Rename…", "Save as new view…", "Copy link", undefined, "Delete view"]);
  assert.equal(s.items[0].contextMenu.at(-1).destructive, true);
  assert.deepEqual(s.actions.map((a) => [a.id, a.label]), [["sv.save", "Save view…"]]);
  assert.equal(buildSavedViewsSection([]).emptyText, "No saved views");
  json(s);
});

test("saved views: commands decode to what the screen does", () => {
  assert.deepEqual(parseSavedViewCommand({ v: 1, type: "nav.activate", navigatorId: "tickets", itemId: "sv:a" }), { type: "open", id: "a" });
  assert.equal(parseSavedViewCommand({ v: 1, type: "nav.activate", navigatorId: "tickets", itemId: "queue:all" }), null);
  assert.deepEqual(parseSavedViewCommand(act("sv.save")), { type: "save" });
  assert.deepEqual(parseSavedViewCommand(act("sv.rename", "sv:a")), { type: "rename", id: "a" });
  assert.deepEqual(parseSavedViewCommand(act("sv.save-as", "sv:a")), { type: "saveAs", id: "a" });
  assert.deepEqual(parseSavedViewCommand(act("sv.copy-link", "sv:a")), { type: "copyLink", id: "a" });
  assert.deepEqual(parseSavedViewCommand(act("sv.delete", "sv:a")), { type: "delete", id: "a" });
  assert.equal(parseSavedViewCommand(act("sv.delete")), null);
  assert.equal(parseSavedViewCommand(act("other", "sv:a")), null);
  for (const m of savedViewMenu().filter((m) => !m.separator)) assert.ok(parseSavedViewTitleAction(m.id), m.id);
  assert.equal(parseSavedViewTitleAction("nope"), null);
});

test("saved views: Work's params map to a query and back", () => {
  const params = new URLSearchParams("status=todo&filter_epic=e1&agent=atlas&ticket_view=active&layout=board&project=x");
  const q = workViewQuery(params);
  assert.equal(q, "status=todo&layout=board&epic=e1&assignee=atlas&view=active");
  assert.equal(workViewQuery(new URLSearchParams("")), "view=all");
  const patch = workViewPatch("v1", q);
  assert.deepEqual(patch, {
    saved: "v1", status: "todo", label: null, q: null, filter_epic: "e1", agent: "atlas", ticket_view: "active", ready: null, blocked: null, unestimated: null, layout: "board",
  });
});

const header = { project: "VES", projects: [{ key: "VES", name: "Vesper" }], agents: [], agent: "" };
const counts = { needs_you: 2, in_progress: 0, ready: 3, blocked: 1, all: 9 };

test("tickets list: queues with badges, epics, saved views; the selection follows the open view", () => {
  const input = {
    header: { ...header, hideNewTicket: true, search: { value: "q", placeholder: "Filter tasks…" } },
    counts, queue: "all", epics: [{ id: "e1", name: "Auth", done: 1, total: 4 }],
    views: [{ id: "a", name: "Mine", href: "/tickets?sv=a" }],
  };
  const m = buildTicketsNavModel(input);
  assert.equal(m.id, "tickets");
  assert.deepEqual(m.actions, []);
  assert.equal(m.search.value, "q");
  assert.deepEqual(m.sections.map((s) => s.id), ["queues", "by-epic", "saved-views"]);
  const q = m.sections[0].items;
  assert.deepEqual(q.map((i) => i.badge?.text), ["2", undefined, "3", "1", "9"]);
  assert.equal(q[0].badge.tone, "human");
  assert.deepEqual(m.sections[1].actions.map((a) => a.id), ["tickets.open-epics"]);
  assert.deepEqual(m.sections[1].items[0].contextMenu.map((c) => c.id), ["epic.open-detail"]);
  assert.equal(m.selectedId, "queue:all");
  assert.equal(buildTicketsNavModel({ ...input, queue: null, epic: "e1" }).selectedId, "epic:e1");
  const open = buildTicketsNavModel({ ...input, queue: null, viewId: "a" });
  assert.equal(open.selectedId, "sv:a");
  assert.equal(findNavItem(open, "sv:a").href, "/tickets?sv=a");
  assert.equal(buildTicketsNavModel({ ...input, epics: [] }).sections.some((s) => s.id === "by-epic"), false);
  json(m);
});

test("tickets list: rows decode", () => {
  assert.deepEqual(parseTicketsRow("queue:blocked"), { type: "queue", queue: "blocked" });
  assert.deepEqual(parseTicketsRow("epic:e1"), { type: "epic", id: "e1" });
  assert.equal(parseTicketsRow("sv:a"), null);
});

test("the header keeps New ticket in the sidebar unless the toolbar has it", () => {
  assert.equal(workHeader({ active: "tickets", agent: "" }).actions.length, 1);
  assert.equal(workHeader({ active: "tickets", agent: "", hideNewTicket: true }).actions.length, 0);
});

const space = { label: "Space: Vesper", menu: [{ id: "space:", label: "All spaces" }, { id: "space:VES", label: "Vesper", checked: true }] };

test("tickets toolbar: the project and layout are menus, New ticket is the accent button", () => {
  const items = buildTicketsToolbar({ space, layout: "board", action: { label: "New ticket", primary: true } });
  assert.deepEqual(items.map((i) => [i.id, i.kind, i.placement ?? "trailing"]), [
    ["tickets.space", "menu", "leading"], ["tickets.layout", "menu", "trailing"], ["tickets.action", "button", "trailing"],
  ]);
  assert.equal(items[0].label, "Vesper");
  assert.equal(items[1].label, "Board");
  assert.deepEqual(items[1].menu.map((m) => [m.id, m.checked]), [["layout:list", false], ["layout:board", true]]);
  const onEpics = buildTicketsToolbar({ space, layout: "epics" });
  assert.deepEqual(onEpics[1].menu.map((m) => [m.id, m.checked]), [["layout:list", false], ["layout:board", false], ["layout:epics", true]]);
  assert.equal(items[2].accent, true);
  const archived = buildTicketsToolbar({ space, layout: "list", action: { label: "Open the space", primary: false } });
  assert.equal(archived.at(-1).accent, false);
  assert.equal(buildTicketsToolbar({ space, layout: "list" }).some((i) => i.id === "tickets.action"), false);
  json(items);
});

test("tickets toolbar: the screen's items sit between the project and the layout; presses decode", () => {
  const extra = buildTicketsListExtras({ readyCount: 2, group: "epic", groups: [{ value: "status", label: "Status" }, { value: "epic", label: "Epic" }], density: "compact" });
  assert.deepEqual(extra.map((i) => i.id), ["list.start-ready", "list.group", "list.density"]);
  assert.equal(extra[0].label, "Start ready (2)");
  assert.equal(extra[1].label, "Group: Epic");
  assert.deepEqual(extra[1].menu.map((m) => m.checked), [false, true]);
  assert.deepEqual(extra[2].menu.map((m) => m.checked), [false, true]);
  assert.equal(buildTicketsListExtras({ readyCount: 0, group: "status", groups: [], density: "comfortable" })[0].id, "list.group");
  const ids = buildTicketsToolbar({ space, layout: "list", extra }).map((i) => i.id);
  assert.deepEqual(ids, ["tickets.space", "list.start-ready", "list.group", "list.density", "tickets.layout"]);

  assert.deepEqual(parseTicketsToolbarAction("tickets.space", "space:VES"), { type: "space", menuItemId: "space:VES" });
  assert.deepEqual(parseTicketsToolbarAction("tickets.layout", "layout:epics"), { type: "layout", layout: "epics" });
  assert.equal(parseTicketsToolbarAction("tickets.layout", "layout:nope"), null);
  assert.deepEqual(parseTicketsToolbarAction("tickets.action"), { type: "action" });
  assert.equal(parseTicketsToolbarAction("list.group", "group:epic"), null);
  assert.deepEqual(parseTicketsListAction("list.start-ready"), { type: "startReady" });
  assert.deepEqual(parseTicketsListAction("list.group", "group:epic"), { type: "group", value: "epic" });
  assert.deepEqual(parseTicketsListAction("list.density", "density:compact"), { type: "density", value: "compact" });
  assert.equal(parseTicketsListAction("list.density", "density:huge"), null);
});

test("board toolbar: two toggles carry their state", () => {
  const items = buildBoardExtras({ showCanceled: true, blockedOnly: false });
  assert.deepEqual(items.map((i) => [i.id, i.kind, i.on]), [["board.canceled", "toggle", true], ["board.blocked", "toggle", false]]);
  assert.deepEqual(parseBoardToggle("board.blocked"), { type: "blocked" });
  assert.equal(parseBoardToggle("x"), null);
});

test("ticket toolbar: cost and position when known, prev/next disabled at the ends", () => {
  const items = buildTicketToolbar({ cost: "$1.20", pager: { index: 0, total: 5 }, hasPrev: false, hasNext: true, copied: false });
  assert.deepEqual(items.map((i) => i.id), ["ticket.cost", "ticket.pager", "ticket.prev", "ticket.next", "ticket.copy"]);
  assert.equal(items[1].label, "1 / 5");
  assert.equal(items[1].disabled, true);
  assert.deepEqual(items.slice(2, 4).map((i) => i.disabled), [true, false]);
  const bare = buildTicketToolbar({ pager: { index: -1, total: 0 }, hasPrev: false, hasNext: false, copied: true });
  assert.deepEqual(bare.map((i) => i.id), ["ticket.prev", "ticket.next", "ticket.copy"]);
  assert.equal(bare[2].label, "Link copied");
  assert.equal(parseTicketToolbarAction("ticket.next"), "next");
  assert.equal(parseTicketToolbarAction("ticket.pager"), null);
  json(items);
});

test("epic toolbar", () => {
  assert.deepEqual(buildEpicToolbar().map((i) => i.label), ["View on board"]);
});
