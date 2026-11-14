import { expect, test } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import { installChatApi } from "./mock-chat-api";

// Back and forward lead every page's content, whatever header the page draws. This sweep is what
// keeps that true: a page with a header of its own that forgets them fails here, as does a page
// that draws them twice.
// /tickets/new is a modal over the Tickets list: the list's bar is behind it, hidden while it is open.
const BOARD = ["/tickets?project=WEB", "/tickets/WEB-1", "/runs", "/inbox", "/reports", "/settings", "/settings/runner", "/customization", "/library", "/learn", "/workflows", "/scheduled", "/more", "/plans"];
const CHAT = ["/chat?new", "/knowledge", "/knowledge/graph", "/knowledge/connect", "/apps/designs", "/apps/slides", "/apps/docs", "/apps", "/setup", "/wiki"];

for (const [install, routes] of [[installBoardApi, BOARD], [installChatApi, CHAT]] as const) {
  for (const route of routes) {
    test(`back and forward lead the content once on ${route}`, async ({ page }) => {
      await install(page);
      await page.goto(route);
      const history = page.getByRole("group", { name: "History" });
      await expect(history).toHaveCount(1);
      await expect(history.getByRole("button", { name: "Go back" })).toBeVisible();
      // In the content, not the left column.
      await expect(page.getByRole("complementary", { name: "Main menu" }).getByRole("group", { name: "History" })).toHaveCount(0);
    });
  }
}
