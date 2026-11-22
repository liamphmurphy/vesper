import { expect, test, type Page } from "@playwright/test";
import type { Schemas } from "../lib/api/client";
import { installChatApi } from "./mock-chat-api";

// VESPER-15: the compact Runs list and run detail (project "mobile", 390×844).
const WAITING = "00000000-0000-4000-8000-000000000201";
const APPROVING = "00000000-0000-4000-8000-000000000202";
const DONE = "00000000-0000-4000-8000-000000000203";
const FAILED = "00000000-0000-4000-8000-000000000204";
const OLD = "00000000-0000-4000-8000-000000000205";

const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();
const step = (position: number, state: Schemas["PlanStep"]["state"], text: string): Schemas["PlanStep"] => ({ position, state, text });

function run(id: string, over: Partial<Schemas["Run"]>): Schemas["Run"] {
  return {
    id, ticket_key: "WEB-7", work_title: "Payout retries", purpose: "ticket", agent: { id, name: "Quill", handle: "quill", color_index: 2 },
    mode: "managed", state: "running", harness: "claude-code", model: "opus", started_at: minutesAgo(12),
    tool_calls: 3, input_tokens: 0, output_tokens: 0, cost_usd: 0, plan: [], scopes: [], approval_scopes: [], ...over,
  };
}

const plan = [step(1, "done", "Read the payout code"), step(2, "current", "Ask about the retry cap"), step(3, "pending", "Change the cap"), step(4, "pending", "Open the PR")];
const waiting = run(WAITING, { state: "waiting", wait_reason: "human_reply", plan });
const approving = run(APPROVING, {
  ticket_key: "WEB-8", work_title: "Partition ledger entries", agent: { id: APPROVING, name: "Atlas", handle: "atlas", color_index: 0 },
  state: "waiting", wait_reason: "approval", plan: [step(1, "done", "Write the migration"), step(2, "current", "Run it on staging")],
});
const done = run(DONE, { ticket_key: "WEB-3", work_title: "Session refresh", state: "completed", started_at: minutesAgo(50), ended_at: minutesAgo(5) });
const failed = run(FAILED, { ticket_key: "WEB-4", work_title: "Webhook signatures", state: "failed", started_at: minutesAgo(40), ended_at: minutesAgo(1) });
const old = run(OLD, { ticket_key: "WEB-1", work_title: "Long ago", state: "completed", started_at: "2020-01-01T09:00:00Z", ended_at: "2020-01-01T10:00:00Z" });

const question = "Should payout retries cap at 5 or 8?";
const events = (seq: number): Schemas["RunEvent"][] => [
  { seq: 1, type: "message", at: minutesAgo(10), payload: { text: "Reading internal/payouts/retry.go and its very long helper names like retryWithExponentialBackoffAndJitterForPayoutProviders" } },
  { seq: 2, type: "tool_call", at: minutesAgo(9), payload: { id: "t1", tool: "Bash", input: { command: "go test ./internal/payouts/... -run TestRetryWithExponentialBackoffAndJitterForPayoutProviders -count=1" } } },
  { seq: 3, type: "tool_result", at: minutesAgo(9), payload: { id: "t1", output: "ok" } },
  { seq, type: "lifecycle", at: minutesAgo(2), payload: { state: "waiting", reason: question } },
];

async function installRuns(page: Page) {
  await installChatApi(page);
  const replies: string[] = [];
  await page.route((url) => url.pathname.startsWith("/api/v1/runs") || /^\/api\/v1\/tickets\/[^/]+\/comments$/.test(url.pathname), async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    if (url.pathname === "/api/v1/runs") {
      const state = url.searchParams.get("state");
      const runs = state === "live" ? [waiting, approving] : [waiting, approving, failed, done, old];
      return route.fulfill({ json: { runs, has_more: false } });
    }
    if (url.pathname.endsWith("/comments") && req.method() === "POST") {
      replies.push((req.postDataJSON() as { body_md: string }).body_md);
      return route.fulfill({ status: 201, json: { id: "c1", body_md: replies.at(-1), created_at: new Date().toISOString() } });
    }
    const id = url.pathname.split("/").at(-1)!;
    const after = Number(url.searchParams.get("after") ?? 0);
    const r = id === APPROVING ? approving : waiting;
    const approvals: Schemas["Approval"][] = id === APPROVING ? [{
      id: "a1", run_id: APPROVING, ticket_key: "WEB-8", agent: approving.agent, scope: "db:migrate", action_summary: "Run 0042_partition_ledger_entries on staging",
      action_detail: {}, action_preview: "ALTER TABLE ledger_entries …", risk_summary: "Dry run finished with no long locks", state: "pending", brokered: true, created_at: minutesAgo(3),
    } as Schemas["Approval"]] : [];
    return route.fulfill({ json: { run: r, child_runs: [], turns: [], approvals, events: events(4).filter((e) => e.seq > after) } });
  });
  return { replies };
}

test("a waiting run is full screen and takes a reply from the pinned composer", async ({ page }) => {
  const api = await installRuns(page);
  await page.goto(`/runs/${WAITING}`);

  await expect(page.getByRole("heading", { name: "Payout retries" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Back to runs" })).toHaveAttribute("href", "/runs");
  // 44px touch targets, written in px: the root font is 13px, so size-11 would be 35.75px.
  for (const target of [page.getByRole("link", { name: "Back to runs" }), page.getByRole("button", { name: "Run actions" })]) {
    const box = (await target.boundingBox())!;
    expect(Math.min(box.width, box.height)).toBeGreaterThanOrEqual(44);
  }
  await expect(page.getByRole("navigation", { name: "Primary" })).toHaveCount(0);
  const strip = page.getByRole("list", { name: "Plan steps" });
  await expect(strip.getByRole("listitem")).toHaveCount(4);
  await expect(strip.locator('[data-state="done"]')).toHaveCount(1);
  await expect(strip.locator('[data-state="current"]')).toHaveCount(1);
  const log = page.getByRole("log", { name: "Run log" });
  await expect(log.getByText(question)).toBeVisible();
  await log.getByRole("button", { name: /Bash/ }).click();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);

  await page.screenshot({ path: "test-results/run-detail-mobile.png" });
  const composer = page.getByRole("form", { name: "Reply to Quill" });
  const box = await composer.boundingBox();
  expect(Math.round(box!.y + box!.height)).toBe(844);
  await composer.getByRole("textbox", { name: "Reply to Quill" }).fill("Cap them at 5.");
  await composer.getByRole("button", { name: "Send" }).click();
  await expect(composer.getByRole("status")).toHaveText(/Sent\. Resuming Quill/);
  expect(api.replies).toEqual(["@quill Cap them at 5."]);

  // The ··· menu carries the run's actions.
  await page.getByRole("button", { name: "Run actions" }).click();
  await expect(page.getByRole("menuitem", { name: "Open ticket" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Cancel run" })).toBeVisible();
});

test("a run waiting on an approval shows it inline in the log", async ({ page }) => {
  await installRuns(page);
  await page.goto(`/runs/${APPROVING}`);
  const log = page.getByRole("log", { name: "Run log" });
  const card = log.getByRole("group", { name: "Needs attention" });
  await expect(card).toContainText("Run 0042_partition_ledger_entries on staging");
  await expect(card.getByRole("button", { name: "Approve" })).toBeVisible();
  await expect(card.getByRole("button", { name: "Deny" })).toBeVisible();
  await expect(page.getByRole("form", { name: /Reply to/ })).toHaveCount(0);
  await page.screenshot({ path: "test-results/run-approval-mobile.png" });
});

test("a run's Chat button opens your persona's work chat in a sheet, beside the reply to the agent", async ({ page }) => {
  await installRuns(page);
  await page.route("**/api/v1/dock-chats?*", (route) => route.fulfill({ json: { chats: [] } }));
  await page.goto(`/runs/${APPROVING}`);
  await page.getByRole("button", { name: "Chat with your persona about this run" }).click();
  const sheet = page.getByRole("dialog", { name: "Chat" });
  await expect(sheet.getByTestId("work-chat-subject")).toContainText("Viewing:");
  await expect(sheet.getByTestId("dock-chat-to")).toBeVisible();
});
