import { expect, test, type Page, type Route } from "@playwright/test";
import { AGENTS } from "./mock-chat-api";

// LAZYAGENTS-52: start a plan with goal, [[ context chips, planner and epic;
// watch its reads stream in; hand off to proposal review; index counts.

const PROJECT = { id: "99999999-0000-4000-8000-000000000001", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
const EPIC = { id: "eeeeeeee-0000-4000-8000-000000000001", project_id: PROJECT.id, name: "Board estimates", health: "on_track", requires_mockup: false, status: "open", criteria_total: 0, criteria_done: 0, points_total: 0, points_done: 0, tickets_total: 0, tickets_done: 0 };
const PAGE = { kind: "artifact", id: "11111111-1111-4111-8111-111111111111", title: "ADR: Project chat sessions", artifact_type: "note", path: "Architecture/ADR: Project chat sessions", href: "/wiki/Architecture/ADR: Project chat sessions" };
const TICKET = { kind: "ticket", id: "33333333-3333-4333-8333-333333333333", title: "Chat context chips", display_id: "WEB-13", href: "/tickets/WEB-13", status: "done" };
const TARGETS: Array<{ title: string; path?: string; display_id?: string }> = [PAGE, TICKET];
const NOW = new Date().toISOString();

type Plan = Record<string, unknown> & { id: string; state: string; run_state: string; run_id: string };

const base = (over: Partial<Plan> & { id: string; goal: string }): Plan => ({
  project: "WEB", run_id: `run-${over.id}`, run_state: "completed", harness: "claude-code", model: "opus-5.5",
  state: "review", revision: 1, proposals: [], proposal_count: 0, context_refs: [], ticket_keys: [], ready_keys: [],
  created_at: NOW, updated_at: NOW, ...over,
});

async function installPlansApi(page: Page) {
  const plans: Plan[] = [
    base({ id: "p-accepted", goal: "Mockup review workspace\nwith pins", state: "accepted", proposal_count: 6, ticket_keys: ["WEB-1", "WEB-2", "WEB-3", "WEB-4", "WEB-5"] }),
    base({ id: "p-failed", goal: "Runner capacity view", state: "planning", run_state: "failed", outcome: "Harness crashed" }),
  ];
  const posted: Record<string, unknown>[] = [];
  const events = new Map<string, Array<Record<string, unknown>>>();
  async function handle(route: Route) {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    const method = req.method();
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    if (path === "/bootstrap")
      return json({
        workspace: { id: "w", name: "Acme", slug: "acme" },
        me: { id: "u", name: "Liam", email: "liam@example.com", initials: "L", role_title: "Owner" },
        users: [], agents: AGENTS, epics: [EPIC], labels: [], projects: [PROJECT],
        counts: { inbox: 0, wiki_suggestions: 0, live_agents: 0 },
      });
    if (path === "/runner") return json({ online: true, runners: [], slots: 1, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 });
    if (path === "/knowledge/suggest") {
      const q = (url.searchParams.get("q") ?? "").toLowerCase();
      return json({ targets: TARGETS.filter((t) => `${t.title} ${t.path ?? ""} ${t.display_id ?? ""}`.toLowerCase().includes(q)) });
    }
    if (path === "/knowledge/resolve")
      return json({ links: url.searchParams.getAll("ref").filter((r) => r === PAGE.path).map((r) => ({ ref: r, target: PAGE })) });
    if (/^\/agents\/[^/]+\/resolved$/.test(path)) return json({ harness: "claude-code", model: "opus-5.5" });
    if (path === "/planning-sessions" && method === "GET") return json(plans);
    if (path === "/planning-sessions" && method === "POST") {
      const b = req.postDataJSON() as Record<string, unknown>;
      posted.push(b);
      const plan = base({ id: "p-new", goal: String(b.goal), state: "planning", run_state: "running", context_refs: b.context_refs ?? [], epic_id: b.epic_id as string });
      plans.unshift(plan);
      events.set(plan.run_id, []);
      return json(plan, 201);
    }
    const one = /^\/planning-sessions\/([^/]+)$/.exec(path);
    if (one) {
      const p = plans.find((x) => x.id === one[1]);
      if (p && method === "PATCH") {
        const body = req.postDataJSON();
        posted.push(body);
        Object.assign(p, { proposals: body.proposals, revision: Number(p.revision) + 1 });
        if (body.action === "accept") Object.assign(p, { state: "accepted", ticket_keys: body.proposals.map((_: unknown, i: number) => `WEB-${i + 20}`) });
      }
      return p ? json(p) : json({ code: "not_found", message: "no plan" }, 404);
    }
    const run = /^\/runs\/([^/]+)$/.exec(path);
    if (run) return json({ run: {}, turns: [], approvals: [], events: events.get(run[1]) ?? [] });
    return json({ code: "not_found", message: `mock: ${method} ${path}` }, 404);
  }
  await page.addInitScript(() => {
    class FakeEventSource {
      onopen?: () => void;
      constructor() {
        setTimeout(() => this.onopen?.(), 0);
      }
      close() {}
    }
    (window as unknown as { EventSource: unknown }).EventSource = FakeEventSource;
  });
  await page.route("**/api/v1/**", handle);
  return {
    posted,
    read(runId: string, seq: number, tool: string, input: Record<string, unknown>) {
      events.get(runId)!.push({ seq, type: "tool_call", at: NOW, payload: { id: String(seq), tool, input } });
    },
    propose(id: string) {
      const p = plans.find((x) => x.id === id)!;
      Object.assign(p, {
        state: "review", run_state: "completed", proposal_count: 2, revision: 2,
        proposals: [
          { ref: "a", title: "Composer", description: "", criteria: ["Starts a plan"] },
          { ref: "b", title: "Index", description: "", criteria: ["Shows counts"] },
        ],
      });
    },
  };
}

test("start a plan with context, watch reads, hand off to review", async ({ page }) => {
  const mock = await installPlansApi(page);
  await page.goto("/plans?project=WEB");

  // Index rows: status, the goal's first line, accepted/total.
  const rows = page.getByTestId("plan-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText("Accepted");
  await expect(rows.nth(0)).toContainText("Mockup review workspace");
  await expect(rows.nth(0)).not.toContainText("with pins");
  await expect(rows.nth(0)).toContainText("5/6 accepted");
  await expect(rows.nth(1)).toContainText("Failed");
  await expect(rows.nth(1)).toContainText("no proposals");

  // Composer: [[ attaches a chip, Add context attaches another; planner lists main agents only.
  const goal = page.getByRole("combobox", { name: "Goal" });
  await goal.click();
  await goal.pressSequentially("Make planning easy. See [[chat ses");
  await page.getByRole("option", { name: /ADR: Project chat sessions/ }).click();
  await expect(page.getByTestId("context-chip")).toHaveCount(1);
  await expect(goal).toHaveValue("Make planning easy. See ");
  await page.getByRole("button", { name: "Add context" }).click();
  await page.getByRole("combobox", { name: "Search pages, artifacts and tickets" }).fill("WEB-13");
  await page.getByRole("option", { name: /WEB-13/ }).click();
  await expect(page.getByTestId("context-chip")).toHaveCount(2);
  await expect(page.getByText("2 of 20")).toBeVisible();

  const planner = page.getByRole("combobox", { name: "Planner agent" });
  await expect(planner.locator("option")).toHaveText(["Atlas · @atlas", "Juno · @juno"]);
  await planner.selectOption({ label: "Juno · @juno" });
  await expect(page.getByText("claude-code · opus-5.5")).toBeVisible();
  await page.getByRole("combobox", { name: "Epic" }).selectOption({ label: "Board estimates" });

  await goal.press("ControlOrMeta+Enter");
  await expect(page).toHaveURL(/\/plans\?id=p-new/);
  expect(mock.posted[0]).toMatchObject({
    project: "WEB",
    agent_id: AGENTS[1].id,
    goal: "Make planning easy. See ",
    epic_id: EPIC.id,
    context_refs: [{ kind: "page", id: PAGE.id }, { kind: "ticket", key: "WEB-13" }],
  });

  // Live: reads stream in from run events.
  await expect(page.getByText("The planner hasn’t read anything yet.")).toBeVisible();
  mock.read("run-p-new", 1, "mcp__lazyagents__read_page", { ref: PAGE.path });
  mock.read("run-p-new", 2, "mcp__lazyagents__get_ticket", { ticket: "WEB-13" });
  const sources = page.getByTestId("plan-sources");
  await expect(sources.getByRole("listitem")).toHaveCount(2, { timeout: 10_000 });
  await expect(sources).toContainText("Reading ADR: Project chat sessions");
  await expect(sources).toContainText("Opening WEB-13");

  // Proposals arrive: the page links to the review.
  mock.propose("p-new");
  const link = page.getByRole("link", { name: "Review the proposals" });
  await expect(link).toBeVisible({ timeout: 10_000 });
  await link.click();
  await expect(page).toHaveURL(/#proposal-review$/);
  await expect(page.getByRole("region", { name: "Proposal review" }).getByLabel("Ticket 1 title")).toHaveValue("Composer");
  await expect(rows.first()).toContainText("0/2 accepted", { timeout: 20_000 });
});
test("review edits criteria and estimates, validates dependencies and accepts a subset", async ({
  page,
}) => {
  const mock = await installPlansApi(page);
  // Create a planning session through the same UI entry point.
  await page.goto("/plans?project=WEB");
  await page.getByLabel("Goal").fill("Review drafts");
  await page.getByLabel("Goal").press("ControlOrMeta+Enter");
  await expect(page).toHaveURL(/id=p-new/);
  mock.propose("p-new");
  await page.reload();
  await expect(page.getByLabel("Ticket 1 title")).toHaveValue("Composer");
  await page
    .getByRole("button", { name: "Add criterion", exact: true })
    .click();
  await page
    .getByLabel("Criterion 2", { exact: true })
    .fill("Second criterion");
  await page
    .getByRole("button", { name: "Move criterion 2 up", exact: true })
    .click();
  await expect(page.getByLabel("Criterion 1", { exact: true })).toHaveValue(
    "Second criterion",
  );
  await page
    .getByRole("button", { name: "Remove criterion 2", exact: true })
    .click();
  await page.getByRole("button", { name: "8", exact: true }).click();
  await expect(page.getByText("Changed from unestimated.")).toBeVisible();
  await page.getByLabel("Select draft 2").uncheck();
  await page.getByText("Ticket 2 · Index", { exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "which is not selected" })).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Accept selected (1)", exact: true }),
  ).toBeDisabled();
  await page.getByLabel("Select draft 2").check();
  await page.getByRole("button", { name: /2 · Index/ }).click();
  await page.getByText("Ticket 1 · Composer", { exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "cycle" })).toBeVisible();
  await page.getByText("Ticket 1 · Composer", { exact: true }).click();
  await page.getByRole("button", { name: /1 · Composer/ }).click();
  await page.getByText("Ticket 2 · Index", { exact: true }).click();
  await page.getByLabel("Select draft 2").uncheck();
  await page
    .getByRole("button", { name: "Accept selected (1)", exact: true })
    .click();
  await expect(
    page.getByRole("link", { name: "WEB-20 · Composer" }),
  ).toBeVisible();
  await expect(page.getByText("Tickets created · 1/2 accepted")).toBeVisible();
  expect(mock.posted.at(-1)?.proposals).toMatchObject([
    { title: "Composer", criteria: ["Second criterion"], estimate_points: 8 },
  ]);
});
