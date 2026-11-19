import { expect, test } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

// The ticket's companion switches between its properties and the work chat with your persona,
// which says which ticket the next message is about; the choice is remembered.
test("the ticket's side panel switches to Chat, which names the ticket, and remembers it", async ({ page }) => {
  await installBoardApi(page);
  await page.route("**/api/v1/dock-chats?*", (route) => route.fulfill({ json: { chats: [] } }));
  await page.goto("/tickets/WEB-1");
  const panel = page.getByRole("complementary", { name: "Panel", exact: true });
  const tabs = page.getByRole("navigation", { name: "Panel rail" }).getByRole("tablist", { name: "Panel tabs" });
  await expect(tabs.getByRole("tab", { name: "Properties" })).toHaveAttribute("aria-selected", "true");
  await tabs.getByRole("tab", { name: "Chat" }).click();
  await expect(panel.getByTestId("work-chat-subject")).toHaveText("Viewing: WEB-1 · Build ticket modal");
  await expect(panel.getByRole("button", { name: "Start a chat" })).toBeVisible();
  await page.reload();
  await expect(tabs.getByRole("tab", { name: "Chat" })).toHaveAttribute("aria-selected", "true");
  await tabs.getByRole("tab", { name: "Properties" }).click();
  // The chat stays mounted behind its tab (a dock keeps its tabs), out of sight.
  await expect(panel.getByTestId("work-chat")).toBeHidden();

  // Unified inline Ticket views tabs switch cleanly between Overview, Runs, and Activity.
  const viewTabs = page.getByRole("tablist", { name: "Ticket views" });
  await expect(viewTabs.getByRole("tab", { name: "Overview" })).toHaveAttribute("aria-selected", "true");
  await viewTabs.getByRole("tab", { name: /^Runs/ }).click();
  await expect(viewTabs.getByRole("tab", { name: /^Runs/ })).toHaveAttribute("aria-selected", "true");
  await viewTabs.getByRole("tab", { name: /^Activity/ }).click();
  await expect(viewTabs.getByRole("tab", { name: /^Activity/ })).toHaveAttribute("aria-selected", "true");
  await viewTabs.getByRole("tab", { name: "Overview" }).click();
  await expect(viewTabs.getByRole("tab", { name: "Overview" })).toHaveAttribute("aria-selected", "true");
});
