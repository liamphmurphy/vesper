import test from "node:test";
import assert from "node:assert/strict";
import { buildChatTitleMenu, buildChatToolbar, parseChatAction, parseTitleAction } from "./chat-toolbar.ts";

const base = (o = {}) => ({
  origin: "http://localhost:3000",
  archived: false,
  participants: [{ id: "p1", name: "Ada Lovelace", color: "#9b8cff", avatar_url: "/api/v1/personas/p1/avatar?v=2" }],
  personas: [{ id: "p1", name: "Ada Lovelace" }, { id: "p2", name: "Bo" }],
  currentPersonaId: "p1",
  fresh: true,
  personaDisabled: false,
  space: { current: undefined, spaces: [{ id: "s1", name: "Vesper" }], locked: false },
  canvasCount: 0,
  runsActive: 0,
  ...o,
});
const byId = (items, id) => items.find((i) => i.id === id);

test("the persona leads as an avatar menu with the current persona checked", () => {
  const p = byId(buildChatToolbar(base()), "chat.persona");
  assert.equal(p.placement, "leading");
  assert.equal(p.showsLabel, true);
  assert.deepEqual(p.avatar, { initials: "AL", color: "#9b8cff", imageUrl: "http://localhost:3000/api/v1/personas/p1/avatar?v=2" });
  assert.deepEqual(p.menu.filter((m) => m.checked).map((m) => m.id), ["persona:p1"]);
  assert.equal(p.menu.at(-1).id, "persona.manage");
  assert.equal(p.menu[0].disabled, true);
});

test("the built-in Assistant gets its mark; a group lists its participants, disabled", () => {
  const solo = byId(buildChatToolbar(base({ participants: [{ name: "Assistant", color: "var(--accent)" }] })), "chat.persona");
  assert.equal(solo.avatar.imageUrl, "http://localhost:3000/assistant-mark.svg");
  assert.equal(solo.avatar.color, undefined);
  const group = byId(buildChatToolbar(base({ participants: [{ name: "Ada", color: "#111111" }, { name: "Bo", color: "#222222" }] })), "chat.persona");
  assert.equal(group.label, "Ada, Bo");
  assert.ok(group.menu.every((m) => m.disabled));
});

test("with no personas to pick from the pill is a disabled button", () => {
  const p = byId(buildChatToolbar(base({ personas: [] })), "chat.persona");
  assert.equal(p.kind, "button");
  assert.equal(p.disabled, true);
});

test("the space item says + Space until the chat has one, then names it with a check", () => {
  const none = byId(buildChatToolbar(base()), "chat.space");
  assert.equal(none.label, "Space");
  assert.equal(none.icon, "plus");
  assert.deepEqual(none.menu.filter((m) => m.checked).map((m) => m.id), ["space:"]);
  const some = byId(buildChatToolbar(base({ space: { current: { id: "s1", name: "Vesper" }, spaces: [{ id: "s1", name: "Vesper" }], locked: true } })), "chat.space");
  assert.equal(some.label, "Vesper");
  assert.equal(some.disabled, true);
  assert.deepEqual(some.menu.filter((m) => m.checked).map((m) => m.id), ["space:s1"]);
});

const shortName = (u) => u.split("/").slice(-2).join("/");
const same = (a, b) => shortName(a).toLowerCase() === shortName(b).toLowerCase();

test("the repository item appears for a coding persona, checks the current repo and offers the search", () => {
  const repo = { value: "https://github.com/acme/app", pending: "https://github.com/acme/next", choices: [{ url: "https://github.com/acme/app", name: "acme/app" }, { url: "https://github.com/acme/next", name: "acme/next" }], shortName, same, disabled: false };
  assert.equal(byId(buildChatToolbar(base()), "chat.repo"), undefined);
  const r = byId(buildChatToolbar(base({ repo })), "chat.repo");
  assert.equal(r.label, "acme/app → acme/next (next turn)");
  assert.deepEqual(r.menu.filter((m) => m.checked).map((m) => m.id), ["repo:https://github.com/acme/app"]);
  assert.equal(r.menu.at(-1).id, "repo.search");
});

test("playground: start button, then a toggle that shows its state", () => {
  assert.equal(byId(buildChatToolbar(base({ playground: { phase: "start", pending: false } })), "chat.playground").label, "Start playground");
  assert.equal(byId(buildChatToolbar(base({ playground: { phase: "start", pending: true } })), "chat.playground").disabled, true);
  const running = byId(buildChatToolbar(base({ playground: { phase: "panel", state: "running", open: true } })), "chat.playground");
  assert.deepEqual([running.kind, running.label, running.on], ["toggle", "Playground", true]);
  assert.equal(byId(buildChatToolbar(base({ playground: { phase: "panel", state: "failed", open: false } })), "chat.playground").label, "Playground · Failed");
});

test("runs, canvas and restore show only when there is something to show", () => {
  assert.deepEqual(buildChatToolbar(base()).map((i) => i.id), ["chat.persona", "chat.space"]);
  const all = buildChatToolbar(base({ runsActive: 2, canvasCount: 3, archived: true }));
  assert.equal(byId(all, "chat.runs").label, "2 runs active");
  assert.equal(byId(all, "chat.canvas").label, "Canvas 3");
  assert.ok(byId(all, "chat.restore"));
});

test("actions parse back from the ids the builder made", () => {
  assert.deepEqual(parseChatAction("chat.persona", "persona:p2"), { type: "persona", id: "p2" });
  assert.deepEqual(parseChatAction("chat.persona", "persona.manage"), { type: "managePersonas" });
  assert.deepEqual(parseChatAction("chat.space", "space:"), { type: "space", id: "" });
  assert.deepEqual(parseChatAction("chat.repo", "repo:https://github.com/a/b"), { type: "repo", url: "https://github.com/a/b" });
  assert.deepEqual(parseChatAction("chat.repo", "repo.search"), { type: "searchRepos" });
  assert.deepEqual(parseChatAction("chat.playground"), { type: "playground" });
  assert.equal(parseChatAction("chat.persona", "persona.header"), null);
  assert.equal(parseChatAction("other"), null);
});

test("the title menu: rename first (off when archived), then workspace, secrets, email, participants", () => {
  const m = buildChatTitleMenu({ archived: false, workspacePath: "/w/x", canOpenWorkspace: true, secrets: { label: "2 secrets used" }, commitEmail: "a@b.c", participants: ["Ada", "Bo"] });
  assert.deepEqual(m.filter((i) => !i.separator).map((i) => i.id), ["rename", "workspace.copy", "workspace.open", "secrets", "commit-email", "participants", "participant:0", "participant:1"]);
  assert.equal(buildChatTitleMenu({ archived: true, canOpenWorkspace: false, participants: ["Ada"] })[0].disabled, true);
  assert.deepEqual(buildChatTitleMenu({ archived: false, canOpenWorkspace: true, participants: ["Ada"] }).map((i) => i.id), ["rename"]);
  assert.equal(parseTitleAction("workspace.open"), "openWorkspace");
  assert.equal(parseTitleAction("participant:0"), null);
});
