import test from "node:test";
import assert from "node:assert/strict";
import { buildChatsNavModel, chatItem, initials } from "./chats-model.ts";
import { findNavItem, routeNavCommand } from "./nav-model.ts";
import { buildShellModel, protocolArea } from "./shell-model.ts";
import { stripVesperSuffix } from "./title.ts";
import { createNavigatorPublisher } from "./publisher.ts";
import { buildCustomAppCapabilities, buildCustomAppInspectorSections } from "./models/custom-app-inspector.ts";

const NOW = Date.parse("2026-01-02T12:00:00Z");
const chat = (o) => ({ id: "c1", title: "Plan", state: "idle", created_at: "2026-01-02T11:00:00Z", last_message_at: "2026-01-02T11:30:00Z", ...o });

test("initials", () => {
  assert.equal(initials("Ada Lovelace"), "AL");
  assert.equal(initials("assistant"), "A");
  assert.equal(initials("  "), "?");
});

test("a chat row: title, href, persona avatar, age", () => {
  const item = chatItem(chat({ persona: { name: "Ada Lovelace", color: "#9B8CFF", avatar_url: "/api/v1/personas/p/avatar?v=1" } }), null, "http://localhost:8080", NOW);
  assert.deepEqual(item.contextMenu.map((m) => m.id), ["rename", "archive", "sep", "delete"]);
  delete item.contextMenu;
  assert.deepEqual(item, {
    id: "c1",
    title: "Plan",
    href: "/chat/c1",
    avatar: { initials: "AL", color: "#9B8CFF", imageUrl: "http://localhost:8080/api/v1/personas/p/avatar?v=1" },
    trailing: "30m",
  });
});

test("unread becomes a badge, running a status, and the open chat is never unread", () => {
  assert.deepEqual(chatItem(chat({ unread: 3 }), null, undefined, NOW).badge, { text: "3", tone: "human" });
  assert.equal(chatItem(chat({ unread: 3 }), "c1", undefined, NOW).badge, undefined);
  const running = chatItem(chat({ state: "running", unread: 2 }), null, undefined, NOW);
  assert.equal(running.status, "done");
  assert.equal(running.badge, undefined);
  assert.equal(chatItem(chat({ title: "  " }), null, undefined, NOW).title, "New conversation");
});

test("non-literal persona colors are left out", () => {
  const item = chatItem(chat({ persona: { name: "Assistant", color: "var(--accent)" } }), null, undefined, NOW);
  assert.deepEqual(item.avatar, { initials: "A" });
});

test("the Chats model: new chat action, selection, spaces, persona picker", () => {
  const m = buildChatsNavModel({
    chats: [chat(), chat({ id: "c2", title: "Other" })],
    viewedChatId: "c2",
    spaces: [
      { id: "s1", name: "Home", color: "#34D399", chat_count: 4 },
      { id: "s2", name: "Old", work: { archived: true } },
    ],
    personas: { value: "all", options: [{ value: "all", label: "All" }, { value: "p", label: "Ada" }] },
    now: NOW,
  });
  assert.equal(m.id, "chats");
  assert.equal(m.selectedId, "c2");
  assert.deepEqual(m.sections[0].actions, [{ id: "new-chat", label: "New Chat", icon: "compose", showsLabel: true }]);
  assert.deepEqual(m.sections[0].items.map((i) => i.id), ["c1", "c2"]);
  assert.deepEqual(m.sections[1].items.map((i) => [i.id, i.href, i.trailing]), [["space:s1", "/spaces/s1", "4"]]);
  assert.equal(m.picker.value, "all");
  assert.equal(JSON.stringify(m), JSON.stringify(JSON.parse(JSON.stringify(m))));
});

test("on a space page the space is selected; no spaces means no section; no harness drops the action", () => {
  const m = buildChatsNavModel({ chats: [], viewedChatId: null, viewedSpaceId: "s1", spaces: [{ id: "s1", name: "Home" }], newChatDisabled: true });
  assert.equal(m.selectedId, "space:s1");
  assert.equal(m.sections[0].actions, undefined);
  assert.equal(m.picker, undefined);
  assert.equal(buildChatsNavModel({ chats: [], viewedChatId: null }).sections.length, 1);
});

test("nav.activate pushes the item's href; other navigators' commands are ignored", () => {
  const m = buildChatsNavModel({ chats: [chat()], viewedChatId: null, now: NOW });
  const pushed = [];
  const handled = [];
  assert.equal(routeNavCommand(m, { v: 1, type: "nav.activate", navigatorId: "chats", itemId: "c1" }, (h) => pushed.push(h), (c) => handled.push(c.type)), true);
  assert.deepEqual(pushed, ["/chat/c1"]);
  assert.deepEqual(handled, ["nav.activate"]);
  assert.equal(routeNavCommand(m, { v: 1, type: "nav.activate", navigatorId: "runs", itemId: "c1" }, (h) => pushed.push(h)), false);
  assert.equal(routeNavCommand(m, { v: 1, type: "nav.activate", navigatorId: "chats", itemId: "nope" }, (h) => pushed.push(h)), true);
  assert.equal(routeNavCommand(m, { v: 1, type: "command", name: "find" }, (h) => pushed.push(h)), false);
  assert.deepEqual(pushed, ["/chat/c1"]);
});

test("nav.activate with newTab (⌘-click) opens the item's href in a new tab and leaves this one alone", () => {
  const m = buildChatsNavModel({ chats: [chat()], viewedChatId: null, now: NOW });
  const pushed = [];
  const opened = [];
  const handled = [];
  const route = (cmd) => routeNavCommand(m, cmd, (h) => pushed.push(h), (c) => handled.push(c.type), (h) => opened.push(h));
  assert.equal(route({ v: 1, type: "nav.activate", navigatorId: "chats", itemId: "c1", newTab: true }), true);
  assert.deepEqual(opened, ["/chat/c1"]);
  assert.deepEqual(pushed, [], "the current tab stays where it is");
  assert.deepEqual(handled, [], "the screen doesn't treat it as selecting the row");
  // A row with no href has nothing to open, so ⌘-click activates it as a click would.
  const noHref = { ...m, sections: [{ id: "x", items: [{ id: "a", title: "A" }] }] };
  routeNavCommand(noHref, { v: 1, type: "nav.activate", navigatorId: "chats", itemId: "a", newTab: true }, (h) => pushed.push(h), (c) => handled.push(c.type), (h) => opened.push(h));
  assert.deepEqual(handled, ["nav.activate"]);
  assert.deepEqual(opened, ["/chat/c1"]);
});

test("findNavItem looks in children", () => {
  const m = { id: "k", sections: [{ id: "s", items: [{ id: "a", title: "A", children: [{ id: "b", title: "B", href: "/b" }] }] }] };
  assert.equal(findNavItem(m, "b").href, "/b");
  assert.equal(findNavItem(m, "z"), undefined);
});

test("shell model: areas with badge dots, apps, work for runs and tickets", () => {
  const areas = [
    { area: "chat", href: "/chat", label: "Chat", icon: "msg" },
    { area: "work", href: "/work", label: "Work", icon: "tickets", badge: "runs" },
    { area: "knowledge", href: "/knowledge", label: "Knowledge", icon: "wiki", badge: "wiki" },
  ];
  const m = buildShellModel({
    areas,
    counts: { runs: 2, wiki: 0 },
    current: "tickets",
    customApps: [{ slug: "budget", name: "Budget", icon: "dollar" }],
    tools: [{ href: "/workflows", label: "Workflows", icon: "graph" }],
  });
  assert.deepEqual(m.areas.map((a) => [a.id, a.badge]), [["chat", undefined], ["work", { tone: "done" }], ["knowledge", undefined]]);
  assert.deepEqual(m.apps.map((a) => [a.id, a.href]), [["app:budget", "/apps/budget"], ["tool:/workflows", "/workflows"]]);
  assert.equal(m.currentArea, "work");
  assert.equal(protocolArea("runs"), "work");
  assert.equal(protocolArea(null), null);
});

test("stripVesperSuffix", () => {
  assert.equal(stripVesperSuffix("VES-412 · Vesper"), "VES-412");
  assert.equal(stripVesperSuffix("Vesper"), "");
  assert.equal(stripVesperSuffix("Chat"), "Chat");
});

test("the navigator publisher coalesces, dedupes and prefers a screen's model", async () => {
  const sent = [];
  let claimed = false;
  const p = createNavigatorPublisher({ send: (m) => sent.push(m), claimed: () => claimed, delayMs: 5 });
  const wait = () => new Promise((r) => setTimeout(r, 20));
  const chats = { id: "chats", sections: [] };
  const runs = { id: "runs", sections: [] };
  p.setDefault({ id: "x", sections: [] });
  p.setDefault(chats);
  await wait();
  assert.deepEqual(sent, [{ v: 1, type: "navigator", model: chats }]);

  p.setDefault({ ...chats });
  await wait();
  assert.equal(sent.length, 1, "an equal model isn't sent again");

  const screen = Symbol();
  claimed = true;
  p.setScreen(screen, runs);
  await wait();
  assert.equal(sent.at(-1).model.id, "runs");

  p.setScreen(screen, null);
  p.refresh();
  await wait();
  assert.equal(sent.at(-1).model, null, "claimed without a model: the page's fallback column shows it");

  const fb = Symbol();
  p.setFallback(fb, true);
  await wait();
  assert.deepEqual(sent.at(-1), { v: 1, type: "navigatorFallback", active: true });
  p.setFallback(fb, false);
  claimed = false;
  p.refresh();
  await wait();
  assert.deepEqual(sent.slice(-2).map((m) => m.type), ["navigator", "navigatorFallback"]);
  assert.equal(sent.at(-1).active, false);
  assert.equal(sent.at(-2).model.id, "chats");
});

test("buildCustomAppCapabilities surfaces configured API secrets without manifest declaration", () => {
  const caps = buildCustomAppCapabilities({
    connectors: [{ slug: "github", name: "GitHub", toolCount: 12, status: "connected" }],
    secrets: [
      { handle: "youtube-data-api", name: "YouTube Data API", allowedHosts: ["www.googleapis.com"] },
      { handle: "empty-hosts", name: "Empty Hosts", allowedHosts: [] },
    ],
  });

  assert.deepEqual(caps, [
    {
      key: "vesper.api:read",
      label: "Vesper API · Read",
      hint: "GET requests to Vesper REST APIs",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "vesper.api:write",
      label: "Vesper API · Write",
      hint: "POST, PATCH, PUT, DELETE requests to Vesper APIs",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "app.http:outbound",
      label: "Outbound HTTPS",
      hint: "Public HTTPS fetches from the app's MCP server and remote image proxy",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "app.media:download",
      label: "Download videos",
      hint: "Save direct video files into Vesper so they play locally",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "mcp:github:*",
      label: "MCP · GitHub",
      hint: "12 tools · connected",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "secret:youtube-data-api",
      label: "Secret · YouTube Data API",
      hint: "youtube-data-api · www.googleapis.com",
      mode: "denied",
      requested: undefined,
    },
    {
      key: "secret:empty-hosts",
      label: "Secret · Empty Hosts",
      hint: "empty-hosts · authenticated secretFetch calls",
      mode: "denied",
      requested: undefined,
    },
  ]);
});

test("buildCustomAppCapabilities deduplicates requested/granted secrets, keeps unknown secrets, and drops app.sql:*", () => {
  const caps = buildCustomAppCapabilities({
    connectors: [],
    secrets: [{ handle: "youtube-data-api", name: "YouTube Data API", allowedHosts: ["www.googleapis.com"] }],
    requestedCapabilities: {
      "app.sql:read": "allowed",
      "secret:youtube-data-api": "requires_approval",
      "secret:missing-key": "requires_approval",
    },
    grantedCapabilities: {
      "app.sql:read": "allowed",
      "app.sql:write": "allowed",
      "secret:youtube-data-api": "denied",
      "app.http:outbound": "allowed",
    },
  });

  assert.deepEqual(caps.map((c) => c.key), [
    "vesper.api:read",
    "vesper.api:write",
    "app.http:outbound",
    "app.media:download",
    "secret:youtube-data-api",
    "secret:missing-key",
  ]);
  assert.deepEqual(caps[4], {
    key: "secret:youtube-data-api",
    label: "Secret · YouTube Data API",
    hint: "youtube-data-api · www.googleapis.com",
    mode: "denied",
    requested: "requires_approval",
  });
  assert.deepEqual(caps[5], {
    key: "secret:missing-key",
    label: "Secret · missing-key",
    hint: "Authenticated secretFetch calls using this Vesper secret",
    mode: "denied",
    requested: "requires_approval",
  });

  const sections = buildCustomAppInspectorSections({
    hasMcpServer: true,
    mcpEntry: "server.ts",
    mcpToolCount: 1,
    mcpTools: [{ name: "backfill", description: "Backfill catalog" }],
    dbSizeLabel: "64 KB",
    schemaCount: 1,
    schemaObjects: [{ type: "table", name: "items" }],
    capabilities: caps,
    toolScope: "chats",
    versions: [],
  });
  const capSection = sections.find((s) => s.id === "capabilities");
  const ytItem = capSection?.items.find((i) => i.id === "cap:secret:youtube-data-api");
  assert.equal(ytItem?.detail, "youtube-data-api · www.googleapis.com (manifest requests ask)");
});
