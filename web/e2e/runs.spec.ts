import { expect, test, type Page } from "@playwright/test";
import type { Schemas } from "../lib/api/client";
import { installChatApi } from "./mock-chat-api";

// LAZYAGENTS-163: the chat-style Runs page. A grouped list beside the run
// thread, the inline approval and Next line, the composer, and the Context panel.

const APPROVING = "00000000-0000-4000-8000-000000000301";
const ASKING = "00000000-0000-4000-8000-000000000302";
const RUNNING = "00000000-0000-4000-8000-000000000303";
const DONE = "00000000-0000-4000-8000-000000000304";
const CHILD = "00000000-0000-4000-8000-000000000305";

const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();
const step = (position: number, state: Schemas["PlanStep"]["state"], text: string): Schemas["PlanStep"] => ({ position, state, text });
const agent = (name: string, color_index = 0) => ({ id: `agent-${name}`, name, handle: name.toLowerCase(), color_index });

function run(id: string, over: Partial<Schemas["Run"]>): Schemas["Run"] {
  return {
    id, ticket_key: "WEB-9", work_title: "Search index", purpose: "ticket", project_key: "WEB", agent: agent("Builder"),
    mode: "managed", state: "running", harness: "claude-code", model: "opus", started_at: minutesAgo(12),
    tool_calls: 3, input_tokens: 1200, output_tokens: 300, cost_usd: 0.4, cost_source: "harness", plan: [], scopes: [], approval_scopes: [], ...over,
  };
}

const approving = run(APPROVING, {
  ticket_key: "WEB-8", work_title: "Partition ledger entries", agent: agent("Atlas", 2), state: "waiting", wait_reason: "approval",
  branch: "atlas/web-8-partition", pr_number: 41, pr_url: "https://github.com/acme/app/pull/41", child_count: 1, model: "gpt-5-codex", harness: "codex",
  plan: [step(1, "done", "Write the migration"), step(2, "current", "Run it on staging"), step(3, "pending", "Open the PR")],
});
const asking = run(ASKING, { ticket_key: "WEB-7", work_title: "Payout retries", agent: agent("Quill", 1), state: "waiting", wait_reason: "human_reply" });
const running = run(RUNNING, {});
const done = run(DONE, { ticket_key: "WEB-3", work_title: "Session refresh", state: "completed", started_at: minutesAgo(80), ended_at: minutesAgo(30), outcome: "Shipped the refresh." });
const child = run(CHILD, { ticket_key: "WEB-8", work_title: "Partition ledger entries", agent: agent("Reviewer", 3), parent_run_id: APPROVING, state: "completed", started_at: minutesAgo(8), ended_at: minutesAgo(5), cost_usd: 0.1 });

const approval = (id: string, action: string): Schemas["Approval"] => ({
  id, run_id: APPROVING, ticket_key: "WEB-8", agent: approving.agent, scope: "db:migrate", action_summary: action,
  action_detail: {}, risk_summary: "Dry run finished with no long locks", state: "pending", brokered: true, created_at: minutesAgo(3),
} as Schemas["Approval"]);

const ev = (seq: number, type: Schemas["RunEvent"]["type"], payload: Record<string, unknown>, m: number): Schemas["RunEvent"] => ({ seq, type, payload, at: minutesAgo(m) });
const atlasEvents = [
  ev(1, "lifecycle", { state: "starting", runner: "runner-2", backend: "microvm" }, 11),
  ev(2, "lifecycle", { state: "turn_started", turn: 1 }, 10),
  ev(3, "message", { text: "I wrote **0042_partition_ledger_entries** and checked it locally." }, 10),
  ev(4, "tool_call", { id: "t1", tool: "Edit", input: { file_path: "db/migrations/0042_partition.sql" } }, 9),
  ev(5, "tool_result", { id: "t1", output: "ok" }, 9),
  ev(6, "message", { kind: "step", step: 1, state: "done" }, 9),
  ev(7, "tool_call", { id: "t2", tool: "lazyagents.delegate", input: { agent: "@reviewer", task: "Review the migration for long locks" } }, 8),
  ev(8, "tool_result", { id: "t2", output: JSON.stringify({ run_id: CHILD }) }, 8),
  ev(9, "tool_call", { id: "t3", tool: "lazyagents.request_approval", input: { scope: "db:migrate", action: "Run 0042 on staging" } }, 3),
];

async function installRuns(page: Page) {
  const api = await installChatApi(page);
  const decided: string[] = [];
  const replies: string[] = [];
  const needs = (kind: string, title: string, over: Record<string, unknown>) => ({
    kind, title, summary: "", href: "/inbox", project: "WEB", ticket_key: "", created_at: minutesAgo(20), resolved: false, read: false, needs_you: true, ...over,
  });
  api.inbox.push(
    needs("approval", "Partition ledger entries", { id: "approval:a1", run_id: APPROVING, ticket_key: "WEB-8", agent: approving.agent, created_at: minutesAgo(3) }),
    needs("question", "Payout retries", { id: "question:q1", run_id: ASKING, ticket_key: "WEB-7", agent: asking.agent }),
    needs("planning", "Billing plan", { id: "planning:p1", href: "/plans/p1" }),
  );
  await page.route((url) => /^\/api\/v1\/(runs|approvals|tickets|epics)/.test(url.pathname), async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace("/api/v1", "");
    if (path === "/runs") {
      const live = [approving, asking, running];
      return route.fulfill({ json: { runs: url.searchParams.get("state") === "live" ? live : [...live, done], has_more: false } });
    }
    const decide = /^\/approvals\/([^/]+)\/(approve|deny)$/.exec(path);
    if (decide) {
      decided.push(`${decide[1]}:${decide[2]}`);
      if (["a1", "a2"].every((id) => decided.some((d) => d.startsWith(`${id}:`)))) {
        const i = api.inbox.findIndex((x) => x.id === "approval:a1");
        if (i >= 0) api.inbox.splice(i, 1);
      }
      return route.fulfill({ json: { ...approval(decide[1], ""), state: decide[2] === "approve" ? "approved" : "denied" } });
    }
    if (path === "/tickets/WEB-7/comments" && req.method() === "POST") {
      replies.push((req.postDataJSON() as { body_md: string }).body_md);
      return route.fulfill({ status: 201, json: { id: "c1", body_md: replies.at(-1), created_at: new Date().toISOString() } });
    }
    if (path === "/tickets/WEB-8") {
      return route.fulfill({ json: {
        key: "WEB-8", title: "Partition ledger entries", status: "in_progress", priority: "high", epic: { id: "e1", name: "Ledger at scale" },
        criteria: [{ id: "c1", position: 1, text: "Entries are partitioned by month", done: true }, { id: "c2", position: 2, text: "No lock longer than 1s", done: false }],
        branch: "atlas/web-8-partition", pr: { number: 41, state: "open", url: "https://github.com/acme/app/pull/41", additions: 120, deletions: 8 },
        blocked_by: [], blocks: [], labels: [], artifacts: [], approvals: [], description_md: "", revision: 1, dependency_revision: 1,
        project: { key: "WEB", name: "Web" }, requires_mockup: false, epic_review: false, mockup_gate: { required: false, from_epic: false, approved: false, mockups: [] },
        created_at: minutesAgo(100), updated_at: minutesAgo(1),
      } });
    }
    if (path.startsWith("/tickets/")) return route.fulfill({ status: 404, json: { message: "not found" } });
    if (path === "/epics") return route.fulfill({ json: { epics: [{ epic: { id: "e1", name: "Ledger at scale" }, counts: { total: 5, done: 3, backlog: 0, todo: 1, in_progress: 1, in_review: 0 }, tickets: [] }] } });
    const id = path.split("/").at(-1)!;
    const after = Number(url.searchParams.get("after") ?? 0);
    const r = { [APPROVING]: approving, [ASKING]: asking, [RUNNING]: running, [DONE]: done, [CHILD]: child }[id] ?? running;
    const events = id === APPROVING ? atlasEvents : id === ASKING
      ? [ev(1, "message", { text: "Reading the payout code." }, 10), ev(2, "lifecycle", { state: "waiting", reason: "Should payout retries cap at 5 or 8?" }, 2)]
      : [ev(1, "message", { text: `${r.agent.name} at work.` }, 5)];
    const approvals = id === APPROVING ? [approval("a1", "Run 0042 on staging"), approval("a2", "Vacuum ledger_entries on staging")].filter((a) => !decided.some((d) => d.startsWith(`${a.id}:`))) : [];
    const state = id === APPROVING && approvals.length === 0 ? { state: "running" as const, wait_reason: undefined } : {};
    return route.fulfill({ json: { run: { ...r, ...state }, child_runs: id === APPROVING ? [child] : [], turns: [], approvals, events: events.filter((e) => e.seq > after) } });
  });
  return { api, decided, replies };
}

const list = (page: Page) => page.getByRole("complementary", { name: "Runs" });

test("the list groups runs beside the selected run, and the URL keeps the selection", async ({ page }) => {
  await installRuns(page);
  await page.goto("/runs");
  // /runs opens Work's Activity, the first Needs you run selected.
  await expect(page).toHaveURL(/\/work\?view=activity$/);
  const active = list(page).getByRole("region", { name: "Active" });
  await expect(active.getByRole("listitem")).toHaveText([/Partition ledger entries/, /Payout retries/, /Search index/]);
  await expect(list(page).getByRole("region", { name: "Other needs you" }).getByRole("link", { name: /Billing plan/ })).toHaveAttribute("href", "/plans/p1");
  await expect(active.locator("a[aria-current=page]")).toContainText("Partition ledger entries");
  await expect(list(page).getByRole("region", { name: "Earlier today" })).toContainText("Session refresh");
  await expect(page.getByRole("region", { name: "Activity telemetry" })).toContainText("0 / 1");

  // The tray's Needs you lists the same items.
  await page.getByRole("button", { name: /^Needs you,/ }).click();
  const tray = page.getByRole("dialog", { name: "Needs you" });
  await expect(tray.locator("[data-tray-row]")).toHaveCount(3);
  for (const t of ["Partition ledger entries", "Payout retries", "Billing plan"]) await expect(tray.locator("[data-tray-row]").filter({ hasText: t })).toHaveCount(1);
  // Open all lands on Work with Needs you in view.
  await tray.getByRole("link", { name: "Open all →" }).click();
  await expect(page).toHaveURL(/\/work(\?[^#]*)?#needs-you$/);
  await expect(active).toBeInViewport();

  // Selecting a row updates the URL; a reload restores the selection.
  await list(page).getByRole("link", { name: /Search index/ }).click();
  await expect(page).toHaveURL(new RegExp(`/work\\?run=${RUNNING}&view=activity$`));
  await expect(page.getByRole("heading", { name: "Search index" })).toBeVisible();
  await page.reload();
  await expect(list(page).locator("a[aria-current=page]")).toContainText("Search index");
  await expect(page.getByRole("heading", { name: "Search index" })).toBeVisible();

  // Inline "/" search and VIEW filter narrow the list cleanly.
  await page.locator("body").click({ position: { x: 900, y: 5 } });
  await page.keyboard.press("/");
  await expect(page.getByRole("textbox", { name: "Search work" })).toBeFocused();
  await page.keyboard.type("session");
  await expect(list(page).getByRole("link", { name: /Session refresh/ })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Search work" })).toHaveValue("session");
  await expect(list(page).getByRole("link", { name: /Search index/ })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Filter: Running & queued" }).click();
  await expect(page).toHaveURL(/filter=active/);
  await expect(list(page).getByText("Session refresh")).toHaveCount(0);
  await page.screenshot({ path: "test-results/runs-desktop.png" });
});

test("the thread decides inline with A and ⇧A, then Next opens the next item with J", async ({ page }) => {
  const { decided } = await installRuns(page);
  await page.goto(`/runs/${APPROVING}`);
  const thread = page.getByRole("region", { name: "Run thread" });
  await expect(thread.getByText("Step 2 of 3", { exact: true })).toBeVisible();
  await expect(thread.getByRole("progressbar", { name: "Plan progress" })).toHaveAttribute("aria-valuenow", "1");
  await expect(thread.getByText("0042_partition_ledger_entries")).toBeVisible();
  await expect(thread.getByText(/Step 1 done · Write the migration/)).toBeVisible();
  await expect(thread.getByText("Review the migration for long locks")).toBeVisible();
  await expect(thread.getByRole("link", { name: "Open run ↗" })).toHaveAttribute("href", `/runs/${CHILD}`);
  const card = thread.getByRole("group", { name: "Needs attention" });
  await expect(card).toContainText("Run 0042 on staging");
  await expect(card.getByRole("button", { name: "Approve all 2 for this run" })).toBeVisible();
  await page.screenshot({ path: "test-results/run-thread.png" });

  await page.locator("body").click({ position: { x: 900, y: 5 } });
  await page.keyboard.press("Shift+A");
  await page.getByRole("alertdialog").getByRole("button", { name: "Approve all" }).click();
  await expect.poll(() => decided).toEqual(["a1:approve", "a2:approve"]);
  const next = thread.getByRole("link", { name: /Question · Payout retries/ });
  await expect(next).toBeVisible();
  await page.keyboard.press("j");
  await expect(page).toHaveURL(new RegExp(`/runs/${ASKING}$`));
});

test("D opens Deny… and A approves one request", async ({ page }) => {
  const { decided } = await installRuns(page);
  await page.goto(`/runs/${APPROVING}`);
  const card = page.getByRole("group", { name: "Needs attention" });
  await expect(card).toContainText("Run 0042 on staging");
  // Letters typed in a filter menu (Radix typeahead) never reach the page's shortcuts.
  await list(page).getByRole("button", { name: /^Persona:/ }).click();
  await expect(page.getByRole("menu")).toBeVisible();
  await page.keyboard.press("a");
  await page.keyboard.press("d");
  await page.keyboard.press("j");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
  expect(decided).toEqual([]);
  await expect(card.getByRole("textbox", { name: /Reason for denying/ })).toHaveCount(0);
  await expect(page).toHaveURL(new RegExp(`/runs/${APPROVING}$`));
  await page.locator("body").click({ position: { x: 900, y: 5 } });
  await page.keyboard.press("d");
  const reason = card.getByRole("textbox", { name: /Reason for denying/ });
  await expect(reason).toBeFocused();
  await reason.fill("Not now");
  await reason.press("Escape");
  await page.locator("body").click({ position: { x: 900, y: 5 } });
  await page.keyboard.press("a");
  await expect.poll(() => decided).toEqual(["a1:approve"]);
  await expect(card).toContainText("Vacuum ledger_entries on staging");
});

test("the composer replies to a waiting run as a comment mentioning the agent", async ({ page }) => {
  const { replies } = await installRuns(page);
  await page.goto(`/runs/${ASKING}`);
  const thread = page.getByRole("region", { name: "Run thread" });
  await expect(thread.getByRole("group", { name: "Needs attention" })).toContainText("Should payout retries cap at 5 or 8?");
  const composer = page.getByRole("form", { name: "Reply to Quill" });
  const box = composer.getByRole("textbox", { name: "Reply to Quill" });
  await expect(box).toBeFocused();
  await box.fill("Cap them at 5.");
  await box.press("Enter");
  await expect(composer.getByRole("status")).toHaveText(/Sent\. Resuming Quill/);
  expect(replies).toEqual(["@quill Cap them at 5."]);
  // A working run takes a follow-up.
  await page.goto(`/runs/${RUNNING}`);
  await expect(page.getByRole("form", { name: "Follow up with Builder" })).toBeVisible();
});

test("the side panel's Chat talks to your persona about the run; the run's composer goes to its agent", async ({ page }) => {
  const { api } = await installRuns(page);
  await page.goto(`/runs/${RUNNING}`);
  // The main pane talks to what it shows.
  await expect(page.getByTestId("run-composer-to")).toHaveText(/^To.*Builder · WEB-9$/);
  // The run's companion: Context and Chat tabs in the shell's right-hand panel, switched from the rail.
  const panel = page.getByRole("complementary", { name: "Panel", exact: true });
  const tabs = page.getByRole("navigation", { name: "Panel rail" }).getByRole("tablist", { name: "Panel tabs" });
  await tabs.getByRole("tab", { name: "Chat" }).click();
  await panel.getByRole("button", { name: "Start a chat" }).click();
  await expect.poll(() => api.created.length).toBe(1);
  expect(api.created[0].hidden).toBe(true);
  await expect(panel.getByTestId("work-chat-subject")).toHaveText("Viewing: WEB-9 · Search index");
  await expect(panel.getByTestId("dock-chat-to")).not.toHaveText("your persona");
  const box = panel.getByRole("combobox", { name: "Message" });
  await box.fill("Is this safe to merge?");
  await box.press("Enter");
  await expect.poll(() => api.posted.length).toBe(1);
  expect(api.posted[0].body.body).toBe(`Is this safe to merge?\n\n<!-- vesper:work-context -->\nViewing run ${RUNNING} (“Search index”) by Builder for ticket WEB-9.`);
  expect(api.posted[0].body.context_refs).toEqual([{ kind: "ticket", key: "WEB-9" }]);
  // The bubble shows what was typed; the context reaches the persona, not the transcript.
  await expect(panel.getByTestId("user-message").first()).toContainText("Is this safe to merge?");
  await expect(panel.getByTestId("user-message").first()).not.toContainText("vesper:work-context");
  // The reply finishes before the next message, so it posts rather than queueing as a follow-up.
  await expect(panel.getByRole("button", { name: "Send", exact: true })).toBeVisible();

  // The chat follows you to another run, and says which one each message is about.
  await page.goto(`/runs/${DONE}`);
  await expect(tabs.getByRole("tab", { name: "Chat" })).toHaveAttribute("aria-selected", "true");
  await expect(panel.getByTestId("work-chat-subject")).toHaveText("Viewing: WEB-3 · Session refresh");
  // The reloaded conversation is ready to send, not still loading the chat.
  await expect(panel.getByRole("button", { name: "Send", exact: true })).toBeVisible();
  await panel.getByRole("combobox", { name: "Message" }).fill("And this one?");
  await panel.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect.poll(() => api.posted.length).toBe(2);
  expect(api.posted[1].chat).toBe(api.posted[0].chat);
  expect(api.posted[1].body.body).toContain("Viewing run " + DONE);
});

test("a pinned run stays attached to the side-panel chat as you move to another run", async ({ page }) => {
  const { api } = await installRuns(page);
  await page.goto(`/runs/${RUNNING}`);
  const panel = page.getByRole("complementary", { name: "Panel", exact: true });
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: "Chat" }).click();
  await panel.getByRole("button", { name: "Start a chat" }).click();
  await panel.getByRole("button", { name: "Pin WEB-9 · Search index" }).click();
  await expect(panel.getByTestId("work-chat-pinned")).toHaveText(/Pinned: WEB-9 · Search index/);
  await expect(panel.getByTestId("work-chat-subject")).toHaveCount(0);

  await page.goto(`/runs/${DONE}`);
  await expect(panel.getByTestId("work-chat-pinned")).toHaveText(/Pinned: WEB-9 · Search index/);
  await expect(panel.getByTestId("work-chat-subject")).toHaveText(/Viewing: WEB-3 · Session refresh/);
  await expect(panel.getByRole("button", { name: "Send", exact: true })).toBeVisible();
  await panel.getByRole("combobox", { name: "Message" }).fill("Compare them");
  await panel.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect.poll(() => api.posted.length).toBe(1);
  expect(api.posted[0].body.body).toBe(`Compare them\n\n<!-- vesper:work-context -->\nPinned run ${RUNNING} (“Search index”) by Builder for ticket WEB-9.\nViewing run ${DONE} (“Session refresh”) by Builder for ticket WEB-3.`);
  expect(api.posted[0].body.context_refs).toEqual([{ kind: "ticket", key: "WEB-9" }, { kind: "ticket", key: "WEB-3" }]);

  await panel.getByRole("button", { name: "Unpin WEB-9 · Search index" }).click();
  await expect(panel.getByTestId("work-chat-pinned")).toHaveCount(0);
  await page.reload();
  await expect(panel.getByTestId("work-chat-pinned")).toHaveCount(0);
});

test("the Context panel shows the ticket, code and run, opens the views, and remembers closing", async ({ page }) => {
  await installRuns(page);
  await page.goto(`/runs/${APPROVING}`);
  // The companion's Context tab.
  const ctx = page.getByRole("tabpanel", { name: "Context" });
  await expect(ctx.getByRole("link", { name: /WEB-8 Partition ledger entries/ })).toHaveAttribute("href", "/tickets/WEB-8");
  await expect(ctx).toContainText("Ledger at scale");
  await expect(ctx.getByRole("progressbar", { name: "Epic progress" })).toHaveAttribute("aria-valuenow", "3");
  const criteria = ctx.getByRole("region", { name: "Acceptance criteria" });
  await expect(criteria).toContainText("1/2");
  await expect(criteria.getByRole("listitem").first()).toContainText("Done: Entries are partitioned by month");
  const code = ctx.getByRole("region", { name: "Code" });
  await expect(code).toContainText("atlas/web-8-partition");
  await expect(code).toContainText("+120 −8");
  await expect(code.getByRole("link", { name: /#41/ })).toHaveAttribute("href", "https://github.com/acme/app/pull/41");
  const facts = ctx.getByRole("region", { name: "Run" });
  // Every column of the old "More columns" table: purpose, model, started, elapsed, cost, sub runs (status, agent and work are in the list and header).
  for (const text of ["Ticket run", "gpt-5-codex", "codex", "12m", "$0.40", "+$0.10 sub", "Sub runs1", "runner-2 · microvm"]) await expect(facts).toContainText(text);

  await ctx.getByRole("button", { name: "Raw log" }).click();
  await expect(page).toHaveURL(/view=details/);
  await expect(page.getByRole("region", { name: "Events" })).toBeVisible();
  // Unified inline Run views tabs stay in place across every mode (no toolbar Back to thread button).
  const viewTabs = page.getByRole("tablist", { name: "Run views" });
  await expect(viewTabs.getByRole("tab", { name: /^Trace/ })).toHaveAttribute("aria-selected", "true");
  await ctx.getByRole("button", { name: "Graph" }).click();
  await expect(page).toHaveURL(/view=graph/);
  await ctx.getByRole("button", { name: "Files" }).click();
  await expect(page.getByRole("region", { name: "Files" })).toContainText("db/migrations/0042_partition.sql");
  await viewTabs.getByRole("tab", { name: "Thread" }).click();
  await expect(page).toHaveURL(new RegExp(`/runs/${APPROVING}$`));
  await expect(ctx.getByRole("region", { name: "Plan" })).toContainText("Write the migration");

  // Folding the companion is remembered: it reopens from its rail.
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Collapse panel" }).click();
  await expect(ctx).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Partition ledger entries" })).toBeVisible();
  await expect(ctx).toHaveCount(0);
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Open Context" }).click();
  await expect(ctx).toBeVisible();
});

test("Costs and Highlights moved to Reports; the old tabs redirect", async ({ page }) => {
  await installRuns(page);
  await page.goto("/runs?tab=costs&project=WEB");
  await expect(page).toHaveURL(/\/reports\?tab=costs&project=WEB$/);
  await expect(page.getByRole("heading", { name: "Reports" })).toBeVisible();
  // Reports is a tool in the Apps flyout, so Apps reads as current.
  await expect(page.getByRole("list", { name: "Areas" }).getByRole("button", { name: "Apps" })).toHaveAttribute("aria-current", "page");
  await page.goto("/runs?tab=highlights");
  await expect(page).toHaveURL(/\/reports\?tab=highlights$/);
});
