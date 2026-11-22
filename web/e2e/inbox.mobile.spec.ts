import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";

// VESPER-14: the compact Inbox (project "mobile", 390×844) is a list of cards with an approval sheet.
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
// Long enough to scroll sideways and to offer the full-screen view.
const PREVIEW = Array.from({ length: 12 }, (_, i) => `ALTER TABLE ledger_entries_p${i} ATTACH PARTITION ledger_entries FOR VALUES FROM ('2026-${String(i + 1).padStart(2, "0")}-01');`).join("\n");

async function installInboxApi(page: Page) {
  const base = { project: "WEB", resolved: false, read: false, needs_you: true };
  const inbox: S["InboxItem"][] = [
    { ...base, id: `approval:${APPROVAL}`, kind: "approval", title: "Partition ledger entries", summary: "Run 0042_partition_ledger_entries on staging", href: "/tickets/WEB-1", ticket_key: "WEB-1", created_at: minutesAgo(12), agent: atlas, run_id: APPROVAL_RUN },
    { ...base, id: `question:${QUESTION_RUN}`, kind: "question", title: "Retry policy for payouts", summary: "Should retries cap at 5 or 8?", href: `/runs/${QUESTION_RUN}`, ticket_key: "WEB-2", created_at: minutesAgo(18), agent: quill, run_id: QUESTION_RUN },
    { ...base, id: `blocked:${FAILED_RUN}`, kind: "blocked", title: "Session refresh on iOS", summary: "Harness error: secret apple-sandbox-creds isn’t granted", href: `/runs/${FAILED_RUN}`, ticket_key: "WEB-3", created_at: minutesAgo(300), agent: sentry, run_id: FAILED_RUN },
    { ...base, id: `mockup:${MOCKUP_VERSION}`, kind: "mockup", title: "Unified Inbox mockup", summary: "Mockup v2 is waiting for your approval", href: `/artifacts/${MOCKUP}/review`, ticket_key: "WEB-4", created_at: minutesAgo(120), agent: echo, artifact_id: MOCKUP },
  ];
  const comments: Array<{ key: string; body_md: string }> = [];
  const decisions: string[] = [];
  const approval: S["Approval"] = {
    id: APPROVAL, run_id: APPROVAL_RUN, ticket_key: "WEB-1", agent: atlas, scope: "db:migrate", action_summary: "Run 0042_partition_ledger_entries on staging",
    action_detail: {}, action_preview: PREVIEW, risk_summary: "Dry run finished with no long locks", state: "pending", brokered: true, created_at: minutesAgo(12),
  };
  const ticket = {
    id: "ticket-1", key: "WEB-1", project, title: "Partition ledger entries", status: "in_progress", description_md: "", priority: "medium", labels: [],
    revision: 1, dependency_revision: 1, blocked_by: [], blocks: [], criteria: [], artifacts: [], approvals: [approval], requires_mockup: false,
    mockup_gate: { required: false, from_epic: false, approved: false, mockups: [] }, created_at: minutesAgo(60), updated_at: minutesAgo(12),
  };
  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname.replace(/^\/api\/v1/, "");
    const method = request.method();
    const json = (data: unknown, status = 200) => route.fulfill({ status, json: data });
    if (path === "/bootstrap") return json({
      workspace: { id: "workspace", name: "Vesper", slug: "lazyagents" },
      me: { id: "user", name: "Liam", email: "liam@example.com", initials: "LM", role_title: "Owner" },
      users: [], agents: [], epics: [], projects: [project], labels: [],
      counts: { inbox: inbox.length, needs_you: inbox.length, wiki_suggestions: 0, live_agents: 0 },
    } satisfies S["Bootstrap"]);
    if (path === "/inbox") return json({ items: inbox });
    if (path === "/tickets/WEB-1") return json(ticket);
    if (path === "/tickets/WEB-2/comments" && method === "POST") {
      comments.push({ key: "WEB-2", ...(request.postDataJSON() as { body_md: string }) });
      return json({ id: "event-1", verb: "commented", payload: {}, created_at: new Date().toISOString() }, 201);
    }
    if (/^\/approvals\/[^/]+\/(approve|deny)$/.test(path) && method === "POST") {
      decisions.push(path);
      approval.state = path.endsWith("approve") ? "approved" : "denied";
      return json(approval);
    }
    if (path === "/runner") return json({ online: true, runners: [], slots: 3, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 } satisfies S["RunnerStatus"]);
    return json({ code: "not_found", message: `mock: no handler for ${method} ${path}` }, 404);
  });
  return { comments, decisions };
}

const list = (page: Page) => page.getByRole("region", { name: "Inbox" });
const card = (page: Page, name: RegExp) => list(page).getByRole("article", { name });

async function expectTouchSize(page: Page, locator: ReturnType<Page["locator"]>) {
  const box = await locator.boundingBox();
  expect(box!.height).toBeGreaterThanOrEqual(44);
}

test("cards show who, what and how long, with each kind's action", async ({ page }) => {
  await installInboxApi(page);
  await page.goto("/inbox");

  await expect(list(page).getByRole("article")).toHaveCount(4);
  const approval = card(page, /^Approval: Partition ledger entries/);
  for (const text of ["Atlas", "WEB-1", "12m", "Approval", "Partition ledger entries", "Run 0042_partition_ledger_entries on staging"]) {
    await expect(approval).toContainText(text);
  }
  await expect(card(page, /^Blocked: Session refresh on iOS/)).toContainText("5h");
  await expect(card(page, /^Mockup: /)).toContainText("Echo");

  // Approve and Deny are 44px tall and Approve is amber.
  for (const name of ["Deny", "Approve"]) await expectTouchSize(page, approval.getByRole("button", { name, exact: true }));
  await expect(approval.getByRole("button", { name: "Approve", exact: true })).toHaveClass(/bg-state-human/);
  await expect(card(page, /^Question: /).getByRole("textbox", { name: "Reply to @quill" })).toBeVisible();
  const openRun = card(page, /^Blocked: /).getByRole("link", { name: "Open run" });
  await expect(openRun).toHaveAttribute("href", `/runs/${FAILED_RUN}`);
  await expectTouchSize(page, openRun);

  // The chips filter the list.
  await page.getByRole("button", { name: /^Questions/ }).click();
  await expect(list(page).getByRole("article")).toHaveCount(1);
  await page.getByRole("button", { name: /^Blocked/ }).click();
  await expect(list(page).getByRole("article")).toHaveText([/Session refresh on iOS/]);
  await page.getByRole("button", { name: /^All/ }).click();
  await expect(list(page).getByRole("article")).toHaveCount(4);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test("approve one item from the approval sheet", async ({ page }) => {
  const api = await installInboxApi(page);
  await page.goto("/inbox");
  await card(page, /^Approval: /).getByRole("button", { name: /Partition ledger entries/ }).click();

  const sheet = page.getByRole("dialog", { name: "Approval" });
  await expect(sheet.getByRole("region", { name: "Action" })).toContainText("db:migrate Run 0042_partition_ledger_entries on staging");
  await expect(sheet.getByRole("region", { name: "Risk summary" })).toContainText("Dry run finished with no long locks");
  // The preview is monospace and scrolls sideways; a long one opens full screen.
  const preview = sheet.getByTestId("approval-preview");
  expect(await preview.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
  await sheet.getByRole("button", { name: "Full screen" }).click();
  const full = page.getByRole("dialog", { name: "Preview" });
  await expect(full).toContainText("ledger_entries_p11");
  await full.getByRole("button", { name: "Close preview" }).click();
  await expect(full).toHaveCount(0);

  // Deny and Approve are pinned to the bottom of the screen.
  const approve = sheet.getByRole("button", { name: "Approve", exact: true });
  await expectTouchSize(page, approve);
  await expectTouchSize(page, sheet.getByRole("button", { name: "Deny", exact: true }));
  const box = await approve.boundingBox();
  expect(box!.y + box!.height).toBeGreaterThan(844 - 80);

  await approve.click();
  await expect.poll(() => api.decisions).toEqual([`/approvals/${APPROVAL}/approve`]);
  await expect(sheet).toHaveCount(0);
  await expect(card(page, /^Approval: /)).toContainText("Sent");
});

test("answer a question from its card", async ({ page }) => {
  const api = await installInboxApi(page);
  await page.goto("/inbox");
  const question = card(page, /^Question: /);
  await question.getByRole("textbox", { name: "Reply to @quill" }).fill("Use 5. The appendix is outdated.");
  await question.getByRole("button", { name: "Send" }).click();
  await expect.poll(() => api.comments).toEqual([{ key: "WEB-2", body_md: "@quill Use 5. The appendix is outdated." }]);
  await expect(question).toContainText("Sent");
});

test("swiping an approval card neither approves nor denies", async ({ page }) => {
  const api = await installInboxApi(page);
  await page.goto("/inbox");
  const box = (await card(page, /^Approval: /).boundingBox())!;
  const y = box.y + 30;
  const cdp = await page.context().newCDPSession(page);
  for (const [from, to] of [[box.x + 20, box.x + box.width - 20], [box.x + box.width - 20, box.x + 20]]) {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: from, y }] });
    for (let i = 1; i <= 8; i++) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: from + ((to - from) * i) / 8, y }] });
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  }
  await page.waitForTimeout(300);
  expect(api.decisions).toEqual([]);
  await expect(card(page, /^Approval: /).getByRole("button", { name: "Approve", exact: true })).toBeEnabled();
});
