import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";

// LAZYAGENTS-47: the setup checklist and the health banners, on Settings now that the Dashboard is gone.
type S = components["schemas"];

const project: S["Project"] = { id: "project-web", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
const atlas: S["AgentRef"] = { id: "aaaaaaaa-0000-4000-8000-000000000001", name: "Atlas", handle: "atlas", color_index: 0 };
const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();

const inboxItem = (id: string, kind: S["InboxItem"]["kind"], key: string, min: number): S["InboxItem"] => ({
  id, kind, title: `${kind} on ${key}`, summary: "", href: `/tickets/${key}`, ticket_key: key, project: "WEB", created_at: minutesAgo(min), resolved: false, read: false, needs_you: true,
});

const run = (id: string, purpose: S["Run"]["purpose"], state: S["Run"]["state"], extra: Partial<S["Run"]> = {}): S["Run"] => ({
  id, ticket_key: "", purpose, agent: atlas, mode: "managed", state, harness: "claude-code", model: "opus", started_at: minutesAgo(12),
  tool_calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0.84, cost_source: "harness", plan: [], approval_scopes: [], scopes: [], ...extra,
});

const epic = (name: string, health: S["Epic"]["health"]): S["Epic"] => ({
  id: `epic-${name}`, project_id: project.id, name, health, requires_mockup: false, status: "open",
  criteria_total: 0, criteria_done: 0, points_total: 106, points_done: 44, tickets_total: 20, tickets_open: 11,
});

type State = { runner: boolean; runnerStarting?: boolean; runs: S["Run"][]; harness: boolean; repo: boolean; plans: number };

async function installSetupApi(page: Page, init: Partial<State> = {}) {
  const state: State = {
    runner: true,
    harness: true,
    repo: true,
    plans: 1,
    runs: [
      run("r-ticket", "ticket", "running", {
        ticket_key: "WEB-48", work_title: "API",
        plan: [{ position: 1, text: "Read", state: "done" }, { position: 2, text: "Implement API", state: "current" }, { position: 3, text: "Test", state: "pending" }, { position: 4, text: "Ship", state: "pending" }],
      }),
      run("r-plan", "planning", "waiting", { work_title: "Q4 plan" }),
      run("r-chat-waiting", "chat", "waiting", { work_title: "Design review" }),
      run("r-chat-busy", "chat", "running", { work_title: "Sprint planning" }),
    ],
    ...init,
  };
  const requests: string[] = [];
  await page.addInitScript(() => {
    const w = window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> };
    w.__sse = [];
    class FakeEventSource {
      onopen?: () => void;
      onerror?: () => void;
      onmessage?: (e: { data: string }) => void;
      constructor() {
        w.__sse.push(this);
        setTimeout(() => this.onopen?.(), 0);
      }
      close() {
        w.__sse = w.__sse.filter((x) => x !== this);
      }
    }
    (window as unknown as { EventSource: unknown }).EventSource = FakeEventSource;
  });
  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    requests.push(`${path}${url.search}`);
    const json = (data: unknown, status = 200) => route.fulfill({ status, json: data });
    if (path === "/bootstrap") return json({
      workspace: { id: "workspace", name: "Vesper", slug: "lazyagents" },
      me: { id: "user", name: "Liam", email: "liam@example.com", initials: "LM", role_title: "Owner" },
      users: [], agents: [{ ...atlas, kind: "main", role: "Tech lead", specialty: "", model: "opus", status: "running" }],
      epics: [epic("Refresh", "at_risk"), epic("Healthy", "on_track")], projects: [state.repo ? { ...project, repo_url: "git@github.com:acme/web.git" } : project], labels: [],
      counts: { inbox: 6, needs_you: 6, wiki_suggestions: 0, live_agents: 1 },
    });
    if (path === "/runner") return json(state.runner
      ? { online: true, runners: [{ id: "mbp", backend: "microvm", max_concurrent: 4, running: 0, heartbeat_at: minutesAgo(0) }], slots: 4, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 }
      : { online: false, ...(state.runnerStarting ? { starting: true } : {}), runners: [], slots: 0, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 });
    if (path === "/chat-models") return json([
      { harness: "claude-code", label: "Claude Code", available: state.harness, ...(state.harness ? {} : { unavailable_reason: "no harness:anthropic secret" }), models: [{ id: "opus", label: "Opus", default: true }] },
      { harness: "codex", label: "Codex", available: false, unavailable_reason: "no harness:openai secret", models: [{ id: "gpt-5-codex", label: "gpt-5-codex", default: true }] },
    ]);
    if (path === "/secrets") return json({ secrets: [], key_configured: true, known: [] });
    if (path === "/personas" && request.method() === "GET") return json({ personas: [] });
    if (path === "/memories" && request.method() === "GET") return json({ memories: [], total: 0, has_more: false });
    if (path === "/planning-sessions") return json(Array.from({ length: state.plans }, (_, i) => ({ id: `plan-${i}`, project: "WEB" })));
    if (path === "/inbox") return json({ items: [
      inboxItem("m1", "mention", "WEB-40", 500), inboxItem("r1", "review", "WEB-41", 10), inboxItem("a1", "approval", "WEB-44", 5),
      inboxItem("q1", "question", "WEB-43", 60), inboxItem("k1", "mockup", "WEB-47", 30), inboxItem("p1", "planning", "WEB-39", 20),
    ] });
    if (path === "/runs") return json({ runs: state.runs, has_more: false });
    if (path === "/chats") return json({ chats: [
      { id: "chat-1", project: "WEB", title: "Design review", agent: atlas, harness: "claude-code", model: "opus", state: "idle", archived: false, revision: 1, message_count: 4, created_at: minutesAgo(90), updated_at: minutesAgo(5) },
      { id: "chat-2", project: "WEB", title: "Sprint planning", agent: atlas, harness: "claude-code", model: "opus", state: "running", archived: false, revision: 1, message_count: 2, created_at: minutesAgo(30), updated_at: minutesAgo(1) },
    ], has_more: false });
    return json({ code: "not_found", message: `mock: no handler for ${request.method()} ${path}` }, 404);
  });
  return {
    state,
    requests,
    async push(type: string) {
      await page.evaluate((t) => {
        const streams = (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse;
        for (const s of streams) s.onmessage?.({ data: JSON.stringify({ type: t }) });
      }, type);
    },
  };
}

test("a new workspace sees the checklist and a health banner naming missing secrets; steps tick without a reload", async ({ page }) => {
  await installSetupApi(page, { runner: false, harness: false, repo: false, plans: 0 });
  await page.goto("/settings?section=workspace");
  const banner = page.getByRole("status", { name: /Agents can’t run/ });
  await expect(banner).toContainText("No harness is available: add harness:anthropic or harness:openai.");
  await expect(banner.getByRole("link", { name: "Fix in Provider credentials →" })).toHaveAttribute("href", "/settings#secrets");

  const setup = page.getByRole("region", { name: "Get set up" });
  await expect(setup).toContainText("0 of 5 done");
  await expect(setup).toContainText("Claude Code: no harness:anthropic secret · Codex: no harness:openai secret");
  // The fixture's project has no space, so the repository step offers a new space that tracks work.
  await expect(setup.getByRole("link", { name: "Spaces →" })).toHaveAttribute("href", "/spaces/new?work=1");
  await expect(setup.getByRole("link", { name: "Provider credentials →" })).toHaveAttribute("href", "/settings#secrets");
  await expect(setup.getByRole("link", { name: "Runner backends →" })).toHaveAttribute("href", "/settings#runners");
  await expect(setup.getByRole("link", { name: "Personas →" })).toHaveAttribute("href", "/settings?section=personas&filter=tickets");
  await expect(setup.getByRole("button", { name: "Dismiss" })).toHaveCount(0);

  // The URL changes before the Personas list mounts and records the visit.
  await setup.getByRole("link", { name: "Personas →" }).click();
  await expect(page).toHaveURL(/\/settings\?section=personas&filter=tickets$/);
  await expect.poll(() => page.evaluate(() => localStorage.getItem("la:setup:workspace:agents-reviewed"))).toBe("1");
  await page.goBack();
  await expect(page.getByRole("region", { name: "Get set up" })).toContainText("1 of 5 done");

  // × hides the banner for the session; it's still hidden after navigating.
  await banner.getByRole("button", { name: "Hide this banner for this session" }).click();
  await expect(page.getByRole("status", { name: /Agents can’t run/ })).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("region", { name: "Get set up" })).toBeVisible();
  await expect(page.getByRole("status", { name: /Agents can’t run/ })).toHaveCount(0);
});

test("the runner banner shows when a harness works but no runner is online", async ({ page }) => {
  const api = await installSetupApi(page, { runner: false });
  await page.goto("/settings");
  const banner = page.getByRole("status", { name: "No runner online" });
  await expect(banner).toContainText("Dispatched work stays queued.");
  await expect(banner.getByRole("link", { name: "Runner backends →" })).toHaveAttribute("href", "/settings#runners");

  // Polling while offline clears the banner within a few seconds once the runner registers, without reloading.
  api.state.runner = true;
  await expect(page.getByRole("status", { name: "No runner online" })).toHaveCount(0, { timeout: 5_000 });
});

test("a starting runner hides the offline banner and updates to online automatically", async ({ page }) => {
  const api = await installSetupApi(page, { runner: false, runnerStarting: true });
  await page.goto("/settings#runners");
  await expect(page.getByRole("status", { name: "No runner online" })).toHaveCount(0);
  await expect(page.locator("#runners")).toContainText("Runner is starting");

  api.state.runner = true;
  api.state.runnerStarting = false;
  await expect(page.locator("#runners").getByRole("rowheader", { name: "mbp" })).toBeVisible({ timeout: 5_000 });
  await expect(page.getByRole("status", { name: "No runner online" })).toHaveCount(0);
});

test("a complete checklist can be dismissed and doesn't come back", async ({ page }) => {
  await installSetupApi(page);
  await page.goto("/settings?section=workspace");
  const done = page.getByRole("region", { name: "Setup complete" });
  await done.getByRole("button", { name: "Dismiss" }).click();
  await expect(done).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Workspace", level: 1 })).toBeVisible();
  await expect(page.getByRole("region", { name: "Setup complete" })).toHaveCount(0);
});
