import test from "node:test";
import assert from "node:assert/strict";
import { buildChatsNavModel, chatItem, chatMenu, hitItem } from "./chats-model.ts";

const NOW = Date.parse("2026-01-02T12:00:00Z");
const chat = (o) => ({ id: "c1", title: "Plan", state: "idle", created_at: "2026-01-02T11:00:00Z", last_message_at: "2026-01-02T11:30:00Z", ...o });

test("an active row's menu: rename, archive, delete (destructive)", () => {
  const menu = chatItem(chat(), null, undefined, NOW).contextMenu;
  assert.deepEqual(menu.filter((m) => !m.separator).map((m) => m.id), ["rename", "archive", "delete"]);
  assert.equal(menu.find((m) => m.id === "delete").destructive, true);
});

test("an archived row: restore and delete, opening read-only", () => {
  const item = chatItem(chat(), null, undefined, NOW, true);
  assert.deepEqual(item.contextMenu.filter((m) => !m.separator).map((m) => m.id), ["restore", "delete"]);
  assert.equal(item.href, "/chat/c1?view=archived");
  assert.deepEqual(chatMenu(true), item.contextMenu);
});

test("several personas are listed in the subtitle with failed and temporary", () => {
  assert.equal(chatItem(chat({ participants: [{ name: "Ada" }, { name: "Bo" }] }), null, undefined, NOW).subtitle, "Ada, Bo");
  assert.equal(chatItem(chat({ participants: [{ name: "Ada" }] }), null, undefined, NOW).subtitle, undefined);
  assert.equal(chatItem(chat({ state: "failed", temporary: true, participants: [{ name: "Ada" }, { name: "Bo" }] }), null, undefined, NOW).subtitle, "Failed · Temporary · Ada, Bo");
});

test("the active list groups by day with the new chat action on the first group", () => {
  const m = buildChatsNavModel({ chats: [chat(), chat({ id: "c2", last_message_at: "2025-12-01T00:00:00Z" })], viewedChatId: null, now: NOW });
  assert.deepEqual(m.sections.map((s) => s.title), ["Today", "Earlier"]);
  assert.equal(m.sections[0].actions[0].id, "new-chat");
  assert.equal(m.sections[1].actions, undefined);
  assert.equal(m.search.id, "chat-search");
  assert.deepEqual(m.actions[0].menu.slice(0, 2).map((i) => [i.id, i.checked]), [["view-active", true], ["view-archived", false]]);
});

test("the archived view: one Archived section, the view menu checks Archived", () => {
  const m = buildChatsNavModel({ chats: [chat()], viewedChatId: "c1", view: "archived", now: NOW });
  assert.deepEqual(m.sections.map((s) => s.id), ["chats-archived"]);
  assert.equal(m.sections[0].items[0].href, "/chat/c1?view=archived");
  assert.deepEqual(m.actions[0].menu.slice(0, 2).map((i) => i.checked), [false, true]);
  assert.equal(buildChatsNavModel({ chats: [], viewedChatId: null, view: "archived" }).sections[0].emptyText, "No archived conversations.");
});

test("search results replace the list: hits, states and no match", () => {
  const hit = { message_id: "m1", chat_id: "c9", chat_title: "", role: "assistant", archived: true, persona_name: "Ada", snippet: "a match here" };
  assert.deepEqual(hitItem(hit), { id: "hit:m1", title: "New conversation", subtitle: "a match here", href: "/chat/c9?message=m1", trailing: "Ada", badge: { text: "Archived" } });
  assert.equal(hitItem({ ...hit, role: "user", archived: false }).trailing, "You");
  const ready = buildChatsNavModel({ chats: [chat()], viewedChatId: null, query: "mat", search: { status: "ready", hits: [hit] } });
  assert.deepEqual(ready.sections.map((s) => s.items.map((i) => i.id)), [["hit:m1"]]);
  assert.equal(ready.search.value, "mat");
  const state = (search) => buildChatsNavModel({ chats: [], viewedChatId: null, query: "m", search }).sections[0].emptyText;
  assert.equal(state({ status: "short" }), "Keep typing…");
  assert.equal(state({ status: "pending" }), "Searching…");
  assert.equal(state({ status: "ready", hits: [] }), "No messages match.");
  assert.equal(state({ status: "error", message: "boom" }), "boom");
});

test("a persona-filtered list ends with a row to start another chat with it", () => {
  const m = buildChatsNavModel({ chats: [chat()], viewedChatId: null, filteredTo: { id: "p1", name: "Ada" }, now: NOW });
  assert.deepEqual(m.sections.at(-1).items.at(-1), { id: "start-with:p1", title: "New chat with Ada", icon: "plus" });
});

test("with no spaces the View menu offers New space; once one exists the Spaces header's + takes over", () => {
  const view = (m) => m.actions.find((a) => a.id === "chats-view").menu;
  const none = buildChatsNavModel({ chats: [chat()], viewedChatId: null, now: NOW });
  assert.deepEqual(view(none).filter((m) => !m.separator).map((m) => m.id), ["view-active", "view-archived", "new-space"]);
  const some = buildChatsNavModel({ chats: [chat()], viewedChatId: null, now: NOW, spaces: [{ id: "s1", name: "Home", color: "#34D399" }] });
  assert.deepEqual(view(some).map((m) => m.id), ["view-active", "view-archived"]);
  assert.equal(some.sections.find((s) => s.id === "spaces").actions[0].id, "new-space");
});
