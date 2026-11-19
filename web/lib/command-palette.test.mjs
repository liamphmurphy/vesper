import test from "node:test";
import assert from "node:assert/strict";
import {
  KIND_JUMPS,
  appMatches,
  bestOf,
  facets,
  groupChats,
  knowledgeFolder,
  linkFromTarget,
  matchParts,
  matchesWords,
  pageContext,
  pageScope,
  parseFilters,
  parseKnowledgeQuery,
  parseRecent,
  personaMatches,
  plainExcerpt,
  projectOfKey,
  pushRecent,
  rankGroups,
  RECENT_KEY,
  recordRecent,
  removeToken,
  searchKind,
  snippetParts,
  stepChip,
  stepKnowledgeKind,
  ticketKeyFrom,
  typeCounts,
  typeOf,
} from "./command-palette.ts";

test("a typed ticket key is recognised and uppercased", () => {
  assert.equal(ticketKeyFrom("LAZYAGENTS-39"), "LAZYAGENTS-39");
  assert.equal(ticketKeyFrom("  pay-214 "), "PAY-214");
  assert.equal(ticketKeyFrom("PAY-214 deploy"), undefined);
  assert.equal(ticketKeyFrom("deploy"), undefined);
  assert.equal(ticketKeyFrom("-12"), undefined);
});

test("hits land in their type: pages apart from artifacts, personas and agents as people", () => {
  assert.equal(typeOf({ kind: "ticket" }), "ticket");
  assert.equal(typeOf({ kind: "artifact", artifact_type: "note" }), "page");
  assert.equal(typeOf({ kind: "artifact", artifact_type: "adr" }), "artifact");
  assert.equal(typeOf({ kind: "section" }), "artifact");
  assert.equal(typeOf({ kind: "agent" }), "people");
  assert.equal(typeOf({ kind: "persona" }), "people");
  for (const k of ["chat", "run", "epic", "memory", "canvas", "course", "space", "workflow", "library", "scheduled"]) assert.equal(typeOf({ kind: k }), k);
});

test("links use the wiki path for pages and skip targets without an href", () => {
  assert.deepEqual(
    linkFromTarget({ kind: "artifact", artifact_type: "note", id: "1", title: "Runbook", path: "Payments/Runbook", href: "/wiki/Payments/Runbook" }),
    { id: "1", title: "Payments/Runbook", meta: "page", href: "/wiki/Payments/Runbook", kind: "Pages" },
  );
  assert.equal(linkFromTarget({ kind: "ticket", title: "x" }), undefined);
  assert.equal(linkFromTarget({ kind: "ticket", id: "2", title: "x", display_id: "PAY-1", href: "/tickets/PAY-1" }).meta, "PAY-1");
  assert.equal(linkFromTarget({ kind: "space", id: "3", title: "Homelab", href: "/spaces/3" }).kind, "Spaces");
});

test("a type's chip asks the server for that kind alone, unless it spans several", () => {
  assert.equal(searchKind("ticket"), "ticket");
  assert.equal(searchKind("people"), undefined);
  assert.equal(searchKind("app"), undefined);
  assert.equal(searchKind(undefined), undefined);
  assert.deepEqual(typeCounts({ ticket: 30, persona: 1, agent: 2, page: 0 }), { ticket: 30, people: 3 });
});

test("Tab steps All → each chip → All, and Shift+Tab back", () => {
  assert.equal(stepChip(undefined), "ticket");
  assert.equal(stepChip("ticket"), "page");
  assert.equal(stepChip("run"), undefined);
  assert.equal(stepChip(undefined, true), "run");
  // From a type under More, Tab goes on to the first chip.
  assert.equal(stepChip("epic"), "ticket");
});

test("groups are ordered by their best hit, capped, and say how many more matched", () => {
  const groups = [
    { type: "ticket", items: [{ score: 0.4 }, { score: 0.3 }, { score: 0.2 }, { score: 0.2 }] },
    { type: "page", items: [{ score: 0.9 }] },
    { type: "run", items: [] },
    { type: "chat", items: [{ score: 0.9 }, { score: 0.1 }] },
  ];
  const ranked = rankGroups(groups, 3, { ticket: 30, page: 2 });
  assert.deepEqual(ranked.map((g) => g.type), ["page", "chat", "ticket"]);
  assert.deepEqual(ranked.map((g) => [g.items.length, g.total, g.more]), [[1, 2, 1], [2, 2, 0], [3, 30, 27]]);
  assert.deepEqual(bestOf([{ score: 1 }, { score: 3 }, { score: 2 }]), { score: 3 });
  assert.equal(bestOf([]), undefined);
});

test("a chat's title match and its matching messages become one row", () => {
  const chat = ({ target, ...rest }) => ({ target: { kind: "chat", id: "c1", title: "Tailscale ACLs", href: "/chat/c1", ...target }, snippet: "", score: 0.05, ...rest });
  const rows = groupChats([
    chat({ target: { anchor: "m1", href: "/chat/c1?message=m1" }, snippet: "keep the «runner» off", detail: "You", updated_at: "2026-11-14T10:12:00Z" }),
    chat({ score: 1, detail: "Hackerman", updated_at: "2026-11-14T11:00:00Z" }),
    chat({ target: { anchor: "m2", href: "/chat/c1?message=m2" }, detail: "Hackerman" }),
    { target: { kind: "chat", id: "c2", anchor: "m3", title: "Homelab", href: "/chat/c2?message=m3" }, snippet: "x", score: 0.05, detail: "You" },
    { target: { kind: "ticket", id: "t", title: "t", href: "/tickets/T-1" }, snippet: "", score: 2 },
  ]);
  assert.equal(rows.length, 2);
  assert.deepEqual(
    { ...rows[0], messages: rows[0].messages.map((m) => [m.id, m.author]) },
    { id: "c1", title: "Tailscale ACLs", href: "/chat/c1", persona: "Hackerman", at: "2026-11-14T11:00:00Z", score: 1, titled: true, messages: [["m1", "You"], ["m2", "Hackerman"]] },
  );
  // Found only by a message: the row opens the chat, and the person's own words don't name a persona.
  assert.equal(rows[1].href, "/chat/c2");
  assert.equal(rows[1].titled, false);
  assert.equal(rows[1].persona, undefined);
});

test("facets count values, most common first, and skip blanks", () => {
  assert.deepEqual(facets(["todo", "done", "todo", undefined, ""]), [{ value: "todo", count: 2 }, { value: "done", count: 1 }]);
});

test("matchesWords needs every word", () => {
  assert.ok(matchesWords("Switch to PAY · Payments", "switch pay"));
  assert.ok(matchesWords("anything", ""));
  assert.ok(!matchesWords("Switch to PAY · Payments", "switch web"));
});

test("recent items are deduped, newest first and capped", () => {
  const a = { id: "a", title: "A", href: "/a", kind: "Tickets" };
  const b = { id: "b", title: "B", href: "/b", kind: "Pages" };
  assert.deepEqual(pushRecent(pushRecent([a], b), a).map((r) => r.id), ["a", "b"]);
  assert.equal(pushRecent([a, b], { ...a, id: "c", href: "/c" }, 2).length, 2);
  assert.deepEqual(parseRecent(JSON.stringify([a, { id: "x", title: "X", href: "https://evil" }, 3])), [a]);
  assert.deepEqual(parseRecent("{nope"), []);
  assert.deepEqual(parseRecent(null), []);
});

test("page context comes from the route", () => {
  assert.deepEqual(pageContext("/tickets/LAZYAGENTS-39"), { kind: "ticket", key: "LAZYAGENTS-39" });
  assert.equal(pageContext("/tickets/new"), undefined);
  assert.deepEqual(pageContext("/artifacts/01a1b654-610b-7c95-ada1-9120068a5400"), { kind: "artifact", id: "01a1b654-610b-7c95-ada1-9120068a5400" });
  assert.deepEqual(pageContext("/knowledge/01a1b654-610b-7c95-ada1-9120068a5400/my-note"), { kind: "knowledge", id: "01a1b654-610b-7c95-ada1-9120068a5400" });
  assert.deepEqual(pageContext("/wiki/Payments/Rollback%20runbook"), { kind: "wiki", path: "Payments/Rollback runbook" });
  assert.equal(pageContext("/board"), undefined);
  assert.equal(projectOfKey("LAZYAGENTS-39"), "LAZYAGENTS");
});

test("pageScope maps Knowledge, Work views, and app routes to their scoped palette", () => {
  assert.deepEqual(pageScope("/knowledge"), { kind: "knowledge", label: "Knowledge" });
  assert.deepEqual(pageScope("/knowledge/01a1b654-610b-7c95-ada1-9120068a5400"), { kind: "knowledge", label: "Knowledge" });
  assert.deepEqual(pageScope("/knowledge?kind=design"), { kind: "knowledge", label: "Knowledge" });
  assert.deepEqual(pageScope("/wiki/Homelab"), { kind: "knowledge", label: "Knowledge" });
  assert.deepEqual(pageScope("/apps/designs/123"), { kind: "knowledge", label: "Knowledge" });
  assert.deepEqual(pageScope("/apps"), { kind: "type", type: "app", label: "Apps" });
  assert.deepEqual(pageScope("/apps/finance"), { kind: "type", type: "app", label: "Apps" });
  assert.deepEqual(pageScope("/tickets/WEB-1"), { kind: "type", type: "ticket", label: "Tickets" });
  assert.deepEqual(pageScope("/tickets?layout=epics&project=WEB"), { kind: "type", type: "epic", label: "Epics" });
  assert.deepEqual(pageScope("/tickets", "?layout=board&project=WEB"), { kind: "type", type: "ticket", label: "Tickets" });
  assert.deepEqual(pageScope("/board"), { kind: "type", type: "ticket", label: "Tickets" });
  assert.deepEqual(pageScope("/work"), { kind: "type", type: "run", label: "Runs" });
  assert.deepEqual(pageScope("/work", "?view=tickets"), { kind: "type", type: "ticket", label: "Tickets" });
  assert.deepEqual(pageScope("/work", "?view=epics"), { kind: "type", type: "epic", label: "Epics" });
  assert.deepEqual(pageScope("/chat/c1"), { kind: "type", type: "chat", label: "Chats" });
  assert.deepEqual(pageScope("/runs/r1"), { kind: "type", type: "run", label: "Runs" });
  assert.deepEqual(pageScope("/settings", "?section=personas"), { kind: "type", type: "people", label: "People" });
  assert.deepEqual(pageScope("/settings?persona=p1"), { kind: "type", type: "people", label: "People" });
  assert.deepEqual(pageScope("/workflows/w1"), { kind: "type", type: "workflow", label: "Workflows" });
  assert.deepEqual(pageScope("/library"), { kind: "type", type: "library", label: "Library" });
  assert.deepEqual(pageScope("/scheduled"), { kind: "type", type: "scheduled", label: "Scheduled" });
  assert.deepEqual(pageScope("/learn/c1"), { kind: "type", type: "course", label: "Courses" });
  assert.deepEqual(pageScope("/spaces/s1"), { kind: "type", type: "space", label: "Spaces" });
  assert.deepEqual(pageScope("/artifacts/a1"), { kind: "type", type: "artifact", label: "Artifacts" });
  assert.equal(pageScope("/settings"), undefined);
  assert.equal(pageScope("/settings?section=secrets"), undefined);
});

test("Knowledge helpers parse #tag queries, format folders and step kinds", () => {
  assert.deepEqual(parseKnowledgeQuery("  combat notes "), { text: "combat notes", tag: "" });
  assert.deepEqual(parseKnowledgeQuery("  #dnd "), { text: "", tag: "dnd" });
  assert.deepEqual(parseKnowledgeQuery("#"), { text: "", tag: "" });
  assert.equal(knowledgeFolder("Campaign/Sessions/Dawn"), "Campaign / Sessions");
  assert.equal(knowledgeFolder("Readme"), "Top level");
  assert.equal(stepKnowledgeKind(undefined), "document");
  assert.equal(stepKnowledgeKind("document"), "deck");
  assert.equal(stepKnowledgeKind("deck"), "design");
  assert.equal(stepKnowledgeKind("design"), undefined);
  assert.equal(stepKnowledgeKind(undefined, true), "design");
});

test("a bare number is a ticket in the current project", () => {
  assert.equal(ticketKeyFrom("143", "WEB"), "WEB-143");
  assert.equal(ticketKeyFrom("143"), undefined);
  assert.equal(ticketKeyFrom("pay-1", "WEB"), "PAY-1");
});

test("filters come out of the query and unknown tokens stay text", () => {
  const f = parseFilters("is:ticket deploy STATUS:done is:nope");
  assert.deepEqual(f, { text: "deploy is:nope", types: ["ticket"], status: "done", tokens: ["is:ticket", "STATUS:done"] });
  assert.deepEqual(parseFilters("is:agent is:persona x").types, ["people"]);
  assert.deepEqual(parseFilters("is:project pay").types, ["space"]);
  assert.equal(removeToken("is:ticket deploy", "is:ticket"), "deploy");
});

test("@ asks for people and # for tickets", () => {
  assert.deepEqual(parseFilters("@hack"), { text: "hack", types: ["people"], tokens: [] });
  assert.deepEqual(parseFilters("# 214"), { text: "214", types: ["ticket"], tokens: [] });
  assert.deepEqual(parseFilters("mail@home").types, []);
});

test("snippets and titles mark every match", () => {
  assert.deepEqual(snippetParts("a «b» c"), [{ text: "a ", match: false }, { text: "b", match: true }, { text: " c", match: false }]);
  assert.deepEqual(snippetParts("See [[Homelab/Setup|setup]] and [[Notes]], then [[Home"), [{ text: "See setup and Notes, then Home", match: false }]);
  assert.deepEqual(matchParts("Deploy the web", "web deploy").filter((p) => p.match).map((p) => p.text), ["Deploy", "web"]);
  assert.deepEqual(matchParts("a.b", "."), [{ text: "a", match: false }, { text: ".", match: true }, { text: "b", match: false }]);
});

test("opening an item records it as recent, newest first, once per href", () => {
  const m = new Map();
  const store = { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) };
  recordRecent(store, { id: "r1", title: "Search index", href: "/runs/r1", kind: "Runs" });
  recordRecent(store, { id: "p1", title: "Reading list", href: "/knowledge/p1", kind: "Pages" });
  recordRecent(store, { id: "r1", title: "Search index", href: "/runs/r1", kind: "Runs" });
  assert.deepEqual(parseRecent(m.get(RECENT_KEY)).map((r) => r.href), ["/runs/r1", "/knowledge/p1"]);
  // Blocked storage is skipped, not thrown.
  assert.doesNotThrow(() => recordRecent({ getItem: () => { throw new Error("blocked"); }, setItem: () => {} }, { id: "x", title: "x", href: "/x", kind: "Runs" }));
});

test("a typed persona name finds the persona, whole name first, then its start, then a word's start", () => {
  const ps = [{ name: "Health Coach" }, { name: "Laura" }, { name: "Lau" }, { name: "Maya" }];
  assert.deepEqual(personaMatches(ps, "lau").map((p) => p.name), ["Lau", "Laura"]);
  assert.deepEqual(personaMatches(ps, "coach").map((p) => p.name), ["Health Coach"]);
  assert.deepEqual(personaMatches(ps, "hea co").map((p) => p.name), ["Health Coach"]);
  assert.deepEqual(personaMatches(ps, "chat with maya").map((p) => p.name), ["Maya"]);
  assert.deepEqual(personaMatches(ps, "talk to LAURA").map((p) => p.name), ["Laura"]);
  // One letter inside a name isn't a match: it would take the top result from most queries.
  assert.deepEqual(personaMatches(ps, "a"), []);
  assert.deepEqual(personaMatches(ps, "  "), []);
  assert.deepEqual(personaMatches(ps, "chat"), []);
});

test("a typed app name finds the app; app or apps lists them all", () => {
  const apps = [{ label: "Knowledge" }, { label: "Slides" }, { label: "Designs" }];
  assert.deepEqual(appMatches(apps, "sli").map((a) => a.label), ["Slides"]);
  assert.deepEqual(appMatches(apps, "open designs").map((a) => a.label), ["Designs"]);
  assert.deepEqual(appMatches(apps, "go to know").map((a) => a.label), ["Knowledge"]);
  assert.deepEqual(appMatches(apps, "slides app").map((a) => a.label), ["Slides"]);
  assert.equal(appMatches(apps, "apps").length, 3);
  assert.deepEqual(appMatches(apps, "s"), [{ label: "Slides" }]);
  assert.deepEqual(appMatches(apps, "deploy"), []);
  assert.deepEqual(appMatches(apps, ""), []);
});

test("Slides, Designs and Docs still find their start pages in Knowledge, by either name", () => {
  const href = (q) => appMatches(KIND_JUMPS, q).map((a) => a.href);
  assert.deepEqual(href("slides"), ["/knowledge?kind=deck"]);
  assert.deepEqual(href("decks"), ["/knowledge?kind=deck"]);
  assert.deepEqual(href("open designs"), ["/knowledge?kind=design"]);
  assert.deepEqual(href("docs"), ["/knowledge?kind=document"]);
});

test("is:app filters to apps", () => {
  assert.deepEqual(parseFilters("is:app slides").types, ["app"]);
});

test("a preview excerpt is plain text, cut with an ellipsis", () => {
  assert.equal(
    plainExcerpt("---\ntags: [x]\n---\n# Setup\nInstall **Tailscale** via [the docs](https://x) and [[Homelab/Notes|notes]].\n```nix\nfoo\n```\n- done", 200),
    "Setup Install Tailscale via the docs and notes. done",
  );
  assert.equal(plainExcerpt("abcdef", 4), "abc…");
});
