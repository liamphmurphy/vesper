import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// Starting a ticket's run from a chat: the persona's ```dispatch card, the run in
// the tray above the message box, then the card's summary once it ends.

const RUN = "88888888-8888-4888-8888-888888888888";
const now = () => new Date().toISOString();

const preview = (blockers: string[] = []) => ({
  ticket_key: "WEB-3", agent: { id: "a1", name: "Pike", handle: "pike", color_index: 6 },
  resolved: { harness: "claude-code", model: "opus-5.5" }, repo_url: "https://github.com/acme/web.git", base_branch: "main", branch: "pike/web-3",
  setup: [], context: [], scopes: [], secrets: [], harness_key: { secret: "harness:anthropic", present: true },
  runner: { host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3, online: true, runners: [], slots: 3, busy: 1, live: 1, queued: 0 },
  blockers, queued_behind: [],
});

type State = { runs: Record<string, unknown>[]; starts: unknown[]; cancels: number; blockers: string[]; decisions?: string[] };

const run = (over: Record<string, unknown> = {}) => ({
  run_id: RUN, ticket: "WEB-3", ticket_title: "Fix payouts", agent: "pike", state: "running", started_at: now(),
  cost_usd: 0.42, steps_total: 4, steps_done: 1, current_step: "Fix Round()", ...over,
});

async function serve(page: Page, state: State) {
  await page.route(/\/api\/v1\/tickets\/WEB-3\/dispatch$/, (route: Route) => route.fulfill({ json: preview(state.blockers) }));
  await page.route(/\/api\/v1\/tickets\/WEB-3$/, (route: Route) => route.fulfill({ json: { key: "WEB-3", title: "Fix payouts", status: "todo" } }));
  await page.route(/\/api\/v1\/approvals\/[^/]+\/(approve|deny)$/, (route: Route) => {
    (state.decisions ??= []).push(route.request().url().split("/approvals/")[1]);
    state.runs = state.runs.map((r) => ({ ...r, state: "running", wait_reason: undefined, approval: undefined }));
    return route.fulfill({ json: {} });
  });
  await page.route(/\/api\/v1\/runs\/[^/]+\/cancel$/, (route: Route) => {
    state.cancels++;
    state.runs = state.runs.map((r) => ({ ...r, state: "cancelled", ended_at: now() }));
    return route.fulfill({ json: {} });
  });
  await page.route(/\/api\/v1\/chats\/[^/]+\/runs$/, (route: Route) => {
    const req = route.request();
    if (req.method() === "POST") {
      const body = req.postDataJSON();
      state.starts.push(body);
      const started = run({ state: "queued", steps_total: 0, steps_done: 0, current_step: undefined, message_id: body.message_id });
      state.runs = [started];
      return route.fulfill({ status: 201, json: started });
    }
    return route.fulfill({ json: { runs: state.runs } });
  });
}

async function offer(page: Page, state: State, routes?: () => Promise<unknown>, opts?: { devWorkspaceEnabled?: boolean }) {
  const mock = await installChatApi(page, { replyDelayMs: 10, devWorkspaceEnabled: opts?.devWorkspaceEnabled });
  await serve(page, state);
  await routes?.();
  await page.goto("/chat");
  const box = page.getByRole("combobox", { name: "Message" });
  await box.fill("dispatch: fix the payout bug");
  await box.press("Enter");
  const card = page.getByTestId("dispatch-card");
  await expect(card).toBeVisible();
  return Object.assign(card, { mock });
}

test("a dispatch card starts the run as you, then the tray follows it", async ({ page }) => {
  const state: State = { runs: [], starts: [], cancels: 0, blockers: [] };
  const card = await offer(page, state);
  await expect(card).toContainText("Start a run for WEB-3?");
  await expect(card).toContainText("Fix payouts");
  await expect(card).toContainText("@pike");
  await expect(card).toContainText("acme/web · main");
  await expect(card).toContainText("Immediately");

  await card.getByRole("button", { name: "Start run" }).click();
  await expect.poll(() => state.starts.length).toBe(1);
  expect(state.starts[0]).toMatchObject({ ticket: "WEB-3" });
  expect((state.starts[0] as { message_id?: string }).message_id).toBeTruthy();
  await expect(page.getByTestId("dispatch-started")).toContainText("Started WEB-3 with @pike");

  // The persona hands the ticket to the agent once, over the run's card, then gets out of the way.
  const handoff = page.getByTestId("ticket-run-handoff");
  await expect(handoff).toContainText("Handing WEB-3 to @pike");
  await page.waitForTimeout(1500);
  await page.screenshot({ path: "/tmp/chat-dispatch-handoff.png" });
  await expect(handoff).toHaveCount(0, { timeout: 5000 });

  const tray = page.getByTestId("ticket-run-tray");
  await expect(tray).toContainText("Queued");
  // The agent posts its plan and gets going; the tray follows by polling.
  const messageId = (state.starts[0] as { message_id: string }).message_id;
  state.runs = [run({ message_id: messageId, activity: { tool: "Bash", command: "go test ./internal/payouts" } })];
  await expect(tray).toContainText("Running", { timeout: 10000 });
  await expect(tray).toContainText("Step 2 of 4 · Fix Round()");
  // The header says a run is going and opens it.
  const pill = page.getByTestId("chat-runs-pill");
  await expect(pill).toHaveText("1 run active");
  await expect(pill).toHaveAttribute("href", `/runs/${RUN}`);
  // What it's doing, in the chat's words: never the command itself.
  await expect(page.getByTestId("ticket-run-doing")).toHaveText("Running tests");
  await expect(tray).not.toContainText("go test");
  await page.screenshot({ path: "/tmp/chat-dispatch-tray.png" });

  // It asks for approval: the decision is right in the tray.
  state.runs = [run({ message_id: messageId, state: "waiting", wait_reason: "approval", approval: { id: "99999999-9999-4999-8999-999999999999", scope: "db:migrate", action: "Run migrations on staging", detail: '{"env":"staging"}', risk: "Reversible" } })];
  const approval = page.getByTestId("ticket-run-approval");
  await expect(approval).toContainText("Run migrations on staging", { timeout: 10000 });
  await expect(tray).toContainText("Waiting · approval");
  await page.screenshot({ path: "/tmp/chat-dispatch-approval.png" });
  await approval.getByRole("button", { name: "Approve" }).click();
  await expect.poll(() => state.decisions).toEqual(["99999999-9999-4999-8999-999999999999/approve"]);

  // It asks a question: the tray says to answer here.
  state.runs = [run({ message_id: messageId, state: "waiting", wait_reason: "human_reply" })];
  await expect(tray).toContainText("asked you something. Answer in this chat", { timeout: 10000 });

  // Once it ends it leaves the tray, and the card becomes its summary with the PR.
  state.runs = [run({ message_id: (state.starts[0] as { message_id: string }).message_id, state: "completed", ended_at: now(), steps_done: 4, current_step: undefined, pr_url: "https://github.com/acme/web/pull/412" })];
  await expect(tray).toHaveCount(0, { timeout: 10000 });
  const summary = page.getByTestId("ticket-run");
  await expect(summary).toContainText("Completed");
  await expect(summary.getByRole("link", { name: "Open PR" })).toHaveAttribute("href", "https://github.com/acme/web/pull/412");

  // Review it with me hands the PR to this chat's persona as the person's message.
  await summary.getByRole("button", { name: "Review it with me" }).click();
  await expect.poll(() => card.mock.posted.map((p) => JSON.stringify(p.body))).toContainEqual(expect.stringContaining("Review the pull request for WEB-3: https://github.com/acme/web/pull/412"));
});

test("ticket run card with an open PR opens its branch in Dev workspace", async ({ page }) => {
  const state: State = { runs: [], starts: [], cancels: 0, blockers: [] };
  const card = await offer(page, state, undefined, { devWorkspaceEnabled: true });
  await card.getByRole("button", { name: "Start run" }).click();
  await expect.poll(() => state.starts.length).toBe(1);
  const messageId = (state.starts[0] as { message_id: string }).message_id;

  state.runs = [run({
    message_id: messageId, state: "completed", ended_at: now(), steps_done: 4, current_step: undefined,
    repository: "https://github.com/acme/web.git", branch: "pike/web-3",
    pr_url: "https://github.com/acme/web/pull/412", pr_state: "open",
  })];
  const summary = page.getByTestId("ticket-run");
  await expect(summary).toContainText("Completed", { timeout: 10000 });
  const openBtn = summary.getByRole("button", { name: "Open in Dev workspace" });
  await expect(openBtn).toBeVisible();
  await openBtn.click();
  await expect(page).toHaveURL(/\/dev$/);
  expect(card.mock.devWorkspaceOpenBranches).toEqual([
    { repository: "https://github.com/acme/web.git", branch: "pike/web-3", pr_number: 412 },
  ]);
});

test("a card that dispatch would refuse says why and can't start", async ({ page }) => {
  const state: State = { runs: [], starts: [], cancels: 0, blockers: ["WEB-3 already has a running run."] };
  const card = await offer(page, state);
  await expect(card.getByRole("alert")).toContainText("already has a running run");
  await expect(card.getByRole("button", { name: "Start run" })).toBeDisabled();
  await card.getByRole("button", { name: "Not now" }).click();
  await expect(page.getByTestId("dispatch-dismissed")).toBeVisible();
  expect(state.starts).toHaveLength(0);
});

test("Stop in the tray cancels the run", async ({ page }) => {
  const state: State = { runs: [], starts: [], cancels: 0, blockers: [] };
  const card = await offer(page, state);
  await card.getByRole("button", { name: "Start run" }).click();
  const tray = page.getByTestId("ticket-run-tray");
  await expect(tray).toBeVisible();
  await tray.getByRole("button", { name: "Stop" }).click();
  await expect.poll(() => state.cancels).toBe(1);
  await expect(tray).toHaveCount(0, { timeout: 10000 });
  await expect(page.getByTestId("ticket-run")).toContainText("Cancelled");
});

test("a run already going when the chat opens doesn't replay the hand-off", async ({ page }) => {
  const state: State = { runs: [run()], starts: [], cancels: 0, blockers: [] };
  await offer(page, state);
  await expect(page.getByTestId("ticket-run-tray")).toContainText("Running");
  // Give a late hand-off the chance to show before checking it never did.
  await page.waitForTimeout(600);
  await expect(page.getByTestId("ticket-run-handoff")).toHaveCount(0);
});

// A card offering WEB-3, WEB-4 and WEB-5: WEB-4 waits for WEB-3; WEB-5 has no agent, so
// dispatch would refuse it. Each start adds its run to the tray.
async function offerSeveral(page: Page) {
  const titles: Record<string, string> = { "WEB-3": "Fix payouts", "WEB-4": "Payout report", "WEB-5": "Nobody's yet" };
  const offers: Record<string, Record<string, unknown>> = {
    "WEB-3": preview(),
    "WEB-4": { ...preview(), ticket_key: "WEB-4", queued_behind: ["Blocked by WEB-3 — Fix payouts (todo); it must be Done"] },
    "WEB-5": { ...preview(["WEB-5 has no agent assigned."]), ticket_key: "WEB-5" },
  };
  const state: { runs: Record<string, unknown>[]; starts: { ticket: string; message_id: string }[] } = { runs: [], starts: [] };
  await installChatApi(page, { replyDelayMs: 10 });
  await page.route(/\/api\/v1\/tickets\/(WEB-\d+)\/dispatch$/, (route: Route) => route.fulfill({ json: offers[route.request().url().match(/(WEB-\d+)\/dispatch$/)![1]] }));
  await page.route(/\/api\/v1\/tickets\/(WEB-\d+)$/, (route: Route) => {
    const key = route.request().url().match(/(WEB-\d+)$/)![1];
    return route.fulfill({ json: { key, title: titles[key], status: "todo" } });
  });
  await page.route(/\/api\/v1\/chats\/[^/]+\/runs$/, (route: Route) => {
    const req = route.request();
    if (req.method() === "POST") {
      const body = req.postDataJSON();
      state.starts.push(body);
      const started = run({ run_id: crypto.randomUUID(), ticket: body.ticket, ticket_title: titles[body.ticket], state: "queued", steps_total: 0, steps_done: 0, current_step: undefined, message_id: body.message_id });
      state.runs = [...state.runs, started];
      return route.fulfill({ status: 201, json: started });
    }
    return route.fulfill({ json: { runs: state.runs } });
  });
  await page.goto("/chat");
  const box = page.getByRole("combobox", { name: "Message" });
  await box.fill("dispatch all: the payouts epic");
  await box.press("Enter");

  return { card: page.getByTestId("dispatch-card"), state };
}

test("one card offers several tickets, and Start all confirms which to start", async ({ page }) => {
  const { card, state } = await offerSeveral(page);
  await expect(card).toContainText("Start runs for 3 tickets?");
  const rows = card.getByTestId("dispatch-offer");
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText("Fix payouts");
  await expect(rows.nth(0)).toContainText("Ready");
  await expect(rows.nth(1)).toContainText("Waits for WEB-3");
  await expect(rows.nth(2)).toContainText("no agent assigned");

  // Start all only offers what dispatch would accept, and nothing starts until you confirm.
  await card.getByRole("button", { name: "Start all (2)…" }).click();
  const dialog = page.getByTestId("start-all-dialog");
  await expect(dialog.getByRole("heading")).toHaveText("Start 2 runs");
  await expect(dialog.getByRole("checkbox", { name: "Start WEB-5" })).toBeDisabled();
  expect(state.starts).toHaveLength(0);
  await page.waitForTimeout(400);
  await page.screenshot({ path: "/tmp/chat-dispatch-start-all.png" });

  // Leave one out, then start the rest.
  await dialog.getByRole("checkbox", { name: "Start WEB-4" }).uncheck();
  await dialog.getByRole("button", { name: "Start 1 run" }).click();
  await expect(dialog).toHaveCount(0);
  expect(state.starts.map((s) => s.ticket)).toEqual(["WEB-3"]);
  await expect(rows.nth(0)).toContainText("Queued", { timeout: 10000 });
  await expect(card).toContainText("1 of 3 started");

  // The card still offers what's left, and each start comes from the same reply.
  await card.getByRole("button", { name: "Start all (1)…" }).click();
  await page.getByTestId("start-all-dialog").getByRole("button", { name: "Start 1 run" }).click();
  await expect.poll(() => state.starts.map((s) => s.ticket)).toEqual(["WEB-3", "WEB-4"]);
  expect(new Set(state.starts.map((s) => s.message_id)).size).toBe(1);
  await expect(card).toContainText("2 of 3 started", { timeout: 10000 });
});

test("runs started together get one grouped hand-off instead of one per card", async ({ page }) => {
  const { card, state } = await offerSeveral(page);
  await card.getByRole("button", { name: "Start all (2)…" }).click();
  await page.getByTestId("start-all-dialog").getByRole("button", { name: "Start 2 runs" }).click();
  await expect.poll(() => state.starts.map((s) => s.ticket)).toEqual(["WEB-3", "WEB-4"]);

  // The two starts land in separate tray refreshes, yet join one hand-off with a lane each.
  const group = page.getByTestId("ticket-run-handoff-group");
  await expect(group).toContainText("Handing 2 tickets to @pike");
  await expect(group.getByTestId("handoff-lane")).toHaveText([/@pike\s*WEB-3/, /@pike\s*WEB-4/]);
  await expect(page.getByTestId("ticket-run-handoff")).toHaveCount(0);
  await page.waitForTimeout(1000);
  await page.screenshot({ path: "/tmp/chat-dispatch-handoff-group.png" });

  // Once it fades, the same graphic stays instead of a card per ticket.
  await expect(group).toHaveCount(0, { timeout: 5000 });
  const tray = page.getByTestId("ticket-run-group");
  await expect(tray.getByTestId("group-lane")).toHaveText([/@pike\s*WEB-3/, /@pike\s*WEB-4/]);
  await expect(page.getByTestId("ticket-run")).toHaveCount(0);

  // Ticket status flies out on demand, one card per run.
  await tray.getByRole("button", { name: "Ticket status" }).click();
  const flyout = page.getByTestId("ticket-run-flyout");
  await expect(flyout.getByTestId("ticket-run")).toHaveCount(2);
  await expect(flyout.getByTestId("ticket-run").nth(0)).toContainText("Fix payouts");
  await expect(flyout.getByTestId("ticket-run").nth(1)).toContainText("Payout report");
  await page.screenshot({ path: "/tmp/chat-dispatch-group-flyout.png" });
  await page.keyboard.press("Escape");
  await expect(flyout).toHaveCount(0);
});

test("two trays share the status slot: the run shows, the queued follow-up expands from +1 more", async ({ page }) => {
  const state: State = { runs: [run()], starts: [], cancels: 0, blockers: [] };
  const followups = [{ id: "f0000000-0000-4000-8000-000000000001", body: "Also update the changelog", created_at: now() }];
  const card = await offer(page, state, () => page.route(/\/api\/v1\/chats\/[^/]+\/followups$/, (route: Route) => route.fulfill({ json: { followups } })));

  const slot = page.getByTestId("status-slot");
  await expect(slot.getByTestId("ticket-run-tray")).toBeVisible();
  // Both are live status; the run is listed first, so the follow-up collapses behind "+1 more".
  await expect(slot.getByTestId("followup-tray")).toBeHidden();
  const more = slot.getByTestId("status-slot-more");
  await expect(more).toContainText("+1 more");
  await expect(more).toContainText("1 queued");
  await expect(more).toHaveAttribute("aria-expanded", "false");

  await more.click();
  await expect(more).toHaveAttribute("aria-expanded", "true");
  await expect(more).toContainText("Show less");
  const tray = slot.getByTestId("followup-tray");
  await expect(tray).toBeVisible();
  await expect(slot.getByTestId("ticket-run-tray")).toBeVisible();

  // The tray's own actions still work from the slot.
  await tray.getByRole("button", { name: "Send now" }).click();
  await expect.poll(() => card.mock.posted.map((p) => (p.body as { body?: string }).body)).toContain("Also update the changelog");

  await more.click();
  await expect(slot.getByTestId("followup-tray")).toBeHidden();
  await expect(more).toContainText("+1 more");
});
