import { expect, test, type Page } from "@playwright/test";
import { installChatApi, openEmptyChat, persona } from "./mock-chat-api";

const composer = (page: Page) => page.getByRole("combobox", { name: "Message" });
const menu = (page: Page) => page.getByTestId("command-suggestions");

async function openChat(page: Page) {
  await page.goto("/chat?project=WEB");
  await openEmptyChat(page);
  await expect(composer(page)).toBeVisible();
  await expect(composer(page)).toBeFocused();
}

test("an empty chat offers four starters; picking one sends its prompt", async ({ page }) => {
  const suggestions = [
    { title: "Plan the next session", prompt: "Help me plan my next session.", icon: "dice" },
    { title: "Tidy the runner", prompt: "What should I tidy in the runner?", icon: "terminal" },
    { title: "Pick a book", prompt: "Suggest a book for this week.", icon: "wiki" },
    { title: "Plan a ride", prompt: "Plan a bike ride for Saturday.", icon: "compass" },
  ];
  const mock = await installChatApi(page, { suggestions });
  await openChat(page);
  const starters = page.getByRole("list", { name: "Conversation starters" });
  await expect(starters.getByRole("button")).toHaveCount(4);
  // Picking one would drop what's being typed, so typing puts them away.
  await composer(page).fill("draft");
  await expect(starters).toHaveCount(0);
  await composer(page).fill("");
  await starters.getByRole("button", { name: /Plan a ride/ }).click();
  await expect(page.getByTestId("assistant-message")).toContainText("Plan a bike ride for Saturday.");
  await expect(starters).toHaveCount(0);
  expect(mock.posted.map((p) => p.body.body)).toEqual(["Plan a bike ride for Saturday."]);
  expect(mock.unhandled).toEqual([]);
});

test("no starters leaves the plain greeting", async ({ page }) => {
  await installChatApi(page);
  await openChat(page);
  await expect(page.getByRole("list", { name: "Conversation starters" })).toHaveCount(0);
});

test("/ lists the commands and /memory opens the Memory page without sending", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await composer(page).pressSequentially("/");
  await expect(menu(page).getByRole("option")).toHaveCount(12);
  await composer(page).pressSequentially("mem");
  await expect(menu(page).getByRole("option")).toHaveCount(1);
  await composer(page).press("Enter");
  await expect(page.getByRole("region", { name: "Customization", exact: true })).toBeVisible();
  expect(mock.posted).toEqual([]);
  expect(mock.unhandled).toEqual([]);
});

test("/effort picks from its arguments and applies to the next message", async ({ page }) => {
  await installChatApi(page);
  await openChat(page);
  await composer(page).pressSequentially("/eff");
  await composer(page).press("Enter");
  await expect(composer(page)).toHaveValue("/effort ");
  await composer(page).pressSequentially("high");
  await composer(page).press("Enter");
  await expect(composer(page)).toHaveValue("");
  await expect(page.getByRole("button", { name: /^Model and effort for the next message: .*, High effort$/ })).toBeVisible();
});

test("an unknown command stays in the composer with an error; // sends it as text", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await composer(page).fill("/nope");
  await composer(page).press("Enter");
  await expect(page.getByTestId("command-error")).toContainText("Unknown command /nope");
  await expect(composer(page)).toHaveValue("/nope");
  expect(mock.posted).toEqual([]);
  await composer(page).fill("//nope");
  await expect(page.getByTestId("command-error")).toHaveCount(0);
  await composer(page).press("Enter");
  await expect(page.getByTestId("assistant-message").first()).toContainText("Echo: /nope");
});

test("a path-like message is sent as text", async ({ page }) => {
  await installChatApi(page);
  await openChat(page);
  await composer(page).fill("/usr/bin is missing");
  await composer(page).press("Enter");
  await expect(page.getByTestId("assistant-message").first()).toContainText("Echo: /usr/bin is missing");
});

test("/persona starts a new chat and keeps the one with messages", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.personas.push(persona(1, { name: "Atlas", is_default: true }), persona(2, { name: "Nova" }));
  await openChat(page);
  await composer(page).fill("hello");
  await composer(page).press("Enter");
  await expect(page.getByTestId("assistant-message").first()).toContainText("Echo: hello");
  const before = page.url();
  await composer(page).fill("/persona nova");
  await expect(menu(page).getByRole("option")).toHaveCount(1);
  await composer(page).press("Enter");
  await expect.poll(() => page.url()).not.toBe(before);
  await expect(composer(page)).toHaveValue("");
  expect(mock.chats.length).toBe(2);
});

test("Customization replaces Assistant, Memory and Personas in the main menu", async ({ page }) => {
  await installChatApi(page);
  await openChat(page);
  const nav = page.getByRole("navigation", { name: "Primary" });
  for (const gone of ["Assistant", "Memory", "Personas", "Dashboard"]) await expect(nav.getByRole("link", { name: gone, exact: true })).toHaveCount(0);
  await nav.getByRole("link", { name: "Customization", exact: true }).click();
  await expect(page.getByRole("region", { name: "Customization", exact: true })).toBeVisible();
  await expect(page).toHaveURL(/\/customization$/);
  // One menu, no modes: Customization is the footer link, current here.
  await expect(page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Customization", exact: true })).toHaveAttribute("aria-current", "page");
  // Old links land on the combined page, with their query.
  await page.goto("/personas");
  await expect(page).toHaveURL(/\/customization$/);
  await page.goto("/memory?id=abc");
  await expect(page).toHaveURL(/\/customization\?id=abc$/);
});

