import { expect, test } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

test("the overview shows each epic's progress and filters by status and health in the URL", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/epics?project=WEB");
  const board = page.getByRole("article", { name: "Kanban board" });
  const other = page.getByRole("article", { name: "Other epic" });
  await expect(board).toContainText("5 / 10 pts · 50%");
  await expect(board).toContainText("1 / 2 met");
  await expect(board).toContainText("3 open tickets");
  await expect(board).toContainText("Liam");
  await expect(board).toContainText("On track");
  await expect(other).toContainText("0 / 8 pts · 0%");
  await expect(other).toContainText("No owner");
  // An open epic past its target date is flagged.
  await expect(other).toContainText("Overdue ·");
  // Needs attention puts the at-risk epic first.
  await expect(page.getByRole("article")).toHaveText([/Other epic/, /Kanban board/]);
  await page.getByRole("button", { name: "Sort epics: Needs attention" }).click();
  await page.getByRole("menuitemradio", { name: "Name" }).click();
  await expect(page).toHaveURL(/sort=name/);
  await expect(page.getByRole("article")).toHaveText([/Kanban board/, /Other epic/]);

  await page.getByRole("radiogroup", { name: "Health" }).getByRole("radio", { name: "At risk" }).click();
  await expect(page).toHaveURL(/health=at_risk/);
  await expect(page.getByRole("article")).toHaveCount(1);
  await expect(other).toBeVisible();
  await page.reload();
  await expect(page.getByRole("article")).toHaveCount(1);

  await page.getByRole("radiogroup", { name: "Epic status" }).getByRole("radio", { name: /Done/ }).click();
  await expect(page).toHaveURL(/status=done/);
  await expect(page.getByRole("heading", { name: "No epics match" })).toBeVisible();
  await page.getByRole("button", { name: "Clear filters" }).click();
  await expect(page.getByRole("article")).toHaveCount(2);

  await board.getByRole("link", { name: "Kanban board" }).click();
  await expect(page).toHaveURL(/\/epics\/epic-1$/);
  await expect(page.getByRole("heading", { level: 1, name: "Kanban board" })).toBeVisible();
  expect(api.unhandled).toEqual([]);
});

test("old ?epic= links open the detail page", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/epics?epic=epic-1&project=WEB");
  await expect(page).toHaveURL(/\/epics\/epic-1$/);
});

test("epic detail shows the burn-up, board link, who checked criteria and the done gate", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/epics/epic-1");
  await expect(page.getByRole("heading", { level: 1, name: "Kanban board" })).toBeVisible();
  await expect(page.getByText("Ship the board")).toBeVisible();
  await expect(page.getByRole("link", { name: "Board filtered to this epic" })).toHaveAttribute("href", "/tickets?layout=board&project=WEB&epic=epic-1");
  // Progress: done / running / needs you / open, with spend so far.
  const progress = page.getByRole("region", { name: "Epic progress" });
  await expect(progress).toContainText("1 done");
  await expect(progress).toContainText("1 running");
  await expect(progress).toContainText("0 need you");
  await expect(progress).toContainText("2 open");
  await expect(progress).toContainText("$0.00 spent so far");
  // Criteria with the done gate, specs, details and the burn-up live in the Context panel, not the page body.
  const context = page.getByRole("tabpanel", { name: "Context" });
  await expect(context.getByRole("region", { name: "Acceptance criteria", exact: true })).toBeVisible();
  await expect(context.getByRole("region", { name: "Specs and details" })).toBeVisible();
  await expect(context.getByRole("img", { name: "Points burn-up: 5 of 10 points done (50%)" })).toBeVisible();
  await expect(context.getByText("Requires mockup", { exact: true })).toBeVisible();
  await expect(page.locator("article details")).toHaveCount(0);
  await page.screenshot({ path: test.info().outputPath("epic-context.png"), fullPage: true });
  await expect(page.locator("article").getByRole("region", { name: "Epic completion" })).toHaveCount(0);

  const panel = context.getByRole("region", { name: "Epic completion" });
  const criteria = panel.getByRole("region", { name: "Final acceptance criteria" });
  await expect(criteria.getByRole("listitem").first()).toContainText("Checked by Builder");
  await criteria.getByLabel("Criterion 2 met").check();
  await expect(criteria.getByRole("listitem").nth(1)).toContainText("Checked by Liam");

  // Open tickets still block done; they are listed from done_blockers.
  await expect(panel.getByRole("button", { name: "Mark epic done" })).toBeDisabled();
  await expect(panel.getByRole("region", { name: "Done blockers" }).getByRole("list", { name: "Open tickets" }).getByRole("link"))
    .toHaveText(["WEB-1 ↗", "WEB-2 ↗", "WEB-5 ↗"]);

  // Tickets are a checklist with their state on the right.
  const checklist = page.getByRole("list", { name: "Ticket checklist" });
  await expect(checklist.getByRole("listitem").filter({ hasText: "WEB-3" }).getByRole("img", { name: "Done" })).toBeVisible();
  await expect(checklist.getByRole("listitem").filter({ hasText: "WEB-1" })).toContainText("Blocked by 1");

  // Once everything is closed the epic can be marked done, and reopened.
  for (const key of ["WEB-1", "WEB-2", "WEB-5"]) api.editTicket(key, { status: "done" });
  await api.emit("ticket.updated");
  await page.reload();
  await panel.getByRole("button", { name: "Mark epic done" }).click();
  await expect(panel.getByRole("button", { name: "Reopen epic" })).toBeEnabled();
  await panel.getByRole("button", { name: "Reopen epic" }).click();
  await expect(panel.getByRole("button", { name: "Mark epic done" })).toBeEnabled();
  expect(api.epicWrites.filter((w) => w.method === "PATCH" && w.path === "/epics/epic-1").map((w) => w.body)).toEqual([{ status: "done" }, { status: "open" }]);
  expect(api.unhandled).toEqual([]);
});

test("the epic page's Context panel stays closed across reloads, like the run page's", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/epics/epic-1");
  // The epic's companion: its Context tab, folded and reopened from the rail like every page's.
  const context = page.getByRole("tabpanel", { name: "Context" });
  await expect(context.getByRole("region", { name: "Epic completion" })).toBeVisible();
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Collapse panel" }).click();
  await expect(context).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("heading", { level: 1, name: "Kanban board" })).toBeVisible();
  await expect(context).toHaveCount(0);
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Open Context" }).click();
  await expect(context.getByRole("region", { name: "Epic completion" })).toBeVisible();
  await page.reload();
  await expect(context.getByRole("region", { name: "Epic completion" })).toBeVisible();
});

test("the epic page's Needs you banner approves inline and Start ready skips blocked tickets", async ({ page }) => {
  const api = await installBoardApi(page);
  api.inbox.push({ id: "approval:ap-5", kind: "approval", title: "Review board", summary: "Merge the PR", href: "/tickets/WEB-5", project: "WEB", ticket_key: "WEB-5", created_at: "2026-11-12T10:00:00Z", resolved: false, read: false, needs_you: true, run_id: "run-5" });
  await page.goto("/epics/epic-1");
  const banner = page.getByRole("region", { name: "Needs you" });
  await expect(banner).toContainText("WEB-5");
  await expect(banner).toContainText("Wants approval: Merge the PR");
  await expect(banner.getByRole("link", { name: "Open what WEB-5 needs" })).toHaveAttribute("href", "/tickets/WEB-5");
  await expect(page.getByRole("region", { name: "Epic progress" })).toContainText("1 need you");
  await banner.getByRole("button", { name: "Approve WEB-5" }).click();
  await expect.poll(() => api.decisions).toEqual([{ id: "ap-5", decision: "approve" }]);
  await expect(page.getByRole("region", { name: "Needs you" })).toHaveCount(0);

  // WEB-1 waits on WEB-2, so only WEB-2 and WEB-5 are ready.
  const start = page.getByRole("region", { name: "Start ready" });
  await expect(start).toContainText("Still blocked, so not started");
  await expect(start).toContainText("WEB-1");
  await expect(start.getByRole("button", { name: /start ready \(2\)/i })).toBeVisible();
});

test("an unknown epic shows not found", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/epics/nope");
  await expect(page.getByRole("heading", { name: "Epic not found" })).toBeVisible();
});
