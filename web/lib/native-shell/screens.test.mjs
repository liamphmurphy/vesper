import test from "node:test";
import assert from "node:assert/strict";
import { buildScheduledNavModel } from "./models/scheduled.ts";
import { buildWorkflowsNavModel, buildWorkflowPaletteNavModel } from "./models/workflows.ts";
import { handleWorkHeaderCommand, workHeader, workTabHref } from "./models/work.ts";
import { buildBoardNavModel } from "./models/board.ts";
import { buildEpicsNavModel } from "./models/epics.ts";
import { buildTicketNavModel } from "./models/ticket.ts";
import { buildEpicDetailNavModel } from "./models/epic-detail.ts";
import { buildRunsNavModel } from "./models/runs.ts";
import { buildWikiNavModel } from "./models/wiki.ts";
import { projectPickerAction } from "./models/project-picker.ts";
import { buildKnowledgeNavModel, K } from "./models/knowledge.ts";
import { knowledgePageActions, KP } from "./models/knowledge-page.ts";
import { splitActions } from "./actions.ts";
import { findNavItem } from "./nav-model.ts";

const json = (m) => assert.equal(JSON.stringify(m), JSON.stringify(JSON.parse(JSON.stringify(m))));

test("scheduled: picker carries the counts, rows follow the filter, + creates", () => {
  const all = [
    { id: "a", name: "Brief", enabled: true, schedule: "Daily 08:00" },
    { id: "b", name: "Digest", enabled: false, schedule: "Weekly" },
  ];
  const m = buildScheduledNavModel({ all, filter: "paused", open: "b" });
  assert.deepEqual(m.picker.options.map((o) => o.label), ["All 2", "Active 1", "Paused 1"]);
  assert.deepEqual(m.sections[0].items.map((i) => i.id), ["b"]);
  assert.equal(m.selectedId, "b");
  assert.equal(m.actions[0].id, "new-task");
  assert.equal(buildScheduledNavModel({ all, filter: "all", open: "new" }).selectedId, null);
  assert.equal(buildScheduledNavModel({ all: [], filter: "all", open: null }).sections[0].emptyText, "No scheduled tasks yet");
  assert.equal(m.sections[0].items[0].status, undefined);
  assert.equal(buildScheduledNavModel({ all, filter: "all", open: null }).sections[0].items[0].status, "done");
});

test("workflows list and the node palette", () => {
  const m = buildWorkflowsNavModel({ workflows: [{ id: "w1", name: "Triage", published_version: 2 }, { id: "w2", name: "New", published_version: 0 }], runs: [{ id: "r1", name: "Triage" }] });
  assert.deepEqual(m.sections[0].items.map((i) => [i.href, i.trailing]), [["/workflows/w1", "v2"], ["/workflows/w2", "Draft"]]);
  assert.equal(m.sections[1].items[0].href, "/workflows/runs/r1");
  assert.equal(buildWorkflowsNavModel({ workflows: [], runs: [] }).sections.length, 1);
  const p = buildWorkflowPaletteNavModel({ palette: [{ group: "Steps", items: [{ type: "agent", label: "Agent step" }] }], disabled: true });
  assert.deepEqual(p.sections[0].items[0], { id: "agent", title: "Agent step", icon: "plus", disabled: true });
});

const projects = [{ key: "VES", name: "Vesper" }, { key: "OLD", name: "Old", archived: true }];
const agents = [{ handle: "ada", name: "Ada" }];

test("work header: new ticket, space and persona menus, tab picker with counts, search", () => {
  const h = workHeader({ active: "tickets", project: "VES", projects, agents, agent: "ada", counts: { activity: 3, tickets: 12 }, search: { value: "x", placeholder: "Filter" } });
  assert.deepEqual(h.actions.map((a) => a.id), ["new-ticket"]);
  assert.deepEqual(h.filters.map((f) => f.id), ["filter-space", "filter-agent"]);
  assert.deepEqual(h.filters[0].options.map((o) => [o.value, o.checked]), [["", false], ["VES", true]]);
  assert.deepEqual(h.filters[1].options.map((o) => [o.value, o.checked]), [["", false], ["ada", true]]);
  assert.deepEqual(h.picker.options.map((o) => o.label), ["Runs 3", "Tasks 12"]);
  assert.equal(h.picker.value, "tickets");
  assert.equal(h.search.value, "x");
  assert.deepEqual(workHeader({ active: "tickets", agent: "", allowAllProjects: false, projects }).filters[0].options.map((i) => i.value), ["VES"]);
  assert.deepEqual(workHeader({ active: "tickets", agent: "", noFilters: true }).filters, []);
  assert.equal(workHeader({ active: "tickets", agent: "" }).search, undefined);
});

test("work header commands call the screen's handlers", () => {
  const calls = [];
  const ctx = { project: "VES", push: (h) => calls.push(["push", h]), onProject: (v) => calls.push(["project", v]), onAgent: (v) => calls.push(["agent", v]), onSearch: (v) => calls.push(["search", v]) };
  const nav = (o) => ({ v: 1, navigatorId: "x", ...o });
  assert.ok(handleWorkHeaderCommand(nav({ type: "nav.action", actionId: "new-ticket" }), ctx));
  assert.ok(handleWorkHeaderCommand(nav({ type: "nav.filter", filterId: "filter-space", value: "", checked: true }), ctx));
  assert.ok(handleWorkHeaderCommand(nav({ type: "nav.filter", filterId: "filter-agent", value: "ada", checked: true }), ctx));
  assert.ok(!handleWorkHeaderCommand(nav({ type: "nav.filter", filterId: "other", value: "x", checked: true }), ctx));
  assert.ok(handleWorkHeaderCommand(nav({ type: "nav.picker", pickerId: "work-view", value: "tickets" }), ctx));
  assert.ok(handleWorkHeaderCommand(nav({ type: "nav.search", searchId: "work-search", value: "q" }), ctx));
  assert.ok(!handleWorkHeaderCommand(nav({ type: "nav.activate", itemId: "i" }), ctx));
  assert.deepEqual(calls, [["push", "/tickets/new?project=VES"], ["project", ""], ["agent", "ada"], ["push", "/tickets?project=VES"], ["search", "q"]]);
  assert.equal(workTabHref("activity", "VES"), "/work?project=VES");
  assert.equal(workTabHref("activity"), "/work");
});

test("board: By epic with All epics first, selection follows the epic filter", () => {
  const header = { active: "tickets", project: "VES", projects, agents, agent: "", allowAllProjects: false };
  const m = buildBoardNavModel({ header, epics: [{ id: "e1", name: "Launch" }], epic: "e1" });
  assert.deepEqual(m.sections[0].items.map((i) => i.id), ["all-epics", "epic:e1"]);
  assert.equal(m.selectedId, "epic:e1");
  assert.equal(buildBoardNavModel({ header, epics: [] }).selectedId, "all-epics");
  assert.deepEqual(buildBoardNavModel({ header }).sections, []);
});

test("epics: status and health menus, grouped rows with progress", () => {
  const m = buildEpicsNavModel({
    header: { project: "VES", projects, search: { value: "", placeholder: "Filter epics…" } },
    status: "open",
    counts: { open: 2, done: 1, all: 3 },
    health: "at_risk",
    healthOptions: [{ value: "any", label: "Any" }, { value: "at_risk", label: "At risk" }],
    atRiskCount: 1,
    groups: [{ key: "VES", label: "Vesper", epics: [{ id: "e1", name: "Launch", health: "at_risk", done: 1, total: 4 }] }],
    selectedEpicId: "e1",
  });
  const byId = Object.fromEntries(m.filters.map((f) => [f.id, f]));
  assert.deepEqual(byId["epic-status"].options.map((i) => [i.value, i.label, i.checked]), [["open", "Active epics (2)", true], ["done", "Done (1)", false], ["all", "All epics (3)", false]]);
  assert.deepEqual(byId["epic-health"].options.map((i) => [i.value, i.label, i.checked]), [["any", "Any", false], ["at_risk", "At risk (1)", true]]);
  assert.equal(byId["filter-agent"], undefined);
  assert.deepEqual(m.sections[0].items[0], { id: "e1", title: "Launch", status: "human", trailing: "1/4" });
  assert.equal(m.search.placeholder, "Filter epics…");
  assert.equal(m.selectedId, "e1");
  const empty = buildEpicsNavModel({ header: {}, status: "open", counts: { open: 0, done: 0, all: 0 }, health: "any", healthOptions: [], atRiskCount: 0, groups: [] });
  assert.equal(empty.sections[0].emptyText, "No epics match.");
});

test("ticket and epic detail pages list siblings with the Work header", () => {
  const t = buildTicketNavModel({ project: "VES", siblings: [{ key: "VES-1", title: "A", status: "in_progress" }], statusNames: { in_progress: "In progress" }, ticketKey: "VES-1" });
  assert.deepEqual(t.sections[0].items[0], { id: "VES-1", title: "A", subtitle: "VES-1 · In progress", href: "/tickets/VES-1", status: "accent" });
  assert.equal(t.selectedId, "VES-1");
  assert.deepEqual(t.actions.map((a) => a.id), ["new-ticket"]);
  const e = buildEpicDetailNavModel({ project: "VES", projectName: "Vesper", epics: [{ id: "e1", name: "Launch", done: 1, total: 2 }], epicId: "e1" });
  assert.equal(e.sections[0].title, "Vesper");
  assert.deepEqual(e.sections[0].badge, { text: "1" });
  assert.deepEqual(e.sections[0].items[0], { id: "e1", title: "Launch", href: "/epics/e1", trailing: "1/2" });
  assert.equal(e.picker.value, "tickets");
});

const body = (o = {}) => ({
  needs: [],
  needsLabel: "Needs you",
  groups: [],
  loading: false,
  error: null,
  hasMore: false,
  loadingMore: false,
  emptyText: "No runs",
  ...o,
});
const run = { id: "r1", href: "/runs/r1?agent=ada", title: "Fix bug", subtitle: "VES-1 · Ada", agentName: "Ada", agentColor: "#A3A6FF", trailing: "4m", dot: "running" };

test("runs: status line, filter menu, needs you and groups, selection", () => {
  const m = buildRunsNavModel({
    body: body({
      needs: [{ id: "n1", href: "/runs/r9", title: "Approve", subtitle: "Approval · VES", trailing: "1h", tone: "human" }],
      groups: [{ key: "running", label: "Running", count: 1, runs: [run] }],
      hasMore: true,
    }),
    filters: { project: "VES", hideDone: true, projects, agents },
    search: "bug",
    statusLine: { text: "1 busy · $2 this week", href: "/reports" },
    selectedId: "run:r1",
  });
  assert.deepEqual(m.sections.map((s) => s.id), ["status", "needs-you", "runs-running", "more"]);
  assert.equal(m.sections[1].title, "Needs you");
  assert.deepEqual(m.sections[1].badge, { text: "1" });
  assert.equal(m.sections[2].title, "Running");
  assert.deepEqual(m.sections[2].badge, { text: "1" });
  assert.deepEqual(m.sections[2].items[0], { id: "run:r1", title: "Fix bug", trailing: "4m", href: "/runs/r1?agent=ada", subtitle: "VES-1 · Ada", avatar: { initials: "A", color: "#A3A6FF" }, status: "done" });
  assert.equal(m.sections[3].items[0].id, "load-more");
  assert.equal(m.actions, undefined);
  assert.deepEqual(m.filters.map((f) => f.id), ["run-options", "run-space", "run-agent"]);
  assert.deepEqual(m.filters[0], { id: "run-options", label: "View", icon: "sliders", multiple: true, options: [{ value: "hide-done", label: "Hide done", checked: true }] });
  assert.deepEqual(m.filters[1].options.map((o) => [o.value, o.checked]), [["", false], ["VES", true], ["OLD", false]]);
  assert.equal(m.search.value, "bug");
  assert.equal(m.selectedId, "run:r1");
  json(m);
});

test("runs: loading, error with retry and empty states", () => {
  const f = { hideDone: false, projects: [], agents: [] };
  assert.equal(buildRunsNavModel({ body: body({ loading: true }), filters: f, search: "" }).sections[0].emptyText, "Loading");
  const err = buildRunsNavModel({ body: body({ error: "boom" }), filters: f, search: "" });
  assert.equal(err.sections[0].items[0].id, "retry");
  assert.equal(buildRunsNavModel({ body: body(), filters: f, search: "" }).sections[0].emptyText, "No runs");
});

const page = (id, path, extra = {}) => ({ id, path, title: path.split("/").pop(), suggestions: 0, ...extra });
const folder = (name, path, folders = [], pages = [], pg) => ({ name, path, folders: new Map(folders.map((f) => [f.name.toLowerCase(), f])), pages, page: pg, count: pages.length + folders.reduce((n, f) => n + f.count, 0) });

test("wiki: namespaces with index rows, open state, suggestions, reports, selection", () => {
  const adr = page("1", "Architecture/ADR-1", { suggestions: 2 });
  const arch = folder("Architecture", "Architecture", [], [adr]);
  const other = folder("", "", [folder("Payments", "Payments", [], [page("2", "Payments/Ledger")])], [page("3", "Home")]);
  const m = buildWikiNavModel({
    loaded: true,
    current: "architecture/adr-1",
    architecture: arch,
    memory: folder("", "", [], []),
    other,
    reports: { state: "ready", list: [{ id: "r1", title: "Report", updated_at: "2026-01-02T00:00:00Z", project: { key: "VES" } }], total: 7 },
    open: new Set(["payments"]),
    forced: new Set(["architecture"]),
  });
  const ns = m.sections[0].items;
  assert.deepEqual(ns.map((i) => i.id), ["f:architecture", "f:patterns", "f:agents", "f:ns:reports"]);
  assert.equal(ns[0].expanded, true);
  assert.deepEqual(ns[0].children.map((c) => c.id), ["index:adrs", "p:Architecture/ADR-1"]);
  assert.deepEqual(ns[0].children[1].badge, { text: "2", tone: "human" });
  assert.equal(m.selectedId, "p:Architecture/ADR-1");
  assert.equal(ns[2].children[0].disabled, true);
  assert.equal(ns[3].children.at(-1).title, "All 7 reports →");
  assert.equal(ns[3].children[0].href, "/artifacts/r1");
  const payments = m.sections[1].items.find((i) => i.id === "f:payments");
  assert.equal(payments.expanded, true);
  assert.equal(payments.trailing, "1");
  assert.equal(m.sections[1].items.at(-1).href, "/wiki/Home");
  assert.equal(buildWikiNavModel({ loaded: false, current: "", memory: other, other, reports: { state: "loading", list: [], total: 0 }, open: new Set(), forced: new Set() }).sections[0].emptyText, "Loading");
  json(m);
});

test("project picker: All spaces, each active space, then Open or New space", () => {
  const action = projectPickerAction({ projects: projects.filter((x) => !x.archived), current: projects[0] });
  assert.equal(action.label, "Space: Vesper");
  assert.deepEqual(action.menu.map((i) => i.id), ["space:", "sep-all", "space:VES", "sep-open", "space-open"]);
  assert.equal(action.menu.at(-1).label, "Open Vesper");
  assert.equal(projectPickerAction({ projects, current: null }).menu.at(-1).label, "New space");
});

const kpage = (id, path, extra = {}) => ({ id, path, title: path.split("/").pop(), ...extra });
const kfolder = (name, path, folders = [], pages = []) => ({ name, path, folders, pages, count: pages.length + folders.reduce((n, f) => n + f.count, 0) });

test("knowledge: header actions, + menu, view picker, tree with menus, quick entries", () => {
  const many = Array.from({ length: 10 }, (_, i) => kpage(`p${i}`, `Notes/Note ${i}`));
  const tree = kfolder("", "", [kfolder("Notes", "Notes", [], many), kfolder("Inbox", "Inbox", [], [kpage("i1", "Inbox/Idea", { pending: 1 })])], [kpage("t1", "Top")]);
  const base = {
    view: "yours",
    loading: false,
    tree,
    pinned: [many[0]],
    pinnedIds: ["p0"],
    activeId: "p9",
    open: new Set(["Notes"]),
    showAll: new Set(),
    pageHref: (p) => `/knowledge/${p.id}`,
    pageIcon: () => "artifacts",
    deckStarters: [{ key: "pitch", name: "Pitch", slide_count: 8 }],
    designStarters: [{ key: "blank", label: "Blank" }],
  };
  const m = buildKnowledgeNavModel(base);
  assert.deepEqual(m.actions.map((a) => a.id), ["search", "graph", "connect", "collapse-all", "new"]);
  const menu = m.actions[4].menu;
  assert.deepEqual(menu.filter((i) => !i.separator).map((i) => i.id), ["new:doc", "deck", "design", "new:folder"]);
  assert.deepEqual(menu[1].children.map((c) => c.id), ["new:deck:blank", "new:deck:pitch"]);
  assert.equal(m.picker.value, "yours");
  assert.deepEqual(m.sections.map((s) => s.id), ["home", "pinned", "tree", "quick"]);
  const section = (model, id) => model.sections.find((s) => s.id === id);
  assert.deepEqual(section(m, "home").items, [{ id: "home", title: "Home", icon: "home", href: "/knowledge" }], "Home leads the list: the Mac app has no tab strip");
  assert.equal(section(m, "pinned").items[0].id, "pin:p0");
  assert.equal(section(m, "pinned").items[0].contextMenu.find((i) => i.id === "pin").label, "Unpin");
  assert.equal(section(m, "pinned").items[0].contextMenu[0].id, K.openNewTab, "a page row opens in a new tab first, as Finder's and Safari's do");
  const items = section(m, "tree").items;
  assert.equal(items[0].id, "f:Inbox", "Inbox heads the tree");
  assert.deepEqual(items[0].badge, { text: "1", tone: "accent" });
  assert.equal(items[0].children[0].status, "human");
  const notes = items[1];
  assert.equal(notes.expanded, true);
  assert.equal(notes.children.length, 10, "8 pages, the open one past the cut, and + more");
  assert.equal(notes.children.at(-1).title, "+ 1 more");
  assert.ok(notes.children.some((c) => c.id === "p:p9"));
  assert.deepEqual(notes.contextMenu.map((i) => i.id).filter((i) => !i.startsWith("s")), ["ask", "new-page", "new-folder", "rename", "move", "delete"]);
  assert.equal(items[2].href, "/knowledge/t1");
  assert.equal(m.selectedId, "p:p9");
  assert.deepEqual(section(m, "quick").items.map((i) => i.id), ["today", "capture", "import"]);
  const all = buildKnowledgeNavModel({ ...base, showAll: new Set(["Notes"]) });
  assert.equal(section(all, "tree").items[1].children.length, 10);
  assert.equal(section(buildKnowledgeNavModel({ ...base, loading: true }), "loading").emptyText, "Loading");
  assert.match(section(buildKnowledgeNavModel({ ...base, tree: kfolder("", ""), pinned: [], view: "agent" }), "empty").emptyText, /No agent knowledge/);
  assert.equal(buildKnowledgeNavModel({ ...base, activeId: undefined, home: true }).selectedId, "home", "Home is selected while it shows");
  assert.equal(buildKnowledgeNavModel({ ...base, activeId: undefined }).selectedId, null);
  assert.equal(K.folder("a/b"), "f:a/b");
  json(m);
});

test("knowledge page: audience, persona mode, copy link and More as toolbar items that run their handlers", () => {
  const calls = [];
  const input = {
    audience: "private",
    setAudience: (a) => calls.push(`audience:${a}`),
    mode: { label: "Meow suggests changes", avatar: { initials: "M" }, open: () => calls.push("mode") },
    copyLink: () => calls.push("copy"),
    exportMarkdown: () => calls.push("export"),
    print: (style) => calls.push(`print:${style}`),
    askPersonaPdf: () => calls.push("ask-persona-pdf"),
    history: () => calls.push("history"),
  };
  const { items, dispatch } = splitActions(knowledgePageActions(input));
  assert.deepEqual(items.map((i) => i.id), [KP.audience, KP.mode, KP.copyLink, KP.more]);
  const audience = items[0];
  assert.equal(audience.label, "Private");
  assert.equal(audience.icon, "lock");
  assert.deepEqual(audience.menu.map((m) => [m.id, !!m.checked, !!m.disabled]), [
    ["audience:private", true, false],
    ["audience:shared", false, false],
    ["audience:agent", false, true],
  ]);
  assert.deepEqual(items[1].avatar, { initials: "M" });
  assert.equal(items[1].showsLabel, true);
  assert.deepEqual(items[3].menu.map((m) => m.id), ["export-md", "print", "history"]);
  assert.deepEqual(
    items[3].menu[1].children.map((c) => (c.separator ? "---" : c.id)),
    ["print:clean", "print:editorial", "print:compact", "print:technical", "---", "print:ask-persona"],
  );
  json(items);

  dispatch(KP.audience, KP.audienceOption("shared"));
  dispatch(KP.audience, KP.audienceOption("private")); // already the audience: nothing to save
  dispatch(KP.audience, KP.audienceOption("agent")); // only agents' own pages are Agent
  dispatch(KP.mode);
  dispatch(KP.copyLink);
  for (const id of [
    "export-md",
    "print:clean",
    "print:editorial",
    "print:compact",
    "print:technical",
    "print:ask-persona",
    "history",
  ]) {
    dispatch(KP.more, id);
  }
  assert.deepEqual(calls, [
    "audience:shared",
    "mode",
    "copy",
    "export",
    "print:clean",
    "print:editorial",
    "print:compact",
    "print:technical",
    "ask-persona-pdf",
    "history",
  ]);

  const agentPage = splitActions(knowledgePageActions({ ...input, audience: "agent", mode: { ...input.mode, avatar: undefined } })).items;
  assert.equal(agentPage[0].label, "Agent");
  assert.equal(agentPage[1].icon, "agents", "no face yet: the agents icon stands in");
});

test("findNavItem still finds nested wiki rows", () => {
  const m = buildWikiNavModel({ loaded: true, current: "", architecture: folder("Architecture", "Architecture", [], [page("1", "Architecture/A")]), memory: folder("", "", [], []), other: folder("", "", [], []), reports: { state: "ready", list: [], total: 0 }, open: new Set(), forced: new Set() });
  assert.equal(findNavItem(m, "p:Architecture/A").href, "/wiki/Architecture/A");
});
