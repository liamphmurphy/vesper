import { expect, test } from "@playwright/test";
import type { Schemas } from "../lib/api/client";
import { installChatApi } from "./mock-chat-api";

const parentId = "00000000-0000-4000-8000-000000000101";
const childId = "00000000-0000-4000-8000-000000000102";
const at = (n: number) => `2026-11-03T12:00:0${n}Z`;
const event = (seq: number, type: Schemas["RunEvent"]["type"], payload: Record<string, unknown>, second: number): Schemas["RunEvent"] => ({ seq, type, payload, at: at(second) });

function run(id: string, name: string): Schemas["Run"] {
  return {
    id, ticket_key: "WEB-1", purpose: "ticket", agent: { id, name, handle: name.toLowerCase(), color_index: 0 },
    mode: "managed", state: "completed", harness: "codex", model: "test-model", started_at: at(0), ended_at: at(7),
    tool_calls: 1, input_tokens: 0, output_tokens: 0, cost_usd: 0, plan: [], scopes: [], approval_scopes: [],
  };
}

test("parent timeline includes historical and live delegated logs with independent cursors", async ({ page }) => {
  await installChatApi(page);
  const parent = run(parentId, "Lead");
  const child = { ...run(childId, "Reviewer"), parent_run_id: parentId };
  const parentEvents = [
    event(1, "tool_call", { id: "same-tool-id", tool: "parent_command", input: {} }, 0),
    event(2, "message", { text: "Parent is waiting" }, 1),
    event(3, "tool_result", { id: "same-tool-id", output: "parent output" }, 6),
  ];
  const childEvents = [
    event(1, "tool_call", { id: "same-tool-id", tool: "child_command", input: {} }, 2),
    event(2, "message", { text: "Delegated review findings" }, 3),
    event(3, "tool_result", { id: "same-tool-id", output: "child output" }, 4),
  ];
  const cursors: Record<string, number[]> = { [parentId]: [], [childId]: [] };
  await page.route("**/api/v1/runs/*", async (route) => {
    const url = new URL(route.request().url());
    const id = url.pathname.split("/").at(-1)!;
    const after = Number(url.searchParams.get("after") ?? 0);
    cursors[id].push(after);
    const isParent = id === parentId;
    await route.fulfill({ json: {
      run: isParent ? parent : child, child_runs: isParent ? [child] : [], turns: [], approvals: [],
      events: (isParent ? parentEvents : childEvents).filter((e) => e.seq > after),
    } });
  });
  await page.goto(`/runs/${parentId}?view=details`);
  await expect(page.getByRole("link", { name: "Environment", exact: true })).toHaveAttribute("href", `/settings/runner?run_id=${parentId}`);
  const timeline = page.getByRole("region", { name: "Events" });
  await expect(timeline.getByText("Delegated review findings", { exact: true })).toBeVisible();
  // Tool results are collapsed until a row (or Expand all) opens them.
  await timeline.getByRole("button", { name: "Expand all" }).click();
  await expect(timeline.getByText("parent output", { exact: true })).toBeVisible();
  await expect(timeline.getByText("child output", { exact: true })).toBeVisible();
  await expect(timeline.getByRole("link", { name: "Reviewer · delegated agent" }).first()).toHaveAttribute("href", `/runs/${childId}`);
  await expect(timeline.locator("li")).toHaveCount(4);

  // Child events invalidate and append even when the parent is already terminal.
  childEvents.push(event(4, "message", { text: "Later delegated update" }, 7));
  await page.evaluate(() => {
    const streams = (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse;
    for (const stream of streams) stream.onmessage?.({ data: JSON.stringify({ type: "run.events" }) });
  });
  await expect(timeline.getByText("Later delegated update", { exact: true })).toBeVisible();
  expect(cursors[parentId]).toContain(3);
  expect(cursors[childId]).toContain(3);
  await expect(timeline.getByText("Delegated review findings", { exact: true })).toHaveCount(1);
  await timeline.getByRole("textbox", { name: "Filter events" }).fill("Reviewer");
  await expect(timeline.getByText("Parent is waiting", { exact: true })).toHaveCount(0);
  await expect(timeline.getByText("Delegated review findings", { exact: true })).toBeVisible();
  await page.reload();
  await expect(timeline.getByText("Later delegated update", { exact: true })).toBeVisible();
});

test("a run shows its harness and model; usage without cost source is unknown", async ({ page }) => {
  await installChatApi(page);
  const codexRun = { ...run(parentId, "Lead"), harness: "codex" as const, model: "gpt-5-codex" };
  await page.route("**/api/v1/runs/*", (route) =>
    route.fulfill({ json: {
      run: codexRun, child_runs: [], turns: [], approvals: [],
      events: [event(1, "usage", { input_tokens: 10, output_tokens: 5, cost_usd: 0 }, 1)],
    } }),
  );
  await page.goto(`/runs/${parentId}?view=details`);
  await expect(page.getByText("codex", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("gpt-5-codex").first()).toBeVisible();
  const timeline = page.getByRole("region", { name: "Events" });
  await expect(timeline.getByText(/turn total/)).toContainText("Unknown");
  await expect(timeline.getByText("$0.00")).toHaveCount(0);
});

test("run usage separates cached, uncached and unreported input in the Context dock and renders Trace messages as Markdown", async ({ page }) => {
  await installChatApi(page);
  const usage = {
    ...run(parentId, "Lead"),
    input_tokens: 1000,
    output_tokens: 100,
    cached_input_tokens: 900,
    uncached_input_tokens: 50,
    unreported_input_tokens: 50,
    plan: [{ position: 1, state: "done" as const, text: "Verify token breakdown" }],
  };
  await page.route("**/api/v1/runs/*", (route) => route.fulfill({ json: {
    run: usage, child_runs: [], turns: [], approvals: [],
    events: [
      event(1, "message", { text: "Added **Status line** in `drive-backup.ts`." }, 0),
      event(2, "usage", { input_tokens: 1000, output_tokens: 100, cached_tokens: 900, cache_reported_input_tokens: 950 }, 1),
    ],
  } }));
  await page.goto(`/runs/${parentId}?view=details`);
  const ctx = page.getByRole("tabpanel", { name: "Context" });
  const breakdown = ctx.getByLabel("Token breakdown");
  await expect(breakdown).toContainText("Cached input");
  await expect(breakdown).toContainText("900");
  await expect(breakdown).toContainText("Uncached input");
  await expect(breakdown).toContainText("50");
  await expect(breakdown).toContainText("Cache breakdown unavailable for 50 input");
  await expect(breakdown).toContainText("Total includes cached input");
  await expect(ctx.getByRole("region", { name: "Plan" })).toContainText("Verify token breakdown");
  await expect(page.getByRole("complementary", { name: "Run summary" })).toHaveCount(0);
  const events = page.getByRole("region", { name: "Events" });
  await expect(events).toContainText("900 cached");
  await expect(events.locator("strong", { hasText: "Status line" })).toBeVisible();
  await expect(events.locator("code", { hasText: "drive-backup.ts" })).toBeVisible();
  await page.screenshot({ path: "test-results/token-breakdown.png", fullPage: true });
});
