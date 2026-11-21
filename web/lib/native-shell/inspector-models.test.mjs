import test from "node:test";
import assert from "node:assert/strict";
import { isPageMessage } from "./protocol.ts";
import { buildRunInspectorSections } from "./models/run-inspector.ts";
import { buildTicketInspectorSections } from "./models/ticket-inspector.ts";
import { buildEpicInspectorSections, buildEpicsOverviewInspectorSections } from "./models/epic-inspector.ts";
import { buildSpaceInspectorSections } from "./models/space-inspector.ts";
import { buildWorkflowInspectorSections } from "./models/workflow-inspector.ts";
import { buildCustomAppInspectorSections } from "./models/custom-app-inspector.ts";
import {
  buildKnowledgeHistorySections,
  buildKnowledgeLinksSections,
  buildKnowledgeOutlineSections,
} from "./models/knowledge-inspector.ts";
import { buildChatActivitySections, buildChatItemSections } from "./models/chat-inspector.ts";
import { buildDocReviewInspector } from "./models/doc-inspector.ts";
import { applyDesignInspectorChange, buildDesignInspector, buildDesignReviewInspector } from "./models/design-inspector.ts";
import { makeLayout } from "../designs/layout.ts";

function wrapModel(id, tabId, sections) {
  const model = {
    id,
    open: true,
    activeTabId: tabId,
    tabs: [{ id: tabId, label: id, icon: "sliders", kind: "native", sections }],
  };
  assert.equal(isPageMessage({ v: 1, type: "inspector", model }), true);
  assert.deepEqual(JSON.parse(JSON.stringify(model)), model);
  return model;
}

test("run inspector builds plan, ticket, code, sub-agents, run, usage, and view actions", () => {
  const sections = buildRunInspectorSections({
    plan: [
      { position: 1, text: "Read code", state: "done" },
      { position: 2, text: "Edit views", state: "current" },
    ],
    ticket: {
      key: "VES-10",
      title: "Native inspector",
      statusLabel: "in progress",
      priorityLabel: "high",
      epic: { id: "e1", name: "Mac App", done: 3, total: 5 },
      criteria: [{ id: "c1", position: 1, text: "120Hz toggle", done: true }],
    },
    code: { branch: "feat/inspector", additions: 120, deletions: 14, prNumber: 88, prState: "open", prUrl: "https://github.com/o/r/pull/88" },
    subAgents: [{ id: "r2", agent: "Reviewer", subtitle: "opus · 12s · $0.05", stateTone: "done" }],
    run: {
      id: "r1",
      purpose: "Ticket",
      model: "claude-opus-4-6",
      harness: "claude-code",
      mode: "sandbox",
      started: "5m ago",
      elapsed: "4m 12s",
      cost: "$0.42",
      tokens: "18k · 9 tool calls",
      subRuns: 1,
      slot: "slot-1",
      dispatchedBy: "Liam",
      workspacePath: "/workspace",
    },
    usage: {
      tokensSummary: "12k in · 6k out",
      costSummary: "$0.42",
      cacheSharePct: 75,
      turns: [{ seq: 1, summary: "12k in · 6k out · $0.42" }],
      models: [
        { model: "claude-opus-4-6", summary: "1 run · $0.37" },
        { model: "claude-haiku-4-5", summary: "1 run · $0.05" },
      ],
    },
    viewMode: "graph",
    environmentHref: "/settings/runner?run_id=r1",
    rawLogUrl: "/api/v1/runs/r1/turns/1/log",
  });
  wrapModel("run:r1", "context", sections);
  assert.deepEqual(sections.map((s) => s.id), ["plan", "ticket", "criteria", "code", "sub_agents", "run", "usage", "open"]);
  const graphBtn = sections.at(-1).items[0].actions.find((a) => a.id === "view:graph");
  assert.equal(graphBtn.active, true);

  const withoutChildren = buildRunInspectorSections({
    plan: [],
    subAgents: [],
    run: {
      id: "r2",
      purpose: "Ticket",
      model: "claude-opus-4-6",
      harness: "claude-code",
      mode: "sandbox",
      started: "5m ago",
      elapsed: "1m",
      cost: "$0.10",
      tokens: "1k · 1 tool calls",
      subRuns: 0,
      slot: "slot-1",
    },
    usage: { turns: [], models: [] },
    viewMode: "simple",
    environmentHref: "/settings/runner?run_id=r2",
  });
  assert.equal(withoutChildren.find((s) => s.id === "run").items.some((i) => i.id === "sub_runs"), false);
  assert.deepEqual(
    withoutChildren.find((s) => s.id === "open").items[0].actions.map((a) => a.id),
    ["view:details", "view:files"],
  );
});

test("ticket inspector builds pickers, chips, blockers, runs, code, and backlinks", () => {
  const sections = buildTicketInspectorSections({
    status: "in_progress",
    statusOptions: [{ value: "in_progress", label: "In Progress" }],
    priority: "high",
    priorityOptions: [{ value: "high", label: "High" }],
    assignee: "a1",
    assigneeOptions: [{ value: "", label: "Unassigned" }, { value: "a1", label: "Implementer" }],
    assigneeBadge: { text: "Not dispatched", tone: "human" },
    reviewer: "",
    reviewerOptions: [{ value: "", label: "No reviewer" }],
    epic: "e1",
    epicOptions: [{ value: "", label: "No epic" }, { value: "e1", label: "Mac UI" }],
    spaceName: "Vesper",
    requiresMockup: true,
    estimate: "5",
    estimateOptions: [{ value: "", label: "Unestimated" }, { value: "5", label: "5 pts" }],
    estimateDisabled: false,
    dueDate: "2026-11-30",
    selectedLabels: [{ id: "l1", name: "macos", color: "#0A84FF" }],
    allLabels: [{ id: "l1", name: "macos" }, { id: "l2", name: "ui" }],
    blockedBy: [{ key: "VES-9", title: "Protocol", statusLabel: "Done", statusTone: "done" }],
    blocks: [],
    canEditBlockedBy: true,
    runs: [{ id: "r1", handle: "impl", stateLabel: "Running", stateTone: "done", subtitle: "now", cost: "$0.10" }],
    runsSummary: "1 · $0.10",
    code: { branch: "feat/x", prNumber: 12, prState: "Open", diff: "+10 −2" },
    linkedMentions: [{ id: "artifact:p1", sourceKind: "artifact", sourceId: "p1", title: "Spec", href: "/knowledge/p1" }],
    unlinkedMentions: [{ id: "ticket:VES-8", sourceKind: "ticket", sourceId: "VES-8", title: "Earlier bug" }],
  });
  wrapModel("ticket:VES-10", "properties", sections);
  assert.equal(sections[0].items.find((i) => i.id === "labels").chips.length, 1);
  assert.equal(sections[0].items.find((i) => i.id === "labels").menu[0].checked, true);
  assert.equal(sections.find((s) => s.id === "backlinks").items.length, 2);

  // Empty edge case
  const empty = buildTicketInspectorSections({
    status: "todo",
    statusOptions: [],
    priority: "none",
    priorityOptions: [],
    assignee: "",
    assigneeOptions: [],
    reviewer: "",
    reviewerOptions: [],
    epic: "",
    epicOptions: [],
    spaceName: "Default",
    mockupFromEpic: "Polish",
    requiresMockup: false,
    estimate: "",
    estimateOptions: [],
    estimateDisabled: true,
    dueDate: "",
    selectedLabels: [],
    allLabels: [],
    blockedBy: [],
    blocks: [],
    canEditBlockedBy: false,
    runs: [],
  });
  wrapModel("ticket:empty", "properties", empty);
});

test("epic inspector and overview inspector produce chart and checklist items", () => {
  const detail = buildEpicInspectorSections({
    status: "open",
    pointsDone: 8,
    pointsTotal: 13,
    criteriaDone: 1,
    criteriaTotal: 2,
    criteria: [
      { id: "c1", text: "1. Native split", done: true },
      { id: "c2", text: "2. Unit tests", done: false },
    ],
    canMarkDone: false,
    canToggleStatus: true,
    blockerNote: "1 unchecked criteria",
    ownerName: "Liam",
    schedule: "Nov 1 → Nov 30",
    source: { title: "Native PRD", href: "/knowledge/p1" },
    requiresMockup: false,
    agentHours: "3.5h",
    burnUpPoints: [
      { label: "Nov 1", value: 0, secondary: 13 },
      { label: "Nov 19", value: 8, secondary: 13 },
    ],
    burnUpSummary: "8 / 13 pts (62%)",
  });
  wrapModel("epic:e1", "context", detail);
  assert.equal(detail[2].items[0].kind, "chart");
  assert.equal(detail[2].items[0].points.length, 2);

  const overview = buildEpicsOverviewInspectorSections({
    epicId: "e1",
    name: "Native Inspector",
    projectName: "Vesper",
    healthLabel: "On track",
    healthTone: "done",
    status: "open",
    doneCount: 4,
    totalCount: 6,
    pointsDone: 8,
    pointsTotal: 13,
    ownerName: "Liam",
    targetDate: "Nov 30",
    tickets: [{ key: "VES-1", title: "Split item", statusLabel: "Done", statusTone: "done" }],
  });
  wrapModel("epics:e1", "context", overview);
  assert.equal(overview.length, 2);
});

test("space, workflow, custom-app, knowledge, and chat inspector models validate", () => {
  const space = buildSpaceInspectorSections({
    id: "s1",
    instructions: "Be concise.",
    sourceCount: 1,
    sources: [{ id: "src1", name: "architecture.md", kindLabel: "Note" }],
    inlineUsed: 1200,
    inlineBudget: 40000,
    inlineLabel: "1.2k of 40k inline",
    spaceMemory: true,
    spaceName: "Vesper",
    memoryCount: 2,
    personaId: "",
    personaOptions: [{ value: "", label: "Default persona" }],
    projectName: "Vesper",
    connectorsSummary: "GitHub",
    work: { key: "VES", archived: false, repoName: "liamphmurphy/vesper", branch: "main" },
  });
  wrapModel("space:s1", "about", space);

  const wf = buildWorkflowInspectorSections({
    workflowName: "Map Gen",
    workflowDescription: "Generate D&D map",
    publishedVersion: 2,
    unpublishedChanges: true,
    preview: false,
    selectedNode: { id: "n2", type: "agent", title: "Draft", config: { prompt: "Draw map", check: true, retry_from: "n1" } },
    personaOptions: [{ value: "", label: "The chat’s persona" }],
    rerunnableOptions: [{ value: "", label: "Don’t retry" }],
    parentCheckOptions: [{ value: "", label: "No check" }],
    issues: [{ node: "n2", message: "Needs prompt" }],
  });
  wrapModel("workflow:w1", "details", wf);

  const app = buildCustomAppInspectorSections({
    hasMcpServer: true,
    mcpEntry: "server.ts",
    mcpToolCount: 1,
    mcpTools: [{ name: "list_notes", description: "List notes" }],
    dbSizeLabel: "12 KB",
    schemaCount: 1,
    schemaObjects: [{ type: "table", name: "notes" }],
    capabilities: [
      { key: "vesper.api:read", label: "Vesper API · Read", hint: "GET requests", mode: "allowed" },
      { key: "nix:yt-dlp", label: "Nix · yt-dlp", hint: "Run nixpkgs#yt-dlp in a background tool job", mode: "requires_approval" },
    ],
    mounts: { cookies: "~/cookies.txt" },
    requestedMounts: [{ name: "cookies", description: "YouTube cookies" }],
    toolScope: "app_only",
    versions: [{ seq: 3, authorLabel: "You", age: "2m ago", current: true }],
  });
  wrapModel("custom-app:notes", "permissions", app);

  wrapModel("knowledge:outline", "outline", buildKnowledgeOutlineSections([{ level: 1, text: "Top" }, { level: 2, text: "Sub" }]));
  wrapModel("knowledge:outline-empty", "outline", buildKnowledgeOutlineSections([]));
  wrapModel("knowledge:links", "links", buildKnowledgeLinksSections({
    linked: [{ id: "a1", sourceKind: "artifact", sourceId: "a1", title: "Home", href: "/knowledge/a1" }],
    unlinked: [{ id: "a2", sourceKind: "artifact", sourceId: "a2", title: "Other" }],
  }));
  wrapModel("knowledge:history", "history", buildKnowledgeHistorySections({
    mode: "suggest",
    versions: [{ id: "v1", label: "v1", who: "You", age: "1h ago", current: true }],
  }));

  wrapModel("chat:activity", "activity", buildChatActivitySections({
    modelLabel: "Claude Opus",
    harnessLabel: "claude-code",
    effort: "High",
    costLabel: "$0.15",
    running: true,
    turns: [{ id: "m1", prompt: "Fix animation", meta: "claude-code · Claude Opus", tone: "done" }],
  }));
  wrapModel("chat:item-ticket", "item", buildChatItemSections({
    kind: "ticket",
    key: "VES-1",
    title: "Test",
    statusLabel: "Open",
    priorityLabel: "High",
    criteria: [{ id: "c1", text: "Pass", done: true }],
    href: "/tickets/VES-1",
  }));
  wrapModel("chat:item-run", "item", buildChatItemSections({
    kind: "run",
    id: "r1",
    title: "Run 1",
    plan: [{ position: 1, text: "Step 1", state: "done" }],
    href: "/runs/r1",
  }));
  wrapModel("chat:item-page", "item", buildChatItemSections({
    kind: "page",
    id: "p1",
    title: "Notes",
    path: "Docs/Notes",
    excerpt: "Hello world",
    href: "/knowledge/p1",
  }));

  const docReview = buildDocReviewInspector({
    persona: "Quinn",
    segments: [
      { kind: "same", blocks: ["# Intro"] },
      { kind: "change", id: 0, before: ["Old line"], after: ["New better line"] },
    ],
    changes: [{ kind: "change", id: 0, before: ["Old line"], after: ["New better line"] }],
    decisions: { 0: "accept" },
    left: 0,
    busy: false,
  });
  wrapModel("doc:review", "review", docReview.sections);
  assert.equal(docReview.sections[1].badge?.tone, "done");

  const sampleDesign = {
    schema: 1,
    mode: "dark",
    token_sets: {},
    assets: {},
    pages: [
      {
        id: "p_main",
        name: "Home",
        children: [
          {
            id: "n_frame",
            type: "frame",
            name: "Card",
            x: 10,
            y: 20,
            w: 320,
            h: 200,
            fill: "#15141F",
            children: [
              {
                id: "n_title",
                type: "text",
                name: "Heading",
                x: 16,
                y: 16,
                w: 180,
                h: 28,
                paragraphs: [{ runs: [{ text: "Hello Vesper" }] }],
              },
            ],
          },
          {
            id: "n_frame2",
            type: "frame",
            name: "Second",
            x: 400,
            y: 20,
            w: 320,
            h: 200,
            children: [],
          },
        ],
      },
    ],
    links: [
      {
        id: "k_link1",
        from: "n_frame",
        to: "n_frame2",
        trigger: "click",
        transition: "dissolve",
        duration_ms: 300,
      },
    ],
  };
  const lay = makeLayout(sampleDesign);

  wrapModel(
    "design:empty",
    "design",
    buildDesignInspector({ design: sampleDesign, page: sampleDesign.pages[0], selected: [], lay, tab: "Design", inspectTarget: "css", readOnly: false }).sections,
  );
  const singleDesign = buildDesignInspector({
    design: sampleDesign,
    page: sampleDesign.pages[0],
    selected: ["n_frame"],
    lay,
    tab: "Design",
    inspectTarget: "css",
    readOnly: false,
  });
  wrapModel("design:single", "design", singleDesign.sections);
  wrapModel(
    "design:multi",
    "design",
    buildDesignInspector({ design: sampleDesign, page: sampleDesign.pages[0], selected: ["n_frame", "n_frame2"], lay, tab: "Design", inspectTarget: "css", readOnly: false }).sections,
  );
  wrapModel(
    "design:prototype",
    "design",
    buildDesignInspector({ design: sampleDesign, page: sampleDesign.pages[0], selected: ["n_frame"], lay, tab: "Prototype", inspectTarget: "css", readOnly: false }).sections,
  );
  const inspected = buildDesignInspector({
    design: sampleDesign,
    page: sampleDesign.pages[0],
    selected: ["n_frame"],
    lay,
    tab: "Inspect",
    inspectTarget: "tailwind",
    readOnly: false,
  });
  wrapModel("design:inspect", "design", inspected.sections);
  assert.ok(inspected.sections.some((s) => s.id === "inspect-code"));

  wrapModel(
    "design:review-pre",
    "review",
    buildDesignReviewInspector({ persona: "Quinn", proposalCount: 2, reviewing: false, busy: false }).sections,
  );
  wrapModel(
    "design:review-active",
    "review",
    buildDesignReviewInspector({
      persona: "Quinn",
      proposalCount: 1,
      reviewing: true,
      changes: [{ i: 0, kind: "changed", title: "Update Card", why: "Contrast", op: { op: "set", id: "n_frame", patch: { fill: "#201E2C" } }, page: "p_main", target: "n_frame", needs: [] }],
      decisions: {},
      left: 1,
      busy: false,
    }).sections,
  );

  // applyDesignInspectorChange edits node geometry/style/text and rejects invalid colors cleanly.
  const moved = applyDesignInspectorChange(sampleDesign, ["n_frame"], "node:x", "48");
  assert.equal(moved.pages[0].children[0].x, 48);
  const invalidColor = applyDesignInspectorChange(sampleDesign, ["n_frame"], "node:fill", "not-a-color");
  assert.equal(invalidColor, sampleDesign);
  const recolored = applyDesignInspectorChange(sampleDesign, ["n_frame"], "node:fill", "#abcdef");
  assert.equal(recolored.pages[0].children[0].fill, "#ABCDEF");
  const editedText = applyDesignInspectorChange(sampleDesign, ["n_title"], "node:text", "Updated heading");
  assert.equal(editedText.pages[0].children[0].children[0].paragraphs[0].runs[0].text, "Updated heading");
  const linked = applyDesignInspectorChange(sampleDesign, ["n_frame"], "proto:trigger:k_link1", "hover");
  assert.equal(linked.links[0].trigger, "hover");
});
