import test from "node:test";
import assert from "node:assert/strict";
import { buildThreadOutline, filterOutline, outlineCounts } from "./chat-outline.ts";

test("buildThreadOutline indexes bookmarks, links, checklists, diffs, and attachments", () => {
  const items = buildThreadOutline([
    {
      id: "m1",
      role: "user",
      body_md: "Please review https://example.com/spec and check the attached log.",
      bookmarked: true,
      attachments: [{ id: "a1", filename: "crash.log", content_type: "text/plain" }],
    },
    {
      id: "m2",
      role: "assistant",
      persona: { name: "Judy" },
      bookmarked: true,
      checklist_state: { "0": true },
      body_md: [
        "Plan:",
        "- [ ] Patch poll loop",
        "- [ ] Add regression test",
        "",
        "```diff",
        `{"title":"Fix poll loop","before":"a","after":"b"}`,
        "```",
        "",
        "```product",
        `{"items":[{"name":"M5 Dock","url":"https://shop.example/dock"}]}`,
        "```",
        "",
        "Sources:",
        "1. [Go Context Docs](https://pkg.go.dev/context)",
      ].join("\n"),
    },
  ]);

  const counts = outlineCounts(items);
  assert.equal(counts.bookmarks, 2);
  assert.equal(counts.files, 1);
  assert.equal(counts.checklists, 1);
  assert.equal(counts.code, 1);
  assert.equal(counts.links, 3);

  const chk = filterOutline(items, "checklists", "")[0];
  assert.equal(chk.badge, "1/2");
  assert.equal(chk.title, "Patch poll loop");

  const code = filterOutline(items, "code", "poll")[0];
  assert.equal(code.title, "Fix poll loop");
});
