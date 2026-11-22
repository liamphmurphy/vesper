import { expect, test, type Page, type Route } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { menuResponse } from "./mock-menu";

// LAZYAGENTS-59: namespace tree, page rail, version diff, Pattern and ADR indexes.
type S = components["schemas"];
const stamp = (m: number) => new Date(Date.now() - m * 60_000).toISOString();
const me: S["Actor"] = { type: "user", id: "user", name: "Liam" };
const lead: S["Actor"] = { type: "agent", id: "agent-lead", name: "tech-lead" };
const builder: S["AgentRef"] = { id: "agent-builder", name: "Builder", handle: "builder", color_index: 0 };

const summary = (path: string, i: number): S["WikiPageSummary"] => ({
  id: `page-${i}`, path, title: path.split("/").pop()!, author: me, updated_at: stamp(i), published: true, suggestions: 0,
});
const pages = [
  "Architecture/ADR - Chat sessions", "Architecture/ADR - Push branches",
  "Patterns/Architecture/Branch on purpose", "Patterns/API/Allowlist MCP tools", "Patterns/Go/Wrap errors",
  "agents/builder/Memory", "Payments/Runbook", "Glossary",
].map(summary);
const PATH = "Patterns/Architecture/Branch on purpose";
const page = pages.find((p) => p.path === PATH)!;

const v1 = "Topic: Architecture\nTags: runner, purpose\n\n## When to use\n\nNew run kinds.\n\n## Rule\n\n- Store the purpose.\n";
const v2 = v1.replace("Tags: runner, purpose", "Tags: runner, purpose, mcp");
const v3 = v2 + "- Unknown purposes fail closed.\n";
const versions: S["ArtifactVersion"][] = [
  { id: "ver-3", seq: 3, label: "v3", note: "Add fail-closed rule", created_by: lead, created_at: stamp(120), content: { kind: "markdown", content_type: "text/markdown", size_bytes: v3.length, sections: 2 } },
  { id: "ver-2", seq: 2, label: "v2", note: "Tags", created_by: lead, created_at: stamp(3000), content: { kind: "markdown", content_type: "text/markdown", size_bytes: v2.length, sections: 2 } },
  { id: "ver-1", seq: 1, label: "v1", note: "Proposed", created_by: lead, created_at: stamp(5000), content: { kind: "markdown", content_type: "text/markdown", size_bytes: v1.length, sections: 2 } },
];
const bodies: Record<string, string> = { "ver-1": v1, "ver-2": v2, "ver-3": v3 };
const detail: S["Artifact"] = {
  id: page.id, type: "note", title: page.title, path: PATH, summary: "", author: lead, current_version: versions[0], body_md: v3,
  outline: [
    { id: "s1", level: 2, anchor: "when-to-use", heading: "When to use", citations: 1 },
    { id: "s2", level: 2, anchor: "rule", heading: "Rule", citations: 4 },
  ],
  read_by: [], versions, suggestions: 0, created_at: stamp(5000), updated_at: stamp(120),
  tickets: [{ key: "WEB-8", title: "Runner: run purpose", status: "done", relation: "context" }],
};

const patterns: S["WikiPattern"][] = [
  { title: "Branch on purpose", path: PATH, topic: "Architecture", tags: ["runner", "purpose", "mcp"], summary: "New run kinds.", snippet: "", score: 1 },
  { title: "Allowlist MCP tools", path: "Patterns/API/Allowlist MCP tools", topic: "API", tags: ["mcp", "security"], summary: "Shared MCP servers.", snippet: "", score: 1 },
  { title: "Wrap errors", path: "Patterns/Go/Wrap errors", topic: "Go", tags: ["errors", "context"], summary: "Boundaries.", snippet: "", score: 1 },
];
const adrs: S["WikiADR"][] = [
  { id: "page-0", title: "ADR - Chat sessions", path: pages[0].path, href: "/wiki/Architecture/ADR%20-%20Chat%20sessions", status: "Accepted", state: "accepted",
    date: "2026-11-02", ticket: "WEB-6", updated_at: stamp(10), open_questions: ["Which agent identity chats use ([[WEB-6]]).", "Memory writes.", "Idle TTL."], has_open_questions: true },
  { id: "page-9", title: "ADR - Board", path: "Architecture/ADR - Board", href: "/wiki/Architecture/ADR%20-%20Board", status: "Accepted", state: "accepted",
    updated_at: stamp(15), open_questions: [], has_open_questions: true },
  { id: "page-1", title: "ADR - Push branches", path: pages[1].path, href: "/wiki/Architecture/ADR%20-%20Push%20branches", status: "Accepted", state: "accepted",
    date: "2026-11-01", updated_at: stamp(20), open_questions: [], has_open_questions: false },
  { id: "adr-7", title: "Old storage", display_id: "ADR-007", href: "/artifacts/adr-7", status: "Superseded", state: "superseded", updated_at: stamp(30), open_questions: [], has_open_questions: false },
];

async function installWikiApi(p: Page) {
  const unhandled: string[] = [];
  async function handle(route: Route) {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    const json = (data: unknown, status = 200) => route.fulfill({ status, json: data });
    if (path === "/bootstrap") return json({
      workspace: { id: "workspace", name: "Vesper", slug: "lazyagents" },
      me: { id: "user", name: "Liam", email: "liam@example.com", initials: "LM", role_title: "Owner" },
      users: [], agents: [], epics: [], projects: [], labels: [], counts: { inbox: 0, needs_you: 0, wiki_suggestions: 0, live_agents: 0 },
    } satisfies S["Bootstrap"]);
    if (path === "/runner") return json({ online: true, runners: [], slots: 3, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 } satisfies S["RunnerStatus"]);
    if (path === "/wiki/pages") return json({ pages, suggestions: 0 } satisfies S["WikiTree"]);
    if (path === "/wiki/suggestions") return json({ suggestions: [] });
    if (path === "/wiki/page") {
      if (url.searchParams.get("path")?.toLowerCase() === PATH.toLowerCase()) return json(detail);
      const s = pages.find((x) => x.path.toLowerCase() === url.searchParams.get("path")?.toLowerCase());
      if (s) return json({ ...detail, id: s.id, title: s.title, path: s.path, body_md: `# ${s.title}\n`, versions: [versions[2]], current_version: versions[2], tickets: [], outline: [] });
      return json({ code: "not_found", message: "not found" }, 404);
    }
    if (path === "/wiki/patterns") {
      const tags = url.searchParams.getAll("tag");
      const topic = url.searchParams.get("topic");
      const scoped = patterns.filter((x) => !topic || x.topic === topic);
      const counts = new Map<string, number>();
      for (const x of scoped) for (const t of x.tags) counts.set(t, (counts.get(t) ?? 0) + 1);
      return json({
        patterns: scoped.filter((x) => tags.every((t) => x.tags.includes(t))),
        tags: [...counts].map(([tag, count]) => ({ tag, count })).sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag)),
      });
    }
    if (path === "/wiki/adrs") return json({ adrs });
    if (path === `/wiki/pages/${page.id}/citations`) return json({
      runs: 1, chats: 2,
      citations: [
        { run_id: "run-1", purpose: "ticket", agent: builder, ticket_key: "WEB-9", ticket_title: "MCP allowlist", reads: 3, last_read_at: stamp(60) },
        { run_id: "run-2", purpose: "chat", agent: builder, chat_id: "chat-1", chat_title: "Why are chat runs read-only?", reads: 1, last_read_at: stamp(30) },
        { run_id: "run-3", purpose: "chat", agent: builder, reads: 1, last_read_at: stamp(20) },
      ],
      unlinked: [{ agent: builder, reads: 2, last_read_at: stamp(9000) }],
    } satisfies S["WikiCitations"]);
    if (path.startsWith("/wiki/pages/") && path.endsWith("/citations")) return json({ runs: 0, chats: 0, citations: [], unlinked: [] });
    if (path === "/knowledge/backlinks") return json({
      linked: url.searchParams.get("id") === page.id ? [
        { source_kind: "artifact", source_id: "page-0", source: { kind: "artifact", artifact_type: "note", title: "ADR - Chat sessions", path: pages[0].path, href: adrs[0].href },
          snippets: ["Pattern followed: [[Patterns/Architecture/Branch on purpose]]. The runner switches on purpose."], anchors: ["rule"] },
        { source_kind: "ticket", source_id: "t-9", source: { kind: "ticket", title: "MCP allowlist", display_id: "WEB-9", status: "in_progress", href: "/tickets/WEB-9" }, snippets: ["See [[Branch on purpose]]"] },
        { source_kind: "comment", source_id: "c-1", source: { kind: "comment", title: "Comment on WEB-12", display_id: "WEB-12", href: "/tickets/WEB-12" }, snippets: ["Allowlist per purpose, see [[Branch on purpose]]"] },
      ] : [],
      unlinked: [],
    } satisfies S["Backlinks"]);
    if (path === "/knowledge/graph") return json({ nodes: [], edges: [] });
    if (path === "/knowledge/resolve") return json({ links: [] });
    if (path === "/artifacts" && url.searchParams.get("type") === "report") return json({
      artifacts: [1, 2, 3, 4, 5, 6].map((i) => ({ id: `report-${i}`, type: "report", title: `Report ${i}`, summary: "", author: lead, ticket_count: 0, updated_at: stamp(i * 100),
        content: { kind: "markdown", content_type: "text/markdown", size_bytes: 1, sections: 0 } })),
      counts: { all: 6, note: 0, prd: 0, spec: 0, adr: 0, report: 7, design: 0, mockup: 0 },
    } satisfies S["ArtifactList"]);
    const content = /^\/artifacts\/[^/]+\/versions\/([^/]+)\/content$/.exec(path);
    if (content && bodies[content[1]]) return route.fulfill({ status: 200, contentType: "text/markdown", body: bodies[content[1]] });
    if (path === "/persona-dock") return json({ personas: [], harnesses: [] });
    if (path === "/chat-models") return json([]);
    if (path === "/secrets") return json({ key_configured: true, known: [], secrets: [] });
    const menu = menuResponse(request.method(), path);
    if (menu) return json(menu);
    unhandled.push(`${request.method()} ${path}`);
    return json({ code: "not_found", message: `mock: no handler for ${path}` }, 404);
  }
  await p.addInitScript(() => {
    class FakeEventSource {
      onopen?: () => void;
      constructor() { setTimeout(() => this.onopen?.(), 0); }
      close() {}
    }
    Object.assign(window, { EventSource: FakeEventSource });
  });
  await p.route("**/api/v1/**", handle);
  return { unhandled };
}

const tree = (p: Page) => p.getByRole("navigation", { name: "Wiki pages" });
const folder = (p: Page, name: string) => tree(p).getByRole("button", { name: new RegExp(`^(Expand|Collapse) ${name}$`) });

test("the tree shows namespaces with counts, remembers open folders and highlights the current page", async ({ page: p }) => {
  const api = await installWikiApi(p);
  await p.goto("/wiki");
  for (const [name, n] of [["Architecture", "2"], ["Patterns", "3"], ["Agent memory", "1"], ["Reports", "7"]]) {
    const row = folder(p, name).locator("..");
    await expect(row).toContainText(n);
    await expect(folder(p, name)).toHaveAttribute("aria-expanded", "false");
  }
  await expect(tree(p).getByRole("link", { name: "Runbook" })).toHaveCount(0);
  await expect(folder(p, "Payments")).toBeVisible();
  await expect(folder(p, "Patterns/Architecture")).toHaveCount(0);
  await expect(tree(p).getByRole("link", { name: "Glossary" })).toBeVisible();

  await folder(p, "Patterns").click();
  await expect(folder(p, "Patterns")).toHaveAttribute("aria-expanded", "true");
  await expect(tree(p).getByRole("link", { name: /Pattern index/ })).toHaveAttribute("href", "/wiki?index=patterns");
  await folder(p, "Reports").click();
  await expect(tree(p).getByRole("link", { name: /^Report \d/ })).toHaveCount(5);
  await expect(tree(p).getByRole("link", { name: "All 7 reports →" })).toHaveAttribute("href", "/library?source=projects&type=report");
  await p.reload();
  await expect(folder(p, "Patterns")).toHaveAttribute("aria-expanded", "true");
  await expect(folder(p, "Architecture")).toHaveAttribute("aria-expanded", "false");

  // The current page's folders are forced open and its row is current.
  await p.goto("/wiki/agents/builder/Memory");
  await expect(folder(p, "Agent memory")).toHaveAttribute("aria-expanded", "true");
  await expect(folder(p, "agents/builder")).toHaveAttribute("aria-expanded", "true");
  await expect(folder(p, "agents/builder").locator("..")).toContainText("@builder");
  await expect(tree(p).locator('[aria-current="page"]')).toHaveText("Memory");
  expect(api.unhandled).toEqual([]);
});

test("a page's rail shows tags, backlinks, linked tickets, cited by and history with a diff", async ({ page: p }) => {
  const api = await installWikiApi(p);
  await p.goto(`/wiki/${PATH.split("/").map(encodeURIComponent).join("/")}`);
  await expect(p.getByRole("heading", { level: 1, name: "Branch on purpose" })).toBeVisible();
  await expect(tree(p).locator('[aria-current="page"]')).toHaveText("Branch on purpose");
  const article = p.locator("article");
  await expect(article.getByText("Tags: runner")).toHaveCount(0);
  await expect(article.getByText("Unknown purposes fail closed.")).toBeVisible();

  const rail = p.getByRole("complementary", { name: "Page details" });
  await expect(rail.getByRole("link", { name: "Architecture", exact: true })).toHaveAttribute("href", "/wiki?index=patterns&topic=Architecture");
  await expect(rail.getByRole("link", { name: "#mcp" })).toHaveAttribute("href", "/wiki?index=patterns&tag=mcp");
  await expect(rail.getByText("The runner switches on purpose.")).toBeVisible();
  await expect(rail.getByText("cites #rule")).toBeVisible();
  const tickets = rail.locator("section", { has: p.getByRole("heading", { name: /^Linked tickets/ }) });
  await expect(tickets.getByRole("link")).toHaveText([/WEB-8.*Runner: run purpose.*Done/, /WEB-9.*MCP allowlist.*In progress/, /WEB-12.*Mentioned in a comment/]);
  const cited = rail.locator("section", { has: p.getByRole("heading", { name: /^Cited by/ }) });
  await expect(cited.getByRole("heading")).toHaveText("Cited by 1 run · 2 chats");
  await expect(cited.getByText("Chat · someone else's chat")).toBeVisible();
  await expect(cited.locator('a[href="/runs/run-3"]')).toHaveCount(0);
  await expect(cited.getByRole("link", { name: "WEB-9" })).toHaveAttribute("href", "/runs/run-1");
  await expect(cited.getByRole("link", { name: "Why are chat runs read-only?" })).toHaveAttribute("href", "/chat/chat-1");
  await expect(cited.getByText("2 earlier reads aren't linked to a run.")).toBeVisible();

  const history = rail.locator("section", { has: p.getByRole("heading", { name: /^History/ }) });
  await expect(history.getByText("current")).toBeVisible();
  await history.getByRole("link", { name: "Diff v2 to v3" }).click();
  await expect(p).toHaveURL(/\?compare=v2\.\.v3$/);
  const diff = p.getByRole("region", { name: "Compare versions" });
  await expect(diff.getByText("+1")).toBeVisible();
  await expect(diff.getByText("−0")).toBeVisible();
  await expect(diff.getByText("- Unknown purposes fail closed.")).toBeVisible();
  await diff.getByRole("combobox", { name: "Older version" }).selectOption("v1");
  await expect(p).toHaveURL(/\?compare=v1\.\.v3$/);
  await expect(diff.getByText("Tags: runner, purpose, mcp")).toBeVisible();
  await expect(diff.getByText("+2")).toBeVisible();
  await p.keyboard.press("Escape");
  await expect(p).not.toHaveURL(/compare=/);
  await expect(p.getByRole("region", { name: "Compare versions" })).toHaveCount(0);
  expect(api.unhandled).toEqual([]);
});

test("the Pattern index filters by tag in the URL, and the ADR index shows status and open questions", async ({ page: p }) => {
  const api = await installWikiApi(p);
  await p.goto("/wiki?index=patterns");
  await expect(folder(p, "Patterns")).toHaveAttribute("aria-expanded", "true");
  await expect(tree(p).locator('[aria-current="page"]')).toContainText("Pattern index");
  const list = p.getByRole("listbox", { name: "Patterns" });
  await expect(list.getByRole("option")).toHaveCount(3);
  const tags = p.getByRole("group", { name: "Filter by tag" });
  await tags.getByRole("button", { name: /^mcp/ }).click();
  await expect(p).toHaveURL(/tag=mcp/);
  await expect(list.getByRole("option")).toHaveCount(2);
  await expect(p.getByText(/2 patterns tagged #mcp/)).toBeVisible();
  await tags.getByRole("button", { name: /^runner/ }).click();
  await expect(p).toHaveURL(/tag=mcp&tag=runner/);
  await expect(list.getByRole("option")).toHaveText([/Branch on purpose/]);
  await p.getByRole("group", { name: "Filter by topic" }).getByRole("button", { name: "Go" }).click();
  await expect(p.getByText("No patterns tagged #mcp #runner in Go.")).toBeVisible();
  await p.getByRole("button", { name: "Clear" }).click();
  await expect(p).not.toHaveURL(/tag=/);
  await expect(list.getByRole("option")).toHaveText([/Wrap errors/]);

  await folder(p, "Architecture").click();
  await tree(p).getByRole("link", { name: "ADR index" }).click();
  await expect(p).toHaveURL(/\/wiki\?index=adrs$/);
  await expect(p.getByRole("heading", { level: 1, name: "Architecture decisions" })).toBeVisible();
  await expect(p.getByText("4 ADRs · 2 with open questions")).toBeVisible();
  const adrList = p.getByRole("list", { name: "ADRs" });
  await expect(adrList.locator("> li")).toHaveCount(4);
  // A Status line that says "with open questions" is highlighted even without a list.
  await expect(adrList.locator("> li").nth(1)).toContainText("ADR - Board");
  await expect(adrList.locator("> li").nth(1)).toContainText("Accepted · open questions");
  const first = adrList.locator("> li").first();
  await expect(first).toContainText("Accepted · open questions");
  await expect(first).toContainText("2026-11-02 · WEB-6 · 3 open questions");
  const qs = p.getByRole("list", { name: "Open questions in ADR - Chat sessions" });
  await expect(qs).toContainText("Which agent identity chats use (WEB-6).");
  await expect(qs).not.toContainText("Idle TTL.");
  await qs.getByRole("button", { name: "+ 1 more" }).click();
  await expect(qs).toContainText("Idle TTL.");
  await expect(adrList.locator("> li").nth(3)).toContainText("ADR-007Old storageSuperseded");
  await p.getByRole("group", { name: "Filter ADRs" }).getByRole("button", { name: /^Accepted/ }).click();
  await expect(adrList.getByRole("link")).toHaveText(["ADR - Push branches"]);
  expect(api.unhandled).toEqual([]);
});
