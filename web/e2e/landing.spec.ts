import { expect, test } from "@playwright/test";
import { AGENTS, installChatApi, persona } from "./mock-chat-api";

// The landing page opens a new, unsaved chat with the persona the person chats with most;
// the Dashboard lives at /dashboard.

const ATLAS = persona(1, { name: "Atlas", is_default: true, chat_count: 2, last_used_at: "2026-11-09T09:00:00.000Z" });
const NOVA = persona(2, { name: "Nova", chat_count: 9, last_used_at: "2026-11-01T09:00:00.000Z" });

test("a fresh install lands in the Welcome Wizard", async ({ page }) => {
  await installChatApi(page, { onboarded: false });
  await page.goto("/");
  await expect(page).toHaveURL(/\/chat\?new$/);
  await expect(page.getByTestId("welcome-wizard")).toBeVisible();
  await expect(page.getByRole("complementary", { name: "Main menu" }).getByRole("region", { name: "Getting set up" })).toBeVisible();
});

test("a finished user only sees the wizard again from Settings", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?new");
  await expect(page.getByRole("radiogroup", { name: "Who to talk to" })).toBeVisible();
  await expect(page.getByTestId("welcome-wizard")).toHaveCount(0);
  await page.goto("/settings");
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Workspace/ }).click();
  await page.getByRole("link", { name: "Run setup again →" }).click();
  await expect(page).toHaveURL(/\/chat\?new&setup$/);
  await expect(page.getByTestId("welcome-wizard")).toBeVisible();
});

test("/ opens an empty chat with the most used persona instead of resuming the newest", async ({ page }) => {
  const api = await installChatApi(page, { personas: [ATLAS, NOVA] });
  const t = "2026-11-09T09:00:00.000Z";
  api.chats.push({
    id: "c0000000-0000-4000-8000-000000000001", title: "Earlier chat", agent_id: AGENTS[0].id, harness: "claude-code", model: "claude-sonnet-5-5", state: "idle",
    archived: false, revision: 1, message_count: 2, created_at: t, updated_at: t, last_message_at: t, persona_id: ATLAS.id,
  } as (typeof api.chats)[number]);

  await page.goto("/");
  await expect(page).toHaveURL(new RegExp(`/chat\\?new&persona=${NOVA.id}$`));
  await expect(page.getByRole("radiogroup", { name: "Who to talk to" }).getByRole("radio", { checked: true })).toHaveAccessibleName("Nova");
  expect(api.created).toHaveLength(0);
});

test("with no chats yet, / opens an empty chat with the default persona", async ({ page }) => {
  await installChatApi(page, { personas: [{ ...ATLAS, chat_count: 0 }, { ...NOVA, chat_count: 0 }] });
  await page.goto("/");
  await expect(page).toHaveURL(new RegExp(`/chat\\?new&persona=${ATLAS.id}$`));
  await expect(page.getByRole("radiogroup", { name: "Who to talk to" }).getByRole("radio", { checked: true })).toHaveAccessibleName("Atlas");
});
