import test from "node:test";
import assert from "node:assert/strict";
import { isPageMessage } from "./protocol.ts";
import { buildSpaceInspectorSections } from "./models/space-inspector.ts";
import { buildCustomAppInspectorSections } from "./models/custom-app-inspector.ts";
import {
  buildKnowledgeHistorySections,
  buildKnowledgeLinksSections,
  buildKnowledgeOutlineSections,
} from "./models/knowledge-inspector.ts";
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

test("space, custom-app, knowledge, doc and design inspector models validate", () => {
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
