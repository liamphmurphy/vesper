import { test, expect, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import type { Schemas } from "../lib/api/client";

async function installWork(page: Page) {
  const api = await installBoardApi(page);
  await page.addInitScript(() =>
    sessionStorage.setItem("la:banner:harness:dismissed", "1"),
  );
  const run: Schemas["Run"] = {
    id: "work-run",
    ticket_key: "WEB-1",
    work_title: "Build ticket modal",
    purpose: "ticket",
    project_key: "WEB",
    agent: {
      id: "agent-builder",
      name: "Builder",
      handle: "builder",
      color_index: 0,
    },
    mode: "managed",
    state: "running",
    harness: "codex",
    model: "gpt-5-codex",
    started_at: "2026-11-14T10:00:00Z",
    tool_calls: 1,
    input_tokens: 100,
    output_tokens: 20,
    cost_usd: 0.42,
    cost_source: "harness",
    scopes: [],
    approval_scopes: [],
    plan: [
      { position: 1, state: "done", text: "Read Work views" },
      { position: 2, state: "current", text: "Checking navigation" },
    ],
  };
  const previous = {
    ...run,
    id: "previous-run",
    state: "cancelled",
    ended_at: "2026-11-14T09:00:00Z",
  };
  const replies: string[] = [];
  await page.route("**/api/v1/runs**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/runs"))
      return route.fulfill({
        json: {
          runs: url.searchParams.has("ticket") ? [run, previous] : [run],
          has_more: false,
        },
      });
    return route.fulfill({
      json: {
        run: url.pathname.includes("previous-run") ? previous : run,
        child_runs: [],
        turns: [],
        approvals: [],
        events: Array.from({ length: 16 }, (_, i) => ({
          seq: i + 1,
          type: "message",
          at: "2026-11-14T10:00:00Z",
          payload: {
            text: `Navigation check ${i + 1}. Keep the run and draft in place.`,
          },
        })).filter((e) => e.seq > Number(url.searchParams.get("after") ?? 0)),
      },
    });
  });
  await page.route("**/api/v1/tickets/WEB-1/comments", async (route) => {
    replies.push(route.request().postDataJSON().body_md);
    return route.fulfill({ status: 201, json: { id: "comment-1" } });
  });
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem(
      "la-appearance",
      JSON.stringify({
        version: 1,
        palette: "gruvbox",
        custom: { base: "gruvbox", dark: {}, light: {} },
      }),
    );
  });
  return { api, replies };
}

for (const compact of [false, true]) {
  test(`run → ticket → epic preserves the run and draft (${compact ? "compact" : "desktop"})`, async ({
    page,
  }, info) => {
    await page.setViewportSize(
      compact ? { width: 390, height: 844 } : { width: 1440, height: 900 },
    );
    const { replies } = await installWork(page);
    await page.goto("/work?run=work-run&project=WEB");
    const input = page.getByRole("textbox", { name: "Follow up with Builder" });
    await input.fill("Keep my filters and reply draft.");
    const log = page.getByRole("log", { name: "Run thread" });
    await log.evaluate((el) => {
      el.scrollTop = 0;
    });
    await page.screenshot({
      path: info.outputPath(`01-activity-${compact}.png`),
    });
    await page
      .locator(".work-run-links")
      .getByRole("button", { name: "WEB-1 ↗" })
      .click();
    const pane = page.getByRole("region", { name: "Work context" });
    await expect(
      pane.getByRole("heading", { name: "Build ticket modal", exact: true }),
    ).toBeVisible();
    await expect(page).toHaveURL(/context=ticket/);
    await page.screenshot({
      path: info.outputPath(`02-ticket-${compact}.png`),
    });
    await pane
      .getByRole("button", { name: "Kanban board →", exact: true })
      .click();
    await expect(
      pane.getByRole("heading", { name: "Kanban board", exact: true }),
    ).toBeVisible();
    await page.screenshot({ path: info.outputPath(`03-epic-${compact}.png`) });
    await page.goBack();
    await expect(
      pane.getByRole("heading", { name: "Build ticket modal", exact: true }),
    ).toBeVisible();
    await page.goBack();
    await expect(input).toHaveValue("Keep my filters and reply draft.");
    expect(await log.evaluate((el) => el.scrollTop)).toBeLessThan(5);
    if (!compact) {
      const nav = page.getByRole("navigation", { name: "Work", exact: true });
      await page
        .locator(".work-run-links")
        .getByRole("button", { name: "WEB-1 ↗" })
        .click();
      await pane.getByRole("button", { name: "Focus ticket →" }).click();
      await expect(
        page.getByRole("region", { name: "Focused work" }),
      ).toBeVisible();
      await expect(input).toHaveValue("Keep my filters and reply draft.");
      await page.screenshot({ path: info.outputPath("04-focused-ticket.png") });
      await page
        .getByRole("region", { name: "Focused work" })
        .getByRole("button", { name: /^Kanban board/ })
        .first()
        .click();
      await expect(
        page
          .getByRole("region", { name: "Focused work" })
          .getByRole("heading", { name: "Kanban board", exact: true }),
      ).toBeVisible();
      await page.screenshot({ path: info.outputPath("05-focused-epic.png") });
      await nav.getByRole("button", { name: "Activity", exact: true }).click();
    }
    await page.getByRole("button", { name: "Send", exact: true }).click();
    await expect
      .poll(() => replies)
      .toEqual(["@builder Keep my filters and reply draft."]);
  });
}

test("legacy Runs links open Work, and Tickets and Epics open the full screens", async ({
  page,
}) => {
  await installWork(page);
  await page.goto("/runs?project=WEB");
  await expect(page).toHaveURL(/\/work\?.*project=WEB/);
  const nav = page.getByRole("navigation", { name: "Work", exact: true });
  await nav.getByRole("link", { name: "Tickets", exact: true }).click();
  await expect(page).toHaveURL(/\/tickets\?project=WEB$/);
  await page.goto("/work?view=tickets&layout=board&project=WEB");
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  await page.goto("/work?view=epics&project=WEB");
  await expect(page).toHaveURL(/\/tickets\?layout=epics&project=WEB$/);
});

test("saved filters retain the run, and a previous attempt opens within Work", async ({
  page,
}) => {
  const { api } = await installWork(page);
  await page.goto(
    "/work?view=tickets&run=work-run&ticket=WEB-1&project=WEB&agent=builder&q=modal",
  );
  const nav = page.getByRole("navigation", { name: "Work", exact: true });
  await nav.getByRole("button", { name: "Save current Work filters" }).click();
  await nav.getByRole("textbox", { name: "View name" }).fill("My workflow");
  await nav.getByRole("button", { name: "Save", exact: true }).click();
  await expect
    .poll(() => api.savedViews.some((v) => v.name === "My workflow"))
    .toBe(true);
  expect(api.savedViews.find((v) => v.name === "My workflow")!.query).toContain(
    "assignee=builder",
  );
  await nav.getByRole("textbox", { name: "Search work" }).fill("");
  await nav.getByRole("button", { name: /^Saved views/ }).click();
  await page.getByRole("menuitemradio", { name: "My workflow" }).click();
  await expect(nav.getByRole("textbox", { name: "Search work" })).toHaveValue(
    "modal",
  );
  await expect(page).toHaveURL(/run=work-run/);
  await page
    .getByRole("region", { name: "Focused work" })
    .getByRole("button", { name: /Attempt 1/ })
    .click();
  await expect(page).toHaveURL(/run=previous-run/);
  await expect(
    page.getByRole("heading", { name: "Outcome", exact: true }),
  ).toBeVisible();
});

test("context errors are recoverable and deep links restore the pane", async ({
  page,
}) => {
  await installWork(page);
  let fail = true;
  await page.route("**/api/v1/tickets/WEB-1", (route) =>
    fail
      ? route.fulfill({
          status: 503,
          json: { code: "unavailable", message: "Temporary outage" },
        })
      : route.fallback(),
  );
  await page.goto("/work?run=work-run&ticket=WEB-1&context=ticket&project=WEB");
  const pane = page.getByRole("region", { name: "Work context" });
  await expect(pane.getByRole("alert")).toBeVisible({ timeout: 15_000 });
  fail = false;
  await pane.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(
    pane.getByRole("heading", { name: "Build ticket modal", exact: true }),
  ).toBeVisible();
  await page.reload();
  await expect(
    pane.getByRole("heading", { name: "Build ticket modal", exact: true }),
  ).toBeVisible();
  await pane.getByRole("button", { name: "Close context" }).click();
  await expect(pane).toHaveCount(0);
  await expect(
    page.getByRole("textbox", { name: "Follow up with Builder" }),
  ).toBeVisible();
});

test("Work keeps a single harness footer in the right rail, contextual Chat dock, a compact Activity header, and consistent tabs across Activity, Tickets and Epics", async ({
  page,
}) => {
  await installWork(page);
  await page.route("**/api/v1/persona-dock", (route) =>
    route.fulfill({
      json: {
        personas: [],
        harnesses: [
          {
            harness: "claude-code",
            label: "Claude Code",
            connected: true,
            running: 0,
            usage_available: true,
            windows: [{ id: "w1", kind: "session", label: "Session", used_percent: 25 }],
          },
        ],
      },
    }),
  );

  // Activity: persistent right rail holds harness usage and contextual WorkChat (not duplicated in Left menu or TopBar).
  await page.goto("/work?run=work-run&project=WEB");
  const mainMenu = page.getByRole("complementary", { name: "Main menu" });
  const rightRail = page.getByRole("complementary", { name: "Right rail" });
  await expect(mainMenu.getByRole("region", { name: "Harness activity" })).toHaveCount(0);
  await expect(rightRail.getByRole("region", { name: "Harness activity" })).toHaveCount(1);
  await expect(page.getByRole("region", { name: "Harness activity" })).toHaveCount(1);
  await expect(rightRail.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Open Chat" })).toBeVisible();

  // Run-context links sit inside the compact TopBar on Activity.
  const headerLinks = page.locator("header .work-run-links");
  await expect(headerLinks.getByRole("button", { name: "WEB-1 ↗" })).toBeVisible();
  await expect(headerLinks.getByRole("button", { name: "Details ◧" })).toBeVisible();

  // Ended runs collapse the ActivityScene row and keep only the compact header + progress bar.
  await page.goto("/work?run=previous-run&project=WEB");
  await expect(page.getByRole("progressbar", { name: "Plan progress" })).toBeVisible();
  await expect(page.locator(".work-run [role='status']")).toHaveCount(0);

  // Switching to Tickets (List, Board) and Epics preserves the Work left navigator.
  const workNav = page.getByRole("navigation", { name: "Work", exact: true });
  await workNav.getByRole("link", { name: "Tickets", exact: true }).click();
  await expect(page).toHaveURL(/\/tickets\?project=WEB$/);
  await expect(workNav).toBeVisible();
  await expect(workNav.getByRole("link", { name: "Tickets", exact: true })).toHaveAttribute("aria-current", "true");

  await page.getByRole("navigation", { name: "Tickets layout" }).getByRole("link", { name: "Board" }).click();
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  await expect(workNav).toBeVisible();
  await expect(workNav.getByRole("link", { name: "Tickets", exact: true })).toHaveAttribute("aria-current", "true");

  await workNav.getByRole("link", { name: "Epics", exact: true }).click();
  await expect(page).toHaveURL(/\/tickets\?layout=epics&project=WEB$/);
  await expect(workNav).toBeVisible();
  await expect(workNav.getByRole("link", { name: "Epics", exact: true })).toHaveAttribute("aria-current", "true");

  // Selecting an epic in the Work sidebar opens its details in the right companion.
  await workNav.getByRole("button", { name: /Kanban board/ }).click();
  const context = page.getByRole("region", { name: "Work context" });
  await expect(context.getByRole("heading", { name: "Kanban board", exact: true })).toBeVisible();
  await context.getByRole("button", { name: "Close context" }).click();
  await expect(context).toHaveCount(0);
});
