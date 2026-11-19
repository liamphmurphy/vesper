import { expect, test, type Page } from "@playwright/test";
import { installAgentApi } from "./mock-agent-api";

const review = (page: Page) => page.getByRole("button", { name: /Review changes/ });
const save = (page: Page) => page.getByRole("dialog").getByRole("button", { name: /Save as v/ });

/** Saving is two steps: review the changes, then save from the dialog. */
async function saveDefinition(page: Page) {
  await review(page).click();
  await save(page).click();
}

test("default model on persona page uses chat-models catalog and updates work settings", async ({ page }) => {
  const mock = await installAgentApi(page);
  await page.goto("/agents/atlas?tab=settings");
  await expect(page.getByLabel("Harness", { exact: true })).toHaveValue("Claude Code");
  await expect(page.getByLabel("Model", { exact: true })).toHaveValue("Opus 5.5");
  await page.getByRole("link", { name: "Change model on persona page" }).click();
  await expect(page).toHaveURL(/\/settings\?section=personas&persona=00000000-0000-4000-8000-000000000001/);

  // Pick Codex · gpt-5-codex and High effort from the live /chat-models menu.
  await page.getByRole("button", { name: "Default model and effort for Atlas" }).click();
  await page.getByRole("menuitem", { name: "Codex gpt-5-codex" }).click();
  await expect(mock.saved.personas.at(-1)?.body).toMatchObject({ default_harness: "codex", default_model: "gpt-5-codex" });

  await page.getByRole("button", { name: "Default model and effort for Atlas" }).click();
  await page.getByRole("menuitem", { name: "High", exact: true }).click();
  await expect(mock.saved.personas.at(-1)?.body).toMatchObject({ default_effort: "high" });

  // Work list chip and Work settings both reflect the updated model and effort.
  await expect(page.getByTestId("persona-work")).toContainText("gpt-5-codex");
  await page.getByRole("link", { name: "Work settings" }).click();
  await expect(page).toHaveURL(/\/agents\/atlas\?tab=settings/);
  await expect(page.getByLabel("Harness", { exact: true })).toHaveValue("Codex");
  await expect(page.getByLabel("Model", { exact: true })).toHaveValue("gpt-5-codex");
  await expect(page.getByLabel("Effort", { exact: true })).toHaveValue("High");
  expect(mock.unhandled).toEqual([]);
});

test("editor: usage fallbacks pick from live chat-models catalog and save", async ({ page }) => {
  const mock = await installAgentApi(page);
  await page.goto("/agents/atlas?tab=settings");
  await page.getByRole("button", { name: "Add fallback" }).click();
  // Auto-initializes to Codex default model from /chat-models catalog.
  const fbBtn = page.getByRole("button", { name: "Fallback 1 model and effort" });
  await expect(fbBtn).toContainText("Codex · gpt-5-codex");

  // Switch fallback to Antigravity Gemini 2.5 Pro (which has no effort column).
  await fbBtn.click();
  await expect(page.getByRole("group", { name: "Reasoning effort" })).toBeVisible();
  await page.getByRole("menuitem", { name: "Antigravity Gemini 2.5 Pro" }).click();
  await expect(fbBtn).toContainText("Antigravity · Gemini 2.5 Pro");
  await fbBtn.click();
  await expect(page.getByRole("group", { name: "Reasoning effort" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  await saveDefinition(page);
  await expect(page.getByRole("dialog")).toBeHidden();
  const spec = (mock.saved.definition.at(-1) as { spec: { fallbacks: Array<{ harness: string; model: string }> } }).spec;
  expect(spec.fallbacks).toEqual([{ harness: "antigravity", model: "gemini-2.5-pro" }]);
  expect(mock.unhandled).toEqual([]);
});

test("override dialog: offers another harness and live catalog models, saves it, reload shows it", async ({ page }) => {
  const mock = await installAgentApi(page);
  await page.goto("/agents/atlas?tab=settings");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await page.getByRole("menuitem", { name: "Web app" }).click();
  const dialog = page.getByRole("dialog");
  const radio = dialog.getByRole("radiogroup", { name: "Harness" }).getByRole("radio", { name: "Codex" });
  await expect(radio).toBeVisible();
  await radio.click();
  await expect(radio).toBeChecked();
  await expect(dialog.locator("#ov-models option[value='gpt-5-codex']")).toHaveCount(1);
  await dialog.getByLabel("Model", { exact: true }).fill("gpt-5-codex");
  await dialog.getByRole("button", { name: "Save override" }).click();
  await expect(dialog).toBeHidden();
  const body = mock.saved.overrides.at(-1)!.body;
  expect(body.harness).toBe("codex");
  expect(body.model).toBe("gpt-5-codex");

  await page.reload();
  const panel = page.getByRole("complementary", { name: "Overrides and versions" });
  await expect(panel.getByText("harness = codex")).toBeVisible();
  await panel.getByRole("button", { name: /Web app \d+ change/ }).click();
  await expect(page.getByRole("dialog").getByRole("radiogroup", { name: "Harness" }).getByRole("radio", { name: "Codex" })).toBeChecked();
});

test("editor saves selective memory and an explicit independent-review policy", async ({ page }) => {
  const mock = await installAgentApi(page);
  await page.goto("/agents/atlas?tab=settings");
  await expect(page.getByRole("radio", { name: "Selective", exact: true })).toBeChecked();
  await expect(page.getByLabel("Token budget", { exact: true })).toHaveValue("1500");
  await page.getByRole("switch", { name: "Require independent review before Done" }).click();
  // Commit the displayed memory defaults into this new definition explicitly.
  await page.getByRole("radio", { name: "Linked", exact: true }).click();
  await page.getByRole("radio", { name: "Selective", exact: true }).click();
  await saveDefinition(page);
  await expect(review(page)).toBeDisabled();
  const spec = (mock.saved.definition.at(-1) as { spec: { review_required: boolean; memory: { inject: string; max_tokens: number } } }).spec;
  expect(spec.review_required).toBe(true);
  expect(spec.memory).toMatchObject({ inject: "selective", max_tokens: 1500 });
  await page.reload();
  await expect(page.getByRole("switch", { name: "Require independent review before Done" })).toBeChecked();
  await expect(page.getByRole("radio", { name: "Selective", exact: true })).toBeChecked();
});
