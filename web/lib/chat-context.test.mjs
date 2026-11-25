import test from "node:test";
import assert from "node:assert/strict";
import {
  addChip, attachQuery, chipFromTarget, citationSources, CUSTOM_APP_CONTEXT_MARKER, defaultSavePath, MAX_CONTEXT_REFS, parseAttach,
  removeChip, toContextRefs, typedText, withChatBacklink,
} from "./chat-context.ts";

const page = { kind: "artifact", id: "p1", title: "Plan", artifact_type: "note", path: "Eng/Plan" };
const report = { kind: "artifact", id: "a1", title: "Q3 report", artifact_type: "report" };

test("chips map to context_refs by kind", () => {
  assert.deepEqual(chipFromTarget(page)?.ref, { kind: "page", id: "p1" });
  assert.equal(chipFromTarget(page)?.label, "Eng/Plan");
  assert.deepEqual(chipFromTarget(report)?.ref, { kind: "artifact", id: "a1" });
  assert.deepEqual(chipFromTarget({ kind: "section", id: "a1", anchor: "risks", title: "Risks" })?.ref, { kind: "section", id: "a1", anchor: "risks" });
  assert.equal(chipFromTarget({ kind: "agent", title: "Atlas" }), null);
});

test("add dedupes, remove drops, refs are undefined when empty", () => {
  let chips = [];
  assert.equal(toContextRefs(chips), undefined);
  chips = addChip(chips, chipFromTarget(page));
  chips = addChip(chips, chipFromTarget(page));
  chips = addChip(chips, chipFromTarget(report));
  assert.equal(chips.length, 2);
  assert.deepEqual(toContextRefs(chips), [{ kind: "page", id: "p1" }, { kind: "artifact", id: "a1" }]);
  chips = removeChip(chips, chips[0].key);
  assert.deepEqual(toContextRefs(chips), [{ kind: "artifact", id: "a1" }]);
});

test("chip list is capped at the contract maximum", () => {
  let chips = [];
  for (let i = 0; i < MAX_CONTEXT_REFS + 5; i++) chips = addChip(chips, chipFromTarget({ ...report, id: `a${i}` }));
  assert.equal(chips.length, MAX_CONTEXT_REFS);
});

test("attach query round-trips", () => {
  const q = new URLSearchParams(attachQuery("WEB", { kind: "artifact", id: "a1" }, "Q3 report"));
  assert.equal(q.get("project"), "WEB");
  const chips = parseAttach(q.getAll("attach"), q.get("attach_title"));
  assert.deepEqual(chips.map((c) => c.ref), [{ kind: "artifact", id: "a1" }]);
  assert.equal(chips[0].label, "Q3 report");
  assert.deepEqual(parseAttach(["bogus", "page:", "page:x"]).map((c) => c.ref), [{ kind: "page", id: "x" }]);
});

test("sources dedupe and link to version and section", () => {
  const src = citationSources([
    { target: { ...report, href: "/artifacts/a1" }, artifact_id: "a1", title: "Q3 report", version_id: "v2", version: "v2", section: "risks" },
    { target: { ...report, href: "/artifacts/a1" }, artifact_id: "a1", title: "Q3 report", version_id: "v2", version: "v2", section: "risks" },
    { target: { ...report, href: "/artifacts/a1" }, artifact_id: "a1", title: "Q3 report" },
    { target: { ...page, href: "/wiki/Eng/Plan" }, artifact_id: "p1", path: "Eng/Plan", version_id: "pv1", version: "v1" },
  ]);
  assert.equal(src.length, 3);
  assert.equal(src[0].href, "/artifacts/a1?version=v2#risks");
  assert.equal(src[0].section, "risks");
  assert.equal(src[1].href, "/artifacts/a1");
  assert.equal(src[2].href, "/artifacts/p1?versions=1&version=pv1");
  assert.equal(src[2].label, "Eng/Plan");
  assert.deepEqual(citationSources(undefined), []);
});

test("saved replies end with a link back to the chat", () => {
  assert.equal(withChatBacklink("Hi\n", "c1", "My [chat]"), "Hi\n\n---\n\nSaved from chat [My chat](/chat/c1)\n");
  assert.equal(defaultSavePath("Plan / roadmap"), "Chats/Plan - roadmap");
  assert.equal(defaultSavePath("  "), "Chats/Chat");
});

test("a sent message shows what was typed, not the context a dock appended", () => {
  assert.equal(typedText("Explain this\n\n<!-- vesper:knowledge-context -->\nCurrently viewing Knowledge page [[Reading list]]."), "Explain this");
  assert.equal(typedText(`Is this safe?${CUSTOM_APP_CONTEXT_MARKER}Custom app: Habit Tracker`), "Is this safe?");
  assert.equal(typedText("No context here <!-- not a marker -->"), "No context here <!-- not a marker -->");
});
