import test from "node:test";
import assert from "node:assert/strict";
import { buildScheduledNavModel } from "./models/scheduled.ts";
import { handleWorkHeaderCommand, workHeader, workTabHref } from "./models/work.ts";
import { buildBoardNavModel } from "./models/board.ts";
import { buildEpicsNavModel } from "./models/epics.ts";
import { buildEpicDetailNavModel } from "./models/epic-detail.ts";
import { projectPickerAction } from "./models/project-picker.ts";
import { knowledgePageActions, KP } from "./models/knowledge-page.ts";
import { splitActions } from "./actions.ts";

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

test("epic detail page lists siblings with the Work header", () => {
  const e = buildEpicDetailNavModel({ project: "VES", projectName: "Vesper", epics: [{ id: "e1", name: "Launch", done: 1, total: 2 }], epicId: "e1" });
  assert.equal(e.sections[0].title, "Vesper");
  assert.deepEqual(e.sections[0].badge, { text: "1" });
  assert.deepEqual(e.sections[0].items[0], { id: "e1", title: "Launch", href: "/epics/e1", trailing: "1/2" });
  assert.equal(e.picker.value, "tickets");
});

test("project picker: All spaces, each active space, then Open or New space", () => {
  const action = projectPickerAction({ projects: projects.filter((x) => !x.archived), current: projects[0] });
  assert.equal(action.label, "Space: Vesper");
  assert.deepEqual(action.menu.map((i) => i.id), ["space:", "sep-all", "space:VES", "sep-open", "space-open"]);
  assert.equal(action.menu.at(-1).label, "Open Vesper");
  assert.equal(projectPickerAction({ projects, current: null }).menu.at(-1).label, "New space");
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
