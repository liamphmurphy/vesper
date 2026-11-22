import { expect, test, type Page } from "@playwright/test";
import { installChatApi, openEmptyChat, persona } from "./mock-chat-api";

// Assistant personas in the Assistant view (LAZYAGENTS-86): the sidebar's persona
// dropdown, the persona's identity on replies, and the persona of a new conversation.

const ATLAS = persona(1, { name: "Atlas", tone: "friendly", color: "#4fd1c5", is_default: true });
const NOVA = persona(2, { name: "Nova", tone: "playful", color: "#f472b6" });

const history = (page: Page) => page.getByRole("navigation", { name: "Chats" });
// The Chats list's one persona filter: a chip naming who it shows, opening a menu of personas.
const strip = (page: Page) => page.getByRole("button", { name: /^Show conversations for:/ });
const picked = strip;
const shows = (name: string) => `Show conversations for: ${name}`;
async function pick(page: Page, name: string | RegExp) {
  await strip(page).click();
  await page.getByRole("menuitemradio", { name: typeof name === "string" ? new RegExp(`^${name}`) : name }).click();
}
const switcher = (page: Page) => page.getByRole("button", { name: /^Persona for this conversation:/ });
const composer = (page: Page) => page.getByRole("combobox", { name: "Message" });
const welcomeBox = (page: Page) => page.getByRole("combobox", { name: "Message" });
const onCarousel = (page: Page) => page.getByRole("radiogroup", { name: "Who to talk to" }).getByRole("radio", { checked: true });
// The menu's New chat opens the welcome; the chat is made with its first message.
async function newChat(page: Page) {
  await page.getByRole("button", { name: "New chat", exact: true }).first().click();
  await expect(page).toHaveURL(/\/chat\?new/);
  await expect(welcomeBox(page)).toBeVisible();
}

// History lives in the expanded menu.
test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

test("persona sidebar filter, reply identity, live edits and new-conversation persona", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?project=WEB");

  // Welcome: the first conversation goes to the default persona.
  await expect(page.getByRole("heading", { level: 1, name: "Atlas" })).toBeVisible();
  await expect(page.getByRole("radiogroup", { name: "Who to talk to" }).getByRole("radio", { checked: true })).toHaveAccessibleName("Atlas");
  await page.getByRole("combobox", { name: "Message" }).fill("hello atlas");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  expect(mock.created[0].persona_id).toBe(ATLAS.id);

  // The reply carries the persona's avatar and its name in its color.
  const identity = page.getByTestId("assistant-identity").first();
  await expect(identity).toContainText("Atlas");
  await expect(identity.getByText("Atlas", { exact: true })).toHaveCSS("color", "rgb(79, 209, 197)");

  // A persona edit reaches the open conversation over SSE.
  const atlasChat = page.url();
  await mock.updatePersona(ATLAS.id, { name: "Atlas Prime" });
  await expect(identity).toContainText("Atlas Prime");

  // New chat opens the welcome on the sidebar's persona (the default), switchable before the first message.
  await newChat(page);
  await expect(onCarousel(page)).toHaveAccessibleName("Atlas Prime");
  await page.getByRole("button", { name: "Next persona" }).click();
  await expect(onCarousel(page)).toHaveAccessibleName("Nova");
  await expect(page.getByRole("heading", { level: 1, name: "Nova" })).toBeVisible();
  await welcomeBox(page).fill("hi nova");
  await welcomeBox(page).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  const novaChat = page.url();
  // The welcome makes no chat until the first message.
  expect(mock.created.map((c) => c.persona_id)).toEqual([ATLAS.id, NOVA.id]);
  await expect(page.getByTestId("assistant-identity").first()).toContainText("Nova");
  // Once a message is sent the persona is fixed.
  await expect(switcher(page)).toHaveCount(0);

  // The sidebar opens on every persona, each row showing who the chat is with.
  await expect(picked(page)).toHaveAccessibleName(shows("All personas"));
  await expect(history(page).getByRole("link", { name: /hi nova/ })).toBeVisible();
  await expect(history(page).getByRole("link", { name: /hello atlas/ }).locator(":scope > [aria-hidden]")).toHaveCount(1);
  // The default persona: only its conversations, and a row no longer needs its persona's picture.
  await pick(page, /^Atlas Prime/);
  await expect(picked(page)).toHaveAccessibleName(shows("Atlas Prime"));
  await expect(history(page).getByRole("link", { name: /hello atlas/ })).toBeVisible();
  await expect(history(page).getByRole("link", { name: /hi nova/ })).toHaveCount(0);
  await expect(history(page).getByRole("link", { name: /hello atlas/ }).locator(":scope > [aria-hidden]")).toHaveCount(0);

  // Another persona, then every persona.
  await pick(page, /^Nova/);
  await expect(history(page).getByRole("link", { name: /hi nova/ })).toBeVisible();
  await expect(history(page).getByRole("link", { name: /hello atlas/ })).toHaveCount(0);
  // New chat follows the sidebar's persona.
  await newChat(page);
  await expect(onCarousel(page)).toHaveAccessibleName("Nova");
  await pick(page, "All personas");
  await expect(history(page).getByRole("link", { name: /hi nova/ })).toBeVisible();
  await expect(history(page).getByRole("link", { name: /hello atlas/ })).toBeVisible();
  await expect(history(page).getByRole("link", { name: /hello atlas/ }).locator(":scope > [aria-hidden]")).toHaveCount(1);
  // Under All personas, New chat from the welcome falls back to the default...
  await newChat(page);
  await expect(onCarousel(page)).toHaveAccessibleName("Atlas Prime");
  // ...and from a conversation, picks that conversation's persona.
  await page.goto(novaChat);
  await newChat(page);
  await expect(onCarousel(page)).toHaveAccessibleName("Nova");
  expect(mock.created).toHaveLength(2);
  expect(mock.chatPersonaFilters).toEqual(expect.arrayContaining(["", NOVA.id, "all"]));
  // Filtered to one persona, the list ends with a way to start another chat with it.
  await pick(page, /^Nova/);
  await expect(history(page).getByRole("button", { name: "New chat with Nova" })).toBeVisible();
  await pick(page, "All personas");
  await expect(history(page).getByRole("button", { name: /^New chat with/ })).toHaveCount(0);

  // The pick lasts for the session.
  await page.goto(atlasChat);
  await expect(picked(page)).toHaveAccessibleName(shows("All personas"));
  expect(mock.unhandled).toEqual([]);
});

test("picking a persona in the sidebar opens its newest conversation", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("hello atlas");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  const atlasChat = new URL(page.url()).pathname;

  // A persona with no conversations leaves the open one alone and offers to start one.
  await pick(page, /^Nova/);
  await expect(history(page).getByText("No conversations with Nova yet.")).toBeVisible();
  expect(new URL(page.url()).pathname).toBe(atlasChat);
  await history(page).getByRole("button", { name: "Start one with Nova →" }).click();
  await expect(page).not.toHaveURL(new RegExp(atlasChat));
  await composer(page).fill("hi nova");
  await composer(page).press("Enter");
  await expect(history(page).getByRole("link", { name: /hi nova/ })).toBeVisible();
  const novaChat = new URL(page.url()).pathname;

  // Switching personas follows to each one's newest conversation.
  await pick(page, /^Atlas/);
  await expect(page).toHaveURL(new RegExp(atlasChat));
  await pick(page, /^Nova/);
  await expect(page).toHaveURL(new RegExp(novaChat));

  // All personas keeps the open conversation.
  await pick(page, "All personas");
  await expect(history(page).getByRole("link", { name: /hello atlas/ })).toBeVisible();
  expect(new URL(page.url()).pathname).toBe(novaChat);
  expect(mock.unhandled).toEqual([]);
});

test("without personas the built-in Assistant is the default and there's no switcher", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  // With no personas there is no one to filter by: no chip.
  await expect(strip(page)).toHaveCount(0);
  await newChat(page);
  await expect(page.getByRole("heading", { level: 1, name: "Assistant" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Next persona" })).toHaveCount(0);
  await welcomeBox(page).fill("hello");
  await welcomeBox(page).press("Enter");
  await expect(composer(page)).toBeVisible();
  await expect(switcher(page)).toHaveCount(0);
  expect(mock.created[0].persona_id).toBeUndefined();
  expect(mock.unhandled).toEqual([]);
});

test("personas sit in the Chats list only: the collapsed strip and app screens never show them", async ({ page }) => {
  await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?project=WEB");
  const menu = page.getByRole("complementary", { name: "Main menu" });
  // Expanded on a chat screen: the Chats list leads with the persona filter.
  await expect(strip(page)).toBeVisible();
  // A screen with a list of its own (Tasks) puts it in the column instead, with no personas.
  await page.goto("/tickets?project=WEB");
  await expect(strip(page)).toHaveCount(0);
  await expect(menu.getByRole("button", { name: /^(Atlas|Nova)/ })).toHaveCount(0);
  // Collapsed, the strip holds the same fixed items on every screen, and no personas either.
  await menu.getByRole("button", { name: "Collapse sidebar" }).click();
  await expect(menu.getByRole("button", { name: /^(Atlas|Nova)/ })).toHaveCount(0);
  await page.goto("/chat?project=WEB");
  await expect(menu.getByRole("button", { name: /^(Atlas|Nova)/ })).toHaveCount(0);
  await expect(strip(page)).toHaveCount(0);
  await menu.getByRole("button", { name: "Expand sidebar" }).click();
  await expect(strip(page)).toBeVisible();
});

test("a new conversation opens at once, without waiting for the lists to refresh", async ({ page }) => {
  await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("hello atlas");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  await expect(page.getByTestId("assistant-identity").first()).toContainText("Atlas");

  await page.route(/\/api\/v1\/chats\?/, async (route) => {
    await new Promise((r) => setTimeout(r, 4000));
    await route.fallback();
  });
  await page.getByRole("button", { name: "New chat", exact: true }).first().click();
  await expect(page).toHaveURL(/\/chat\?new/, { timeout: 2500 });
});

test("the left column keeps its width whatever the titles and persona filter", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("hello atlas");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  await expect(page.getByTestId("assistant-identity").first()).toContainText("Atlas");
  mock.chats[0].title = "A title still being generated that keeps going and going well past the width of the menu";
  await page.reload();
  await expect(history(page).getByRole("link", { name: /A title still being generated/ })).toBeVisible();

  const menu = page.getByRole("complementary", { name: "Main menu" });
  const width = async () => (await menu.boundingBox())!.width;
  expect(await width()).toBe(248);
  await expect(picked(page)).toHaveAccessibleName(shows("All personas"));
  expect(await width()).toBe(248);
  await pick(page, /^Atlas/);
  await expect(picked(page)).toHaveAccessibleName(shows("Atlas"));
  expect(await width()).toBe(248);
});

test("the header names the chat's persona: it switches an empty chat, then starts a new chat once there are messages", async ({ page }) => {
  await installChatApi(page, { personas: [ATLAS, NOVA] });
  const id = await openEmptyChat(page, { persona_id: ATLAS.id });
  await page.goto(`/chat/${id}`);
  const header = page.getByTestId("chat-header");
  const control = header.getByRole("button", { name: "Persona: Atlas" });
  await expect(control).toBeVisible();
  await control.click();
  await expect(page.getByRole("menu").getByText("Persona for this conversation")).toBeVisible();
  await page.getByRole("menuitem", { name: /Nova/ }).click();
  // An empty chat is replaced by one with the new persona, as the composer's pill does.
  await expect(header.getByRole("button", { name: "Persona: Nova" })).toBeVisible();
  await composer(page).fill("hello nova");
  await composer(page).press("Enter");
  await expect(page.getByTestId("assistant-identity").first()).toContainText("Nova");
  await header.getByRole("button", { name: "Persona: Nova" }).click();
  await expect(page.getByRole("menu").getByText("New chat with")).toBeVisible();
  await page.getByRole("menuitem", { name: /Atlas/ }).click();
  await expect(page).toHaveURL(new RegExp(`/chat\\?new&persona=${ATLAS.id}`));
});

test("the welcome's carousel slides between personas and keeps focus on the arrow keys", async ({ page }) => {
  await installChatApi(page, { personas: [ATLAS, NOVA] });
  await page.goto("/chat?new");
  const current = onCarousel(page);
  await expect(current).toHaveAccessibleName("Atlas");
  // Nothing moves on load.
  await expect(current.locator(".motion-slide")).toHaveCount(0);
  await current.focus();
  await page.keyboard.press("ArrowRight");
  await expect(current).toHaveAccessibleName("Nova");
  await expect(current).toBeFocused();
  // The picked persona slides in from the side it came from.
  await expect(current.locator(".motion-slide")).toHaveCSS("animation-name", "motion-slide");
  await expect(current.locator(".motion-slide")).toHaveAttribute("style", /--slide-from: ?1/);
  await page.getByRole("button", { name: "Previous persona" }).click();
  await expect(current).toHaveAccessibleName("Atlas");
  await expect(current.locator(".motion-slide")).toHaveAttribute("style", /--slide-from: ?-1/);
});
