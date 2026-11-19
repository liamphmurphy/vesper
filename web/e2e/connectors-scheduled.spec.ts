import { expect, test } from "@playwright/test";
import { installChatApi, persona } from "./mock-chat-api";

const ATLAS = persona(1, { name: "Atlas", tone: "friendly", color: "#4fd1c5", is_default: true });

test("a connector is added, then given to a persona with per-tool permissions", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS] });
  await page.goto("/settings?section=connectors");
  await page.getByRole("button", { name: "Add connector" }).click();
  await page.getByLabel("Name").fill("Linear");
  await page.getByLabel("MCP server URL").fill("https://mcp.example.com/mcp");
  await page.getByLabel("MCP server URL").blur();
  await expect(page.getByText("Found the server: 2 tools")).toBeVisible();
  await page.getByRole("radio", { name: "None" }).click();
  await page.getByRole("button", { name: "Connect" }).click();

  const detail = page.getByTestId("connector-detail");
  await expect(detail.getByRole("heading", { name: "Linear" })).toBeVisible();
  await detail.getByRole("switch", { name: "Atlas can use Linear" }).click();
  await expect.poll(() => mock.connectors[0].persona_ids.length).toBe(1);
  await detail.getByRole("radiogroup", { name: "Permission for write_thing" }).getByRole("radio", { name: "Off" }).click();
  await expect.poll(() => mock.connectors[0].tools[1].policy).toBe("off");
  expect(mock.unhandled).toEqual([]);
});

test("a scheduled task is created from the Scheduled page", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS] });
  await page.goto("/chat");
  // Scheduled is a tool in the menu's Apps flyout.
  await page.getByRole("navigation", { name: "Primary" }).getByRole("button", { name: /^Apps/ }).click();
  await page.getByRole("dialog", { name: "Apps" }).getByRole("link", { name: "Scheduled" }).click();
  await expect(page).toHaveURL(/\/scheduled$/);
  await page.getByRole("button", { name: "New task" }).click();
  await page.getByLabel("Name").fill("Monday work brief");
  await page.getByLabel("Instructions").fill("Summarise my week.");
  await page.getByRole("button", { name: "Friday" }).click();
  await page.getByLabel("Time", { exact: true }).fill("07:30");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByTestId("scheduled-row")).toContainText("Every Monday, Friday at 7:30 AM");
  expect(mock.scheduledTasks[0]).toMatchObject({ kind: "prompt", frequency: "weekly", weekdays: [1, 5], at_time: "07:30", enabled: true });
  expect(mock.unhandled).toEqual([]);
});

test("a connector tool waiting for approval shows in the chat", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS] });
  await page.goto("/chat");
  await page.getByRole("combobox", { name: "Message" }).fill("slow: hello");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  mock.connectorApprovals.push({ id: "11111111-1111-4111-8111-111111111111", connector_id: "11111111-1111-4111-8111-111111111112", connector_name: "GitHub", tool: "create_issue", arguments: { title: "Fix it" }, created_at: new Date().toISOString() });
  // The request opens inside the running status card rather than stacking above it.
  const card = page.getByTestId("chat-status-card").getByTestId("connector-approval");
  await expect(card).toContainText("create_issue");
  await expect(page.getByTestId("chat-status")).toContainText("needs your approval");
  await card.getByRole("button", { name: "Allow once" }).click();
  await expect(card).toHaveCount(0);
  await expect(page.getByTestId("chat-status")).not.toContainText("needs your approval");
  expect(mock.connectorDecisions).toEqual(["allow"]);
});
