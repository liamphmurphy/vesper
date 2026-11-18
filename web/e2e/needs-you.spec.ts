import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";

// LAZYAGENTS-162: one Needs you queue in the sidebar, answerable from any page.
type S = components["schemas"];

const APPROVAL = "aaaaaaaa-0000-4000-8000-000000000001";
const APPROVAL_2 = "aaaaaaaa-0000-4000-8000-000000000002";
const RUN = "cccccccc-0000-4000-8000-000000000001";
const QUESTION_RUN = "cccccccc-0000-4000-8000-000000000002";
const atlas = { id: "agent-atlas", name: "Atlas", handle: "atlas", color_index: 0 };
const quill = { id: "agent-quill", name: "Quill", handle: "quill", color_index: 1 };
const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();

function items(): S["InboxItem"][] {
  const base = { project: "WEB", resolved: false, read: false };
  return [
    { ...base, needs_you: true, id: `approval:${APPROVAL}`, kind: "approval", title: "Partition ledger entries", summary: "Run 0042 on staging", href: "/tickets/WEB-1", ticket_key: "WEB-1", created_at: minutesAgo(30), agent: atlas, run_id: RUN },
    { ...base, needs_you: true, id: `approval:${APPROVAL_2}`, kind: "approval", title: "Drop old sessions", summary: "Delete 12k rows", href: "/tickets/WEB-1", ticket_key: "WEB-1", created_at: minutesAgo(20), agent: atlas, run_id: RUN },
    { ...base, needs_you: true, id: `question:${QUESTION_RUN}`, kind: "question", title: "Retry policy", summary: "Should retries cap at 5 or 8?", href: `/runs/${QUESTION_RUN}`, ticket_key: "WEB-2", created_at: minutesAgo(10), agent: quill, run_id: QUESTION_RUN },
    { ...base, needs_you: true, id: "mention:ask", kind: "mention", title: "Checkout copy", summary: "@liam which tone do you want?", href: "/tickets/WEB-3", ticket_key: "WEB-3", created_at: minutesAgo(5), agent: quill },
    { ...base, needs_you: false, id: "mention:fyi", kind: "mention", title: "Checkout copy", summary: "@liam FYI shipped.", href: "/tickets/WEB-3", ticket_key: "WEB-3", created_at: minutesAgo(4), agent: quill },
    { ...base, needs_you: false, id: "merged:1", kind: "merged", title: "Ledger partitions", summary: "Pull request #12 merged", href: "/tickets/WEB-4", ticket_key: "WEB-4", created_at: minutesAgo(3), agent: atlas },
    { ...base, needs_you: false, id: "scheduled:1", kind: "scheduled", title: "Daily digest", summary: "3 PRs merged yesterday", href: "/chat/c1", ticket_key: "", project: "", created_at: minutesAgo(2) },
  ];
}

async function installTray(page: Page) {
  const board = await installBoardApi(page);
  let inbox = items();
  const decisions: Array<{ path: string; body: unknown }> = [];
  const comments: Array<{ key: string; body_md: string }> = [];
  const reads: string[] = [];
  const needs = () => inbox.filter((i) => i.needs_you && !i.resolved && !i.read).length;
  board.counts.needs_you = needs();
  // Registered after the board mock, so these win for the paths they handle.
  await page.route(/\/api\/v1\/(inbox|approvals|tickets\/WEB-\d\/comments)/, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname.replace(/^\/api\/v1/, "");
    const method = request.method();
    if (path === "/inbox") return route.fulfill({ json: { items: inbox } });
    if (path === "/inbox/read" && method === "POST") {
      const { id } = request.postDataJSON() as { id: string };
      reads.push(id);
      inbox = inbox.map((i) => (i.id === id ? { ...i, read: true } : i));
      board.counts.needs_you = needs();
      return route.fulfill({ status: 204 });
    }
    const decided = /^\/approvals\/([^/]+)\/(approve|deny)$/.exec(path);
    if (decided && method === "POST") {
      decisions.push({ path, body: request.postDataJSON() });
      inbox = inbox.map((i) => (i.id === `approval:${decided[1]}` ? { ...i, resolved: true } : i));
      board.counts.needs_you = needs();
      return route.fulfill({ json: { id: decided[1], run_id: RUN, ticket_key: "WEB-1", agent: atlas, scope: "db:migrate", action_summary: "", action_detail: {}, state: decided[2] === "approve" ? "approved" : "denied", brokered: false, created_at: minutesAgo(1) } });
    }
    const commented = /^\/tickets\/(WEB-\d)\/comments$/.exec(path);
    if (commented && method === "POST") {
      comments.push({ key: commented[1], ...(request.postDataJSON() as { body_md: string }) });
      return route.fulfill({ status: 201, json: { id: "event-1", verb: "commented", payload: {}, created_at: new Date().toISOString() } });
    }
    return route.fallback();
  });
  return { board, decisions, comments, reads };
}

const pill = (page: Page) => page.getByRole("button", { name: /^Needs you,/ });
const tray = (page: Page) => page.getByRole("dialog", { name: "Needs you" });
const row = (page: Page, key: string) => page.locator(`main [data-ticket-row="${key}"]`);
const selected = (page: Page) => tray(page).locator('[data-tray-row][aria-current="true"]');

test("approve, deny and answer from the tray, with the badge counting only Needs you", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  const api = await installTray(page);
  await page.goto("/tickets?layout=board&project=WEB");
  // Four to act on; the FYI mention, the merged PR and the scheduled result are Updates and never counted.
  await expect(pill(page)).toHaveAccessibleName("Needs you, 4 waiting");
  await expect(page.getByRole("group", { name: "Work" }).getByRole("link", { name: /^Inbox/ })).toHaveCount(0);

  await pill(page).click();
  await expect(tray(page)).toBeVisible();
  const needs = tray(page).getByRole("tabpanel", { name: "Needs you" });
  await expect(needs.locator("[data-tray-row]")).toHaveCount(4);
  // The asking mention is under Needs you, with a link to open it.
  await expect(needs.locator('[data-tray-row="mention:ask"]')).toContainText("which tone do you want?");
  await expect(selected(page)).toContainText("Partition ledger entries");
  await expect(selected(page)).toBeFocused();
  await expect(selected(page)).toContainText("WEB-1 · Atlas · 30m");

  // A approves the selected approval.
  await page.keyboard.press("a");
  await expect.poll(() => api.decisions).toEqual([{ path: `/approvals/${APPROVAL}/approve`, body: {} }]);
  // The server's change arrives over SSE: the badge and the list update without a reload.
  await api.board.emit("approval.decided");
  await expect(pill(page)).toHaveAccessibleName("Needs you, 3 waiting");
  await expect(needs.locator("[data-tray-row]")).toHaveCount(3);

  // D on the next approval asks for an optional reason; Enter sends the denial with it.
  await expect(selected(page)).toContainText("Drop old sessions");
  await page.keyboard.press("d");
  const reason = tray(page).getByRole("textbox", { name: /Reason for denying/ });
  await expect(reason).toBeFocused();
  await reason.fill("Keep them for the audit");
  await page.keyboard.press("Enter");
  await expect.poll(() => api.decisions.at(-1)).toEqual({ path: `/approvals/${APPROVAL_2}/deny`, body: { note: "Keep them for the audit" } });
  await api.board.emit("approval.decided");
  await expect(pill(page)).toHaveAccessibleName("Needs you, 2 waiting");

  // The question's inline reply posts the Inbox's comment, mentioning the agent so the run resumes.
  await expect(selected(page)).toContainText("Retry policy");
  const reply = tray(page).getByRole("textbox", { name: "Reply to Quill" });
  // R focuses the reply; Esc in it goes back to the list without closing the tray.
  await page.keyboard.press("r");
  await expect(reply).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(tray(page)).toBeVisible();
  await expect(selected(page)).toBeFocused();
  await reply.fill("Cap at 5.");
  await reply.press("Enter");
  await expect.poll(() => api.comments).toEqual([{ key: "WEB-2", body_md: "@quill Cap at 5." }]);
  await expect(selected(page)).toContainText("Sent");

  // J/K move; Esc on the list closes the tray.
  await page.keyboard.press("j");
  await expect(selected(page)).toContainText("Checkout copy");
  await page.keyboard.press("k");
  await expect(selected(page)).toContainText("Retry policy");
  await page.keyboard.press("Escape");
  await expect(tray(page)).toHaveCount(0);
});

test("Updates: FYI items with a dot and no count, cleared one by one or all at once", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  const api = await installTray(page);
  await page.goto("/tickets?layout=board&project=WEB");
  await pill(page).click();
  await expect(selected(page)).toBeFocused();
  // → switches to Updates.
  await page.keyboard.press("ArrowRight");
  const updatesTab = tray(page).getByRole("tab", { name: /^Updates/ });
  await expect(updatesTab).toHaveAttribute("aria-selected", "true");
  await expect(updatesTab).toHaveText("Updates, unread");
  await expect(updatesTab.getByTestId("updates-dot")).toBeVisible();
  const updates = tray(page).getByRole("tabpanel", { name: "Updates" });
  await expect(updates.locator("[data-tray-row]")).toHaveText([/Daily digest/, /Ledger partitions.*Pull request #12 merged/, /Checkout copy.*FYI shipped/]);

  // The row's ✕ clears it (the Inbox's Done), and it leaves the list.
  await updates.locator('[data-tray-row="merged:1"]').getByRole("button", { name: "Clear Merged: Ledger partitions" }).click();
  await expect.poll(() => api.reads).toEqual(["merged:1"]);
  await expect(updates.locator("[data-tray-row]")).toHaveText([/Daily digest/, /Checkout copy.*FYI shipped/]);
  // The selection takes the cleared row's slot, focused, and X clears it.
  await expect(selected(page)).toContainText("FYI shipped");
  await expect(selected(page)).toBeFocused();
  await page.keyboard.press("x");
  await expect.poll(() => api.reads).toEqual(["merged:1", "mention:fyi"]);
  await expect(updates.locator("[data-tray-row]")).toHaveText([/Daily digest/]);

  await tray(page).getByRole("button", { name: "Clear all" }).click();
  await expect.poll(() => [...api.reads].sort()).toEqual(["mention:fyi", "merged:1", "scheduled:1"]);
  await expect(updates.locator("[data-tray-row]")).toHaveCount(0);
  await expect(updates.getByText("You’re all caught up")).toBeVisible();
  await expect(updatesTab.getByTestId("updates-dot")).toHaveCount(0);
  await expect(tray(page).getByRole("button", { name: "Clear all" })).toHaveCount(0);
  // Updates never change the badge.
  await expect(pill(page)).toHaveAccessibleName("Needs you, 4 waiting");

  // ← back, with the emptied list's focus fallen to the page.
  await page.keyboard.press("ArrowLeft");
  await expect(tray(page).getByRole("tab", { name: /^Needs you/ })).toHaveAttribute("aria-selected", "true");
  // Tab is not taken over: it moves into the selected row's buttons, so every control is reachable.
  await expect(selected(page)).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(selected(page).getByRole("button", { name: "Approve" })).toBeFocused();
  // An asking mention never resolves by itself: opening it from the tray reads it.
  await tray(page).locator('[data-tray-row="mention:ask"]').getByRole("link", { name: "Open" }).click();
  await expect.poll(() => api.reads).toContain("mention:ask");
  await expect(page).toHaveURL(/\/tickets\/WEB-3$/);
  await pill(page).click();
  await tray(page).getByRole("link", { name: "Open all →" }).click();
  await expect(page).toHaveURL(/\/work(\?[^#]*)?#needs-you$/);
  await expect(tray(page)).toHaveCount(0);
  await expect(page.getByRole("complementary", { name: "Runs" }).getByRole("region", { name: "Needs you" })).toBeInViewport();
});

test("a Needs you row clears one at a time, lowering the badge, with no Clear all", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  const api = await installTray(page);
  await page.goto("/tickets?layout=board&project=WEB");
  await pill(page).click();
  const needs = tray(page).getByRole("tabpanel", { name: "Needs you" });
  await expect(needs.locator("[data-tray-row]")).toHaveCount(4);
  // Bulk-clearing would hide runs still waiting: only Updates offers it.
  await expect(tray(page).getByRole("button", { name: "Clear all" })).toHaveCount(0);

  // X on the selected row; the next row takes its slot, focused, so X can keep going.
  await expect(selected(page)).toContainText("Partition ledger entries");
  await expect(selected(page)).toBeFocused();
  await page.keyboard.press("x");
  await expect.poll(() => api.reads).toEqual([`approval:${APPROVAL}`]);
  await expect(needs.locator("[data-tray-row]")).toHaveCount(3);
  await expect(selected(page)).toContainText("Drop old sessions");
  await expect(selected(page)).toBeFocused();
  await expect(pill(page)).toHaveAccessibleName("Needs you, 3 waiting");

  // The row's ✕ clears it too.
  await needs.locator('[data-tray-row="mention:ask"]').getByRole("button", { name: "Clear Mention: Checkout copy" }).click();
  await expect.poll(() => api.reads).toEqual([`approval:${APPROVAL}`, "mention:ask"]);
  await expect(needs.locator("[data-tray-row]")).toHaveCount(2);
  await expect(pill(page)).toHaveAccessibleName("Needs you, 2 waiting");
  // Clearing decided nothing: the approval itself was never sent.
  expect(api.decisions).toEqual([]);
});

test("a clear the server refuses puts the row back and says so", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  await installTray(page);
  await page.route(/\/api\/v1\/inbox\/read$/, (route) => route.fulfill({ status: 500, json: { error: { code: "internal", message: "boom" } } }));
  await page.goto("/tickets?layout=board&project=WEB");
  await pill(page).click();
  await expect(selected(page)).toBeFocused();
  await page.keyboard.press("x");
  await expect(tray(page).getByRole("alert")).toContainText("Couldn't mark item read");
  await expect(tray(page).getByRole("tabpanel", { name: "Needs you" }).locator("[data-tray-row]")).toHaveCount(4);
});

test("the tray opens from Chat, Tickets, Runs and an App page, on the rail too", async ({ page }) => {
  await installTray(page);
  await page.route("**/api/v1/runs?*", (route) => route.fulfill({ json: { runs: [], has_more: false } }));
  // The menu starts collapsed: the rail's icon carries the badge.
  for (const path of ["/chat", "/tickets", "/runs", "/apps/docs"]) {
    await page.goto(path);
    await expect(pill(page)).toHaveAccessibleName("Needs you, 4 waiting");
    await pill(page).click();
    await expect(tray(page).locator("[data-tray-row]")).toHaveCount(4);
    await page.keyboard.press("Escape");
    await expect(tray(page)).toHaveCount(0);
  }
  // Enter opens the selected item's page and closes the tray.
  await pill(page).click();
  await expect(selected(page)).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/tickets\/WEB-1$/);
  await expect(tray(page)).toHaveCount(0);
});

test("the shortcuts sheet lists the tray keys", async ({ page }) => {
  await installTray(page);
  await page.goto("/tickets");
  await expect(pill(page)).toBeVisible();
  await page.keyboard.press("?");
  const sheet = page.getByRole("dialog", { name: "Keyboard shortcuts" }).getByRole("region", { name: "Needs you tray" });
  for (const label of ["Next / previous item", "Open the item’s page", "Switch between Needs you and Updates", "Reply to the selected question", "Clear the selected item until it changes", "Approve the selected approval", "Deny the selected approval (with an optional reason)", "Close the tray, or leave the reply box"]) {
    await expect(sheet.getByText(label, { exact: true })).toBeVisible();
  }
});

test("the Tickets list's Needs you group holds the same tickets as the tray's Needs you tab", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  const board = await installBoardApi(page);
  const base = { project: "WEB", resolved: false, read: false, href: "/tickets/WEB-1", agent: atlas };
  const inbox: S["InboxItem"][] = [
    { ...base, needs_you: true, id: `approval:${APPROVAL}`, kind: "approval", title: "Build ticket modal", summary: "Push", ticket_key: "WEB-1", created_at: minutesAgo(30), run_id: RUN },
    // Kinds outside approval, question and blocked: the server's flag decides.
    { ...base, needs_you: true, id: "dispatch:web-2", kind: "dispatch", title: "Write integration checks", summary: "Ready to start", ticket_key: "WEB-2", created_at: minutesAgo(20) },
    { ...base, needs_you: true, id: "review:web-5", kind: "review", title: "Review board", summary: "PR #7", ticket_key: "WEB-5", created_at: minutesAgo(15) },
    { ...base, needs_you: true, id: "mention:ask", kind: "mention", title: "Other epic work", summary: "@liam which tone?", ticket_key: "WEB-4", created_at: minutesAgo(10) },
    // Updates: never under Needs you, on either screen.
    { ...base, needs_you: false, id: "mention:fyi", kind: "mention", title: "Review board", summary: "@liam FYI", ticket_key: "WEB-5", created_at: minutesAgo(5) },
    { ...base, needs_you: false, id: "merged:3", kind: "merged", title: "ADR and contract", summary: "PR #3 merged", ticket_key: "WEB-3", created_at: minutesAgo(4) },
    // Handled already: neither shows it.
    { ...base, needs_you: true, id: "approval:old", kind: "approval", title: "Other epic work", summary: "Old", ticket_key: "WEB-4", created_at: minutesAgo(60), resolved: true },
  ];
  board.inbox.push(...inbox);
  board.counts.needs_you = 4;
  await page.goto("/tickets?project=WEB");

  const group = page.getByRole("region", { name: /^Needs you, \d+$/ });
  await expect(group.locator("[data-ticket-row]")).toHaveCount(4);
  const listed = await group.locator("[data-ticket-row]").evaluateAll((rows) => rows.map((r) => r.getAttribute("data-ticket-row")));

  await pill(page).click();
  const needs = tray(page).getByRole("tabpanel", { name: "Needs you" });
  await expect(needs.locator("[data-tray-row]")).toHaveCount(4);
  const ids = await needs.locator("[data-tray-row]").evaluateAll((rows) => rows.map((r) => r.getAttribute("data-tray-row")));
  const inTray = new Set(ids.map((id) => inbox.find((i) => i.id === id)?.ticket_key).filter(Boolean));

  expect(new Set(listed)).toEqual(inTray);
  expect([...inTray].sort()).toEqual(["WEB-1", "WEB-2", "WEB-4", "WEB-5"]);
  // Each kind reads as its own state.
  await expect(row(page, "WEB-5")).toContainText("Review requested: PR #7");
  await expect(row(page, "WEB-4")).toContainText("Mentioned you: @liam which tone?");
});
