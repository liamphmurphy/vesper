import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

const screen = (page: Page) => page.locator('[data-testid="board-screen"]:visible');
const card = (page: Page, key = "WEB-1") => screen(page).getByRole("article", { name: `Ticket ${key}`, exact: true });
const dialog = (page: Page) => page.getByRole("dialog", { name: "Edit WEB-1" });
const alertWith = (page: Page, text: string) => dialog(page).getByRole("alert").filter({ hasText: text });
const save = (page: Page) => dialog(page).getByRole("button", { name: "Save changes" });

test("click opens a prefilled modal and sets ?ticket=", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&include_canceled=");
  await card(page).click();
  const d = dialog(page);
  await expect(d).toBeVisible();
  await expect(page).toHaveURL(/project=WEB.*ticket=WEB-1/);
  await expect(d.getByText("Changes are saved when you choose Save changes.")).toBeVisible();
  await expect(d.getByLabel("Title", { exact: true })).toHaveValue("Build ticket modal");
  await expect(d.getByLabel("Description · Markdown")).toHaveValue("Original description");
  await expect(d.getByLabel("Status", { exact: true })).toHaveValue("todo");
  await expect(d.getByLabel("Priority", { exact: true })).toHaveValue("high");
  await expect(d.getByLabel("Point estimate")).toHaveValue("3");
  await expect(d.getByText("Set by @builder")).toBeVisible();
  await expect(d.getByLabel("Assignee")).toHaveValue("agent-builder");
  await expect(d.getByLabel("Epic", { exact: true })).toHaveValue("epic-1");
  await expect(d.getByLabel("Criterion 1 text")).toHaveValue("Works");
  await expect(d.getByLabel("Criterion 1 done")).toBeChecked();
  await expect(d.getByRole("link", { name: "Open full ticket ↗" })).toHaveAttribute("href", "/tickets/WEB-1");
  await expect(save(page)).toBeDisabled();
  expect(api.patches).toEqual([]);
});

test("Enter opens the editor; Esc closes with no request and focus returns to the card", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).focus();
  await page.keyboard.press("Enter");
  await expect(dialog(page)).toBeVisible();
  await expect(dialog(page).getByLabel("Title", { exact: true })).toHaveValue("Build ticket modal");
  await dialog(page).getByLabel("Title", { exact: true }).fill("Unsaved");
  await page.keyboard.press("Escape");
  await page.getByRole("alertdialog").getByRole("button", { name: "Discard" }).click();
  await expect(dialog(page)).toHaveCount(0);
  await expect(page).not.toHaveURL(/ticket=/);
  await expect(page).toHaveURL(/project=WEB/);
  await expect(card(page)).toBeFocused();
  await card(page).click();
  await dialog(page).getByRole("button", { name: "Cancel" }).click();
  await expect(card(page)).toBeFocused();
  expect(api.patches).toEqual([]);
});

test("edit and save sends one PATCH with only changed fields plus revision and updates the card", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  const d = dialog(page);
  await d.getByLabel("Title", { exact: true }).fill("Renamed ticket");
  await d.getByLabel("Priority", { exact: true }).selectOption("low");
  await save(page).click();
  await expect(dialog(page)).toHaveCount(0);
  expect(api.patches).toEqual([{ key: "WEB-1", body: { revision: 1, title: "Renamed ticket", priority: "low" } }]);
  await expect(card(page)).toContainText("Renamed ticket");
  await expect(card(page)).toContainText("Low");
  await expect(page).not.toHaveURL(/ticket=/);
  expect(api.unhandled).toEqual([]);
});

test("estimate can be changed or cleared, and shows who set it", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  const d = dialog(page);
  await d.getByLabel("Point estimate").selectOption("8");
  await expect(d.getByText("Will be recorded as your estimate")).toBeVisible();
  await save(page).click();
  await expect(dialog(page)).toHaveCount(0);
  await expect(card(page)).toContainText("8 pt");
  expect(api.patches.at(-1)).toEqual({ key: "WEB-1", body: { revision: 1, estimate_points: 8 } });
  await card(page).click();
  await expect(d.getByText("Set by Liam")).toBeVisible();
  await d.getByRole("button", { name: "Clear" }).click();
  await save(page).click();
  await expect(dialog(page)).toHaveCount(0);
  await expect(card(page)).not.toContainText("8 pt");
  await expect(card(page)).not.toContainText("unestimated");
  expect(api.patches.at(-1)).toEqual({ key: "WEB-1", body: { revision: 2, estimate_points: null } });
  await card(page, "WEB-3").click();
  await expect(page.getByRole("dialog", { name: "Edit WEB-3" }).getByText("Set by Sam")).toBeVisible();
});

test("criteria reorder, add, delete and tick are sent as one criteria draft", async ({ page }) => {
  const api = await installBoardApi(page);
  api.tickets[0].criteria = [
    { id: "c1", position: 1, text: "One", done: false },
    { id: "c2", position: 2, text: "Two", done: false },
    { id: "c3", position: 3, text: "Three", done: true },
  ];
  await page.goto("/board?project=WEB");
  await card(page).click();
  const d = dialog(page);
  await d.getByRole("button", { name: "Move criterion 2 up" }).click();
  await d.getByLabel("Criterion 1 done").check();
  await d.getByRole("button", { name: "Delete criterion 3" }).click();
  await d.getByRole("button", { name: "+ Add criterion" }).click();
  await d.getByLabel("Criterion 3 text").fill("Four");
  await save(page).click();
  await expect(dialog(page)).toHaveCount(0);
  expect(api.patches).toHaveLength(1);
  expect(api.patches[0].body).toEqual({
    revision: 1,
    criteria: {
      expected: [
        { id: "c1", position: 1, text: "One", done: false },
        { id: "c2", position: 2, text: "Two", done: false },
        { id: "c3", position: 3, text: "Three", done: true },
      ],
      items: [{ id: "c2", text: "Two", done: true }, { id: "c1", text: "One", done: false }, { text: "Four", done: false }],
    },
  });
  await expect(card(page).getByLabel("1 of 3 criteria met")).toBeVisible();
});

test("a stale 409 shows the banner, keeps edits, and reload replaces the draft", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  const d = dialog(page);
  await d.getByLabel("Title", { exact: true }).fill("My edit");
  api.editTicket("WEB-1", { title: "Someone else's title" });
  await save(page).click();
  const banner = alertWith(page, "This ticket changed by someone else. Your unsaved edits are still shown.");
  await expect(banner).toBeVisible();
  await expect(d.getByLabel("Title", { exact: true })).toHaveValue("My edit");
  expect(api.patches).toHaveLength(1);
  await banner.getByRole("button", { name: "Reload latest ticket (replaces this draft)" }).click();
  await expect(d.getByLabel("Title", { exact: true })).toHaveValue("Someone else's title");
  await expect(banner).toHaveCount(0);
  await expect(save(page)).toBeDisabled();
  await d.getByLabel("Title", { exact: true }).fill("Retry");
  await save(page).click();
  await expect(dialog(page)).toHaveCount(0);
  expect(api.patches.at(-1)?.body).toEqual({ revision: 2, title: "Retry" });
});

test("a criteria snapshot conflict also shows the stale banner", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  await dialog(page).getByLabel("Criterion 1 done").uncheck();
  api.rejectNext(409, "Criteria changed", "criteria");
  await save(page).click();
  await expect(alertWith(page, "changed by someone else")).toBeVisible();
  await expect(dialog(page).getByLabel("Criterion 1 done")).not.toBeChecked();
});

test("other 409s are a general error, not the stale banner", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  await dialog(page).getByLabel("Title", { exact: true }).fill("X");
  api.rejectNext(409, "Cancel the run first");
  await save(page).click();
  await expect(alertWith(page, "Cancel the run first")).toBeVisible();
  await expect(dialog(page).getByText("changed by someone else")).toHaveCount(0);
});

test("422 shows the message beside the named field; unknown fields are general", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).click();
  const d = dialog(page);
  await d.getByLabel("Title", { exact: true }).fill("Bad");
  api.rejectNext(422, "Title is not allowed", "title");
  await save(page).click();
  const field = d.getByLabel("Title", { exact: true });
  await expect(field).toHaveAttribute("aria-invalid", "true");
  await expect(alertWith(page, "Title is not allowed")).toBeVisible();
  await expect(field.locator("xpath=..").getByRole("alert")).toHaveText("Title is not allowed");
  api.rejectNext(422, "Something odd", "mystery");
  await save(page).click();
  await expect(alertWith(page, "Something odd")).toBeVisible();
  await expect(alertWith(page, "Title is not allowed")).toHaveCount(0);
});

test("/board?ticket=KEY opens directly, even for a ticket outside the filter", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&assignee=reviewer&ticket=WEB-2");
  await expect(page.getByRole("dialog", { name: "Edit WEB-2" }).getByLabel("Title", { exact: true })).toHaveValue("Write integration checks");
  await expect(card(page, "WEB-2")).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page).toHaveURL(/assignee=reviewer/);
  await expect(page).not.toHaveURL(/ticket=/);
  expect(api.patches).toEqual([]);
});

test("a direct link focuses the card on close when it is on the board", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/board?project=WEB&ticket=WEB-1");
  await expect(dialog(page)).toBeVisible();
  await dialog(page).getByRole("button", { name: "Cancel" }).click();
  await expect(card(page)).toBeFocused();
});

test("a missing ticket leaves the modal closed with a non-blocking error", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/board?project=WEB&ticket=WEB-404");
  await expect(screen(page).getByRole("alert").filter({ hasText: "Couldn't open WEB-404" })).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(card(page)).toBeVisible();
  await screen(page).getByRole("button", { name: "Dismiss ticket error" }).click();
  await expect(page).not.toHaveURL(/ticket=/);
});


test("Markdown preview and keyboard save keep criteria atomic", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&ticket=WEB-1");
  const d = dialog(page);
  await d.getByLabel("Description · Markdown").fill("**Verified** description");
  await d.getByRole("button", { name: "Preview", exact: true }).click();
  await expect(d.locator("strong")).toHaveText("Verified");
  await d.getByLabel("Criterion 1 text").fill("Verified criterion");
  expect(api.patches).toHaveLength(0);
  await d.getByLabel("Title", { exact: true }).press("Control+Enter");
  await expect(d).toHaveCount(0);
  expect(api.patches).toHaveLength(1);
  expect(api.patches[0].body).toMatchObject({ description_md: "**Verified** description", criteria: { items: [{ text: "Verified criterion", done: true }] } });
});


test("conflict reapply keeps only my changed fields over the latest server version", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&ticket=WEB-1");
  const d = dialog(page);
  await d.getByLabel("Title", { exact: true }).fill("My title");
  api.editTicket("WEB-1", { title: "Their title", description_md: "Their description" });
  await save(page).click();
  await d.getByRole("button", { name: "Reapply mine" }).click();
  await expect(d.getByLabel("Title", { exact: true })).toHaveValue("My title");
  await expect(d.getByLabel("Description · Markdown")).toHaveValue("Their description");
  await save(page).click();
  await expect(d).toHaveCount(0);
  expect(api.patches.at(-1)?.body).toEqual({ revision: 2, title: "My title" });
});

test("declining discard keeps the unsaved draft open", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&ticket=WEB-1");
  const d = dialog(page);
  await d.getByLabel("Title", { exact: true }).fill("Keep me");
  await d.getByRole("button", { name: "Cancel", exact: true }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Keep editing" }).click();
  await expect(page.getByRole("alertdialog")).toHaveCount(0);
  await expect(d.getByLabel("Title", { exact: true })).toHaveValue("Keep me");
  expect(api.patches).toEqual([]);
});
