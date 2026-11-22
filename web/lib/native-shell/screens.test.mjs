import test from "node:test";
import assert from "node:assert/strict";
import { buildWorkflowsNavModel, buildWorkflowPaletteNavModel } from "./models/workflows.ts";
import { handleWorkHeaderCommand, workHeader, workTabHref } from "./models/work.ts";
import { buildBoardNavModel } from "./models/board.ts";
import { projectPickerAction } from "./models/project-picker.ts";
import { knowledgePageActions, KP } from "./models/knowledge-page.ts";
import { splitActions } from "./actions.ts";

const json = (m) => assert.equal(JSON.stringify(m), JSON.stringify(JSON.parse(JSON.stringify(m))));

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
