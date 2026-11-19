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
    ],
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
});
