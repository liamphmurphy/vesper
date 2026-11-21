import assert from "node:assert/strict";
import test from "node:test";
import {
  buildPersonaPdfPrompt,
  calloutTone,
  DEFAULT_KNOWLEDGE_PRINT_STYLE,
  embedFallbackLabel,
  formatPropertyValue,
  KNOWLEDGE_PRINT_STYLES,
  knowledgePrintHref,
  parseKnowledgePrintStyle,
  prepareKnowledgePrint,
  stripDuplicateLeadingHeading,
  stripObsidianBlockIds,
} from "./knowledge-print.ts";

test("print styles parse safely with clean as default", () => {
  assert.equal(DEFAULT_KNOWLEDGE_PRINT_STYLE, "clean");
  assert.deepEqual(
    KNOWLEDGE_PRINT_STYLES.map((s) => s.id),
    ["clean", "editorial", "compact", "technical"],
  );
  assert.equal(parseKnowledgePrintStyle(undefined), "clean");
  assert.equal(parseKnowledgePrintStyle("unknown"), "clean");
  assert.equal(parseKnowledgePrintStyle(" EDITORIAL "), "editorial");
  assert.equal(parseKnowledgePrintStyle("compact"), "compact");
  assert.equal(parseKnowledgePrintStyle("technical"), "technical");
  assert.equal(knowledgePrintHref("abc-123", "editorial"), "/print/knowledge/abc-123?style=editorial");
});

test("buildPersonaPdfPrompt cites the page path or title and mentions render_pdf", () => {
  assert.equal(
    buildPersonaPdfPrompt({ title: "Handbook", path: "Docs/Handbook" }),
    "Export [[Docs/Handbook]] as a polished, print-ready PDF using render_pdf. ",
  );
  assert.equal(
    buildPersonaPdfPrompt({ title: "Standalone", path: null }),
    "Export [[Standalone]] as a polished, print-ready PDF using render_pdf. ",
  );
});

test("formatPropertyValue cleans wikilinks, arrays, and empty values", () => {
  assert.equal(formatPropertyValue(null), "");
  assert.equal(formatPropertyValue(undefined), "");
  assert.equal(formatPropertyValue("[[People/Ada Lovelace]]"), "Ada Lovelace");
  assert.equal(formatPropertyValue("Lead: [[People/Ada|Ada]] (#ops)"), "Lead: Ada (#ops)");
  assert.equal(formatPropertyValue(["[[Docs/One]]", "[[Docs/Two#Intro|Two]]"]), "One, Two");
  assert.equal(formatPropertyValue(42), "42");
});

test("stripDuplicateLeadingHeading only removes a matching leading H1", () => {
  assert.equal(stripDuplicateLeadingHeading("\n# Architecture Plan\n\nBody text", "architecture plan"), "Body text");
  assert.equal(stripDuplicateLeadingHeading("# Different Title\n\nBody text", "Architecture Plan"), "# Different Title\n\nBody text");
  assert.equal(stripDuplicateLeadingHeading("Intro\n# Architecture Plan\nBody", "Architecture Plan"), "Intro\n# Architecture Plan\nBody");
});

test("stripObsidianBlockIds removes trailing block IDs outside code blocks and spans", () => {
  const input = [
    "Normal paragraph ^block-1",
    "With `inline ^keep-inline` code ^strip-end",
    "Ends with `^keep-in-code`",
    "```md",
    "Inside code fence ^keep-fence",
    "```",
    "~~~",
    "Inside tilde fence ^keep-tilde",
    "~~~",
  ].join("\n");
  assert.equal(
    stripObsidianBlockIds(input),
    [
      "Normal paragraph",
      "With `inline ^keep-inline` code",
      "Ends with `^keep-in-code`",
      "```md",
      "Inside code fence ^keep-fence",
      "```",
      "~~~",
      "Inside tilde fence ^keep-tilde",
      "~~~",
    ].join("\n"),
  );
});

test("embedFallbackLabel strips attachment, library, and design prefixes cleanly", () => {
  assert.equal(embedFallbackLabel("![[attachment:pdf-1/handbook.pdf]]"), "handbook.pdf");
  assert.equal(embedFallbackLabel("![[attachment:img-1/photo.png|Team Photo]]"), "Team Photo");
  assert.equal(embedFallbackLabel("![[Docs/Runbook#Deploy]]"), "Runbook › Deploy");
  assert.equal(embedFallbackLabel("![[design:d1#Home]]"), "d1 › Home");
});

test("calloutTone groups Obsidian callouts into print tones", () => {
  assert.equal(calloutTone("TIP"), "tip");
  assert.equal(calloutTone("warning"), "warning");
  assert.equal(calloutTone("danger"), "danger");
  assert.equal(calloutTone("quote"), "quote");
  assert.equal(calloutTone("note"), "note");
});

test("prepareKnowledgePrint segments callouts, standalone embeds, inline embeds, and code fences", () => {
  const md = [
    "# Runbook",
    "",
    "See `![[literal-in-code.png]]` and inline ![[attachment:img-1/arch.png]] plus ![[Missing/Note]].",
    "",
    "> [!tip]+ Fast path",
    "> First line ^callout-id",
    "> Check ![[attachment:pdf-1/handbook.pdf]]",
    "",
    "![[attachment:pdf-1/handbook.pdf]]",
    "",
    "![[Docs/Overview]]",
    "",
    "```markdown",
    "> [!warning] Literal code callout",
    "![[literal-fence.png]]",
    "```",
  ].join("\n");

  const embeds = [
    {
      ref: "![[attachment:img-1/arch.png]]",
      kind: "image",
      title: "arch.png",
      url: "/api/v1/knowledge/assets/img-1",
      content_type: "image/png",
      available: true,
    },
    {
      ref: "![[attachment:pdf-1/handbook.pdf]]",
      kind: "file",
      title: "handbook.pdf",
      url: "/api/v1/knowledge/assets/pdf-1",
      content_type: "application/pdf",
      available: true,
    },
    {
      ref: "![[Docs/Overview]]",
      kind: "page",
      title: "Overview",
      markdown: "# Overview\n\nSummary line.",
      available: true,
    },
  ];

  const segments = prepareKnowledgePrint(md, "Runbook", embeds);
  assert.equal(segments.length, 5);

  assert.deepEqual(segments[0], {
    kind: "markdown",
    content: "See `![[literal-in-code.png]]` and inline ![arch.png](/api/v1/knowledge/assets/img-1) plus Note.",
  });

  assert.deepEqual(segments[1], {
    kind: "callout",
    calloutType: "tip",
    tone: "tip",
    title: "Fast path",
    body: "First line\nCheck handbook.pdf",
  });

  assert.equal(segments[2].kind, "embed");
  if (segments[2].kind === "embed") {
    assert.equal(segments[2].fallbackLabel, "handbook.pdf");
    assert.equal(segments[2].embed?.content_type, "application/pdf");
  }

  assert.equal(segments[3].kind, "embed");
  if (segments[3].kind === "embed") {
    assert.equal(segments[3].embed?.kind, "page");
    assert.equal(segments[3].embed?.title, "Overview");
  }

  assert.deepEqual(segments[4], {
    kind: "markdown",
    content: "```markdown\n> [!warning] Literal code callout\n![[literal-fence.png]]\n```",
  });
});
