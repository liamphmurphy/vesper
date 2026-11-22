import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";

// LAZYAGENTS-46: the unified Inbox triages every human gate from one list.
type S = components["schemas"];

const project: S["Project"] = { id: "project-web", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
const atlas: S["AgentRef"] = { id: "aaaaaaaa-0000-4000-8000-000000000001", name: "Atlas", handle: "atlas", color_index: 0 };
const quill: S["AgentRef"] = { id: "aaaaaaaa-0000-4000-8000-000000000002", name: "Quill", handle: "quill", color_index: 1 };
const sentry: S["AgentRef"] = { id: "aaaaaaaa-0000-4000-8000-000000000003", name: "Sentry", handle: "sentry", color_index: 2 };
const echo: S["AgentRef"] = { id: "aaaaaaaa-0000-4000-8000-000000000004", name: "Echo", handle: "echo", color_index: 7 };
const APPROVAL = "bbbbbbbb-0000-4000-8000-000000000001";
const QUESTION_RUN = "cccccccc-0000-4000-8000-000000000002";
const FAILED_RUN = "cccccccc-0000-4000-8000-000000000003";
const APPROVAL_RUN = "cccccccc-0000-4000-8000-000000000004";
const MOCKUP = "dddddddd-0000-4000-8000-000000000001";
const MOCKUP_VERSION = "dddddddd-0000-4000-8000-000000000002";
const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();

function items(): S["InboxItem"][] {
  const base = { project: "WEB", resolved: false, read: false, needs_you: true };
  return [
    { ...base, id: `approval:${APPROVAL}`, kind: "approval", title: "Partition ledger entries", summary: "Run 0042_partition_ledger_entries on staging", href: "/tickets/WEB-1", ticket_key: "WEB-1", created_at: minutesAgo(12), agent: atlas, run_id: APPROVAL_RUN },
    { ...base, id: `question:${QUESTION_RUN}`, kind: "question", title: "Retry policy for payouts", summary: "Should retries cap at 5 or 8?", href: `/runs/${QUESTION_RUN}`, ticket_key: "WEB-2", created_at: minutesAgo(18), agent: quill, run_id: QUESTION_RUN },
    { ...base, id: `blocked:${FAILED_RUN}`, kind: "blocked", title: "Session refresh on iOS", summary: "Harness error: secret apple-sandbox-creds isn’t granted", href: `/runs/${FAILED_RUN}`, ticket_key: "WEB-3", created_at: minutesAgo(300), agent: sentry, run_id: FAILED_RUN },
    { ...base, id: `mockup:${MOCKUP_VERSION}`, kind: "mockup", title: "Unified Inbox mockup", summary: "Mockup v2 is waiting for your approval", href: `/artifacts/${MOCKUP}/review`, ticket_key: "WEB-4", created_at: minutesAgo(120), agent: echo, artifact_id: MOCKUP },
  ];
}

async function installInboxApi(page: Page) {
  let inbox = items();
  const comments: Array<{ key: string; body_md: string }> = [];
  const reads: string[] = [];
  const decisions: Array<{ path: string; body: unknown }> = [];
  const approval: S["Approval"] = {
    id: APPROVAL, run_id: APPROVAL_RUN, ticket_key: "WEB-1", agent: atlas, scope: "db:migrate", action_summary: "Run 0042_partition_ledger_entries on staging",
    action_detail: {}, action_preview: "ALTER TABLE ledger_entries …", risk_summary: "Dry run finished with no long locks", state: "pending", brokered: true, created_at: minutesAgo(12),
  };
  const ticket = {
    id: "ticket-1", key: "WEB-1", project, title: "Partition ledger entries", status: "in_progress", description_md: "", priority: "medium", labels: [],
    revision: 1, dependency_revision: 1, blocked_by: [], blocks: [], criteria: [], artifacts: [], approvals: [approval], requires_mockup: false,
    mockup_gate: { required: false, from_epic: false, approved: false, mockups: [] }, created_at: minutesAgo(60), updated_at: minutesAgo(12),
  };
  const open = () => inbox.filter((i) => !i.resolved && !i.read).length;
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
    const path = new URL(request.url()).pathname.replace(/^\/api\/v1/, "");
    const method = request.method();
    const json = (data: unknown, status = 200) => route.fulfill({ status, json: data });
    if (path === "/bootstrap") return json({
      workspace: { id: "workspace", name: "Vesper", slug: "lazyagents" },
      me: { id: "user", name: "Liam", email: "liam@example.com", initials: "LM", role_title: "Owner" },
      users: [], agents: [], epics: [], projects: [project], labels: [],
      counts: { inbox: open(), needs_you: open(), wiki_suggestions: 0, live_agents: 0 },
    } satisfies S["Bootstrap"]);
    if (path === "/inbox") return json({ items: inbox });
    if (path === "/inbox/read" && method === "POST") {
      const { id } = request.postDataJSON() as { id: string };
      reads.push(id);
      inbox = inbox.map((i) => (i.id === id ? { ...i, read: true } : i));
      return route.fulfill({ status: 204 });
    }
    if (path === "/tickets/WEB-1") return json(ticket);
    if (path === "/tickets/WEB-2/comments" && method === "POST") {
      comments.push({ key: "WEB-2", ...(request.postDataJSON() as { body_md: string }) });
      return json({ id: "event-1", verb: "commented", payload: {}, created_at: new Date().toISOString() }, 201);
    }
    if (path === `/approvals/${APPROVAL}/approve` && method === "POST") {
      decisions.push({ path, body: request.postDataJSON() });
      approval.state = "approved";
      inbox = inbox.map((i) => (i.kind === "approval" ? { ...i, resolved: true } : i));
      return json(approval);
    }
    if (path === `/artifacts/${MOCKUP}/versions/${MOCKUP_VERSION}/review` && method === "POST") {
      decisions.push({ path, body: request.postDataJSON() });
      inbox = inbox.map((i) => (i.kind === "mockup" ? { ...i, resolved: true } : i));
      return json({ id: MOCKUP });
    }
    if (path === "/runner") return json({ online: true, runners: [], slots: 3, busy: 1, live: 1, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 } satisfies S["RunnerStatus"]);
    if (path === "/agent-overviews") return json({
      agents: [{
        agent: { ...atlas, kind: "main", role: "Tech lead", specialty: "", model: "opus", status: "running" },
        max_concurrency: 1, harness: "claude-code", planning_runs: [], queue: [], queue_count: 0, scopes: [],
        stats: { completed: 0, median_cycle_seconds: null, merged_prs: 0, closed_prs: 0, spend_usd: 0 },
        assignments: [{
          run_id: "eeeeeeee-0000-4000-8000-000000000001", ticket: { id: "ticket-9", key: "WEB-9", title: "Stripe webhook endpoint", status: "in_progress", priority: "medium" },
          state: "running", harness: "claude-code", model: "opus", started_at: minutesAgo(24), step: "", step_position: 0, steps_done: 0, steps_total: 0,
        }],
      }],
    });
    return json({ code: "not_found", message: `mock: no handler for ${method} ${path}` }, 404);
  });
  return {
    comments, reads, decisions,
    /** The server's side of a change: the item is gone, and SSE says so. */
    async resolve(page: Page, id: string, type: string) {
      inbox = inbox.filter((i) => i.id !== id);
      await page.evaluate((t) => {
        const streams = (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse;
        for (const s of streams) s.onmessage?.({ data: JSON.stringify({ type: t }) });
      }, type);
    },
  };
}

const list = (page: Page) => page.getByRole("region", { name: "Inbox" });
const row = (page: Page, key: string) => list(page).getByRole("button").filter({ hasText: key });
const selectedRow = (page: Page) => list(page).locator('[aria-current="true"]');

test("triage from the keyboard: answer an await_human question, mark done, approve, then all clear", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  const api = await installInboxApi(page);
  await page.goto("/inbox");

  // Grouped in urgency order; each row shows type, ticket, agent and wait time.
  await expect(list(page).getByRole("group")).toHaveCount(4);
  await expect(list(page).locator('[role="group"] > h2')).toHaveText([/^Approvals/, /^Questions/, /^Failed & stalled runs/, /^Mockups/]);
  await expect(row(page, "WEB-2")).toContainText("Question");
  await expect(row(page, "WEB-2")).toContainText("Quill · Should retries cap at 5 or 8?");
  await expect(row(page, "WEB-2")).toContainText("18m");
  await expect(row(page, "WEB-3")).toContainText("Failed");
  await expect(row(page, "WEB-3")).toContainText("5h");
  await expect(page.getByRole("button", { name: "Needs you, 4 waiting" })).toBeVisible();

  // The first item is selected and focused; j moves to the question.
  await expect(selectedRow(page)).toContainText("WEB-1");
  await expect(selectedRow(page)).toBeFocused();
  await page.keyboard.press("j");
  await expect(selectedRow(page)).toContainText("WEB-2");
  const pane = page.getByRole("complementary", { name: "Question details" });
  await expect(pane.getByRole("heading", { name: "Quill is asking you" })).toBeVisible();
  await expect(pane.getByText("Should retries cap at 5 or 8?", { exact: true })).toBeVisible();

  // r focuses the reply; ⌘/Ctrl+Enter posts it as a comment mentioning the agent.
  await page.keyboard.press("r");
  const reply = pane.getByRole("textbox", { name: "Reply to @quill" });
  await expect(reply).toBeFocused();
  await reply.fill("Use 5. The appendix is outdated.");
  await page.keyboard.press("ControlOrMeta+Enter");
  await expect.poll(() => api.comments).toEqual([{ key: "WEB-2", body_md: "@quill Use 5. The appendix is outdated." }]);
  await expect(row(page, "WEB-2")).toContainText("Sent");

  // The run resumes and the live update removes the item; focus takes its slot.
  await api.resolve(page, `question:${QUESTION_RUN}`, "run.updated");
  await expect(row(page, "WEB-2")).toHaveCount(0);
  await expect(selectedRow(page)).toContainText("WEB-3");
  await expect(selectedRow(page)).toBeFocused();

  // e marks the failed run done: it moves to Done and the mockup takes the slot.
  await page.keyboard.press("e");
  await expect.poll(() => api.reads).toEqual([`blocked:${FAILED_RUN}`]);
  await expect(row(page, "WEB-3")).toHaveCount(0);
  await expect(selectedRow(page)).toContainText("WEB-4");

  // k back to the approval; a approves it from the pane.
  await page.keyboard.press("k");
  await expect(selectedRow(page)).toContainText("WEB-1");
  await expect(page.getByRole("complementary", { name: "Approval details" }).getByRole("button", { name: /Approve & continue/ })).toBeVisible();
  await page.keyboard.press("a");
  await expect.poll(() => api.decisions.map((d) => d.path)).toEqual([`/approvals/${APPROVAL}/approve`]);
  await expect(row(page, "WEB-1")).toHaveCount(0);

  // Approve the mockup from its pane.
  await expect(selectedRow(page)).toContainText("WEB-4");
  await page.getByRole("complementary", { name: "Mockup details" }).getByRole("button", { name: /^Approve/ }).click();
  await expect.poll(() => api.decisions.at(-1)).toEqual({ path: `/artifacts/${MOCKUP}/versions/${MOCKUP_VERSION}/review`, body: { decision: "approved" } });

  // Nothing left: all clear, with what is still running.
  await expect(page.getByRole("heading", { name: "All clear" })).toBeVisible();
  const running = page.getByRole("region", { name: "Still running" });
  await expect(running.getByRole("link", { name: /WEB-9.*Stripe webhook endpoint.*Atlas/ })).toBeVisible();
  await page.getByRole("button", { name: "3 done · Show done" }).click();
  await expect(list(page).getByRole("group")).toHaveCount(3);
});

test("the shortcut overlay lists the Inbox keys", async ({ page }) => {
  await installInboxApi(page);
  await page.goto("/inbox");
  await expect(selectedRow(page)).toBeFocused();
  await page.keyboard.press("?");
  const overlay = page.getByRole("dialog", { name: "Keyboard shortcuts" });
  const inboxKeys = overlay.getByRole("region", { name: "Inbox" });
  for (const label of ["Next / previous item", "Approve (approvals, mockups)", "Reply (questions) or focus the note", "Mark done: hide until it changes"]) {
    await expect(inboxKeys.getByText(label)).toBeVisible();
  }
  // Inbox keys are off while the overlay is open.
  await page.keyboard.press("j");
  await page.keyboard.press("Escape");
  await expect(overlay).toHaveCount(0);
  await expect(selectedRow(page)).toContainText("WEB-1");
  await page.getByRole("button", { name: /Shortcuts/ }).click();
  await expect(overlay).toBeVisible();
});
