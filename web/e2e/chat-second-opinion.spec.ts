import { expect, test, type Page } from "@playwright/test";
import { installChatApi, openEmptyChat } from "./mock-chat-api";

const composer = (page: Page) => page.getByRole("combobox", { name: "Message" });
const picker = (page: Page) => page.getByRole("button", { name: /^Model and effort for the next message/ });

async function openChat(page: Page) {
  await page.goto("/chat?project=WEB");
  await openEmptyChat(page);
  await expect(composer(page)).toBeVisible();
}

test("reply toolbar second opinion supports focus, follow-up Q&A, quoting, independent thread, and leaves parent cache intact", async ({ page }) => {
  const mock = await installChatApi(page, { replyDelayMs: 10 });
  await openChat(page);
  await composer(page).fill("draft the mutex fix");
  await composer(page).press("Enter");

  const reply = page.getByTestId("assistant-message").first();
  await expect(reply).toContainText("Echo: draft the mutex fix");
  await expect(picker(page)).toHaveText("Opus 5.5 · Auto");

  await reply.hover();
  await reply.getByTestId("message-second-opinion").click();
  await expect(page.getByTestId("second-opinion-menu")).toBeVisible();
  await page.getByRole("textbox", { name: "Second opinion focus" }).fill("check lock ordering");
  await page.getByTestId("second-opinion-option-codex-gpt-5-codex").click();

  const card = reply.getByTestId("second-opinion-card");
  await expect(card).toBeVisible();
  await expect(card.getByTestId("second-opinion-model")).toHaveText("Codex · gpt-5-codex");
  await expect(card).toContainText("Second opinion (Codex · gpt-5-codex):");
  await expect(card).toContainText("check lock ordering");

  // Parent chat harness, model, and transcript remain completely untouched (prompt cache stays warm).
  await expect(picker(page)).toHaveAttribute("aria-label", /Claude Code/);
  await expect(picker(page)).toHaveText("Opus 5.5 · Auto");
  await expect(page.getByTestId("system-message")).toHaveCount(0);
  await expect(page.getByTestId("user-message")).toHaveCount(1);
  expect(mock.secondOpinions).toHaveLength(1);
  expect(mock.secondOpinions[0]).toMatchObject({
    harness: "codex",
    model: "gpt-5-codex",
    body: "check lock ordering",
  });

  // Follow-up conversation inside the second-opinion card stays scoped to the child session.
  await card.getByTestId("second-opinion-followup-toggle").click();
  await card.getByTestId("second-opinion-followup-input").fill("is a try-lock needed?");
  await card.getByTestId("second-opinion-followup-send").click();
  await expect(card).toContainText("Echo: is a try-lock needed?");
  await expect(page.getByTestId("user-message")).toHaveCount(1);

  // Quote inserts an attributed blockquote into the main composer without altering parent history.
  await card.getByTestId("second-opinion-quote").click();
  await expect(composer(page)).toHaveValue(/> \*\*Second opinion \(Codex · gpt-5-codex\):\*\*/);
  await composer(page).fill("");

  // Regular Slack-style threads on the same reply remain independent and uncluttered.
  await reply.hover();
  await reply.getByRole("button", { name: "Start a thread" }).click();
  await expect(page).toHaveURL(/panel=thread/);
  await expect(page.getByRole("textbox", { name: "Reply in thread" })).toBeVisible();
  await expect(page.getByRole("complementary", { name: "Panel" })).not.toContainText("Second opinion (Codex");
  await expect(reply.getByTestId("second-opinion-card")).toHaveCount(1);
  expect(mock.unhandled).toEqual([]);
});

test("/compare command and HarnessSwitchDialog 'Second opinion instead' keep parent prompt cache intact", async ({ page }) => {
  const mock = await installChatApi(page, { replyDelayMs: 10 });
  await openChat(page);
  await composer(page).fill("compare approaches");
  await composer(page).press("Enter");
  const reply = page.getByTestId("assistant-message").first();
  await expect(reply).toContainText("Echo: compare approaches");

  // /comp completes to /compare; once a space follows the model token, menu closes so Enter submits the full command.
  await composer(page).pressSequentially("/comp");
  await expect(page.getByTestId("command-suggestions")).toContainText("/compare");
  await composer(page).fill("/compare codex check edge cases");
  await expect(page.getByTestId("command-suggestions")).toHaveCount(0);
  await composer(page).press("Enter");

  await expect(composer(page)).toHaveValue("");
  const firstCard = reply.getByTestId("second-opinion-card").first();
  await expect(firstCard).toBeVisible();
  await expect(firstCard.getByTestId("second-opinion-model")).toHaveText("Codex · gpt-5-codex");
  await expect(firstCard).toContainText("check edge cases");
  await expect(page.getByTestId("user-message")).toHaveCount(1);
  await expect(page.getByTestId("system-message")).toHaveCount(0);

  // Selecting another harness in the main picker offers "Second opinion instead" inside HarnessSwitchDialog.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  const dialog = page.getByRole("dialog", { name: "Switch to Codex · gpt-5-codex?" });
  await expect(dialog).toBeVisible();
  await dialog.getByTestId("switch-second-opinion").click();

  await expect(dialog).toHaveCount(0);
  await expect(page.getByTestId("pending-switch")).toHaveCount(0);
  await expect(picker(page)).toHaveText("Opus 5.5 · Auto");
  await expect(reply.getByTestId("second-opinion-card")).toHaveCount(2);
  expect(mock.secondOpinions).toHaveLength(2);
  expect(mock.unhandled).toEqual([]);
});

test("CodePanel fullscreen supports Second opinion… with repository diff context and Escape closes menu first", async ({ page }) => {
  const mock = await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  await composer(page).fill("code: update auth");
  await composer(page).press("Enter");

  const block = page.getByTestId("code-changes");
  await block.getByRole("button", { name: /Changed 3 files/ }).click();
  await block.getByTestId("review-branch").click();

  const panel = page.getByTestId("code-panel");
  await panel.getByTestId("code-fullscreen-open").click();
  await expect(page).toHaveURL(/code=full/);
  await expect(panel).toHaveAttribute("data-fullscreen", "true");

  // Pressing Escape with the Second opinion menu open closes the menu rather than dismissing fullscreen.
  await panel.getByTestId("code-second-opinion").click();
  await expect(page.getByTestId("second-opinion-menu")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("second-opinion-menu")).toHaveCount(0);
  await expect(panel).toHaveAttribute("data-fullscreen", "true");

  await panel.getByTestId("code-second-opinion").click();
  await page.getByTestId("second-opinion-option-codex-gpt-5-codex").click();

  const strip = panel.getByTestId("code-second-opinion-strip");
  await expect(strip).toBeVisible();
  await expect(strip).toContainText("1 second opinion");
  await expect(strip.getByTestId("second-opinion-model")).toHaveText("Codex · gpt-5-codex");
  await expect(strip).toContainText("https://github.com/acme/alpha.git");
  expect(mock.secondOpinions[0]).toMatchObject({
    harness: "codex",
    model: "gpt-5-codex",
    repository: "https://github.com/acme/alpha.git",
  });
  expect(mock.unhandled).toEqual([]);
});
