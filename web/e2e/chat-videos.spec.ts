import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// A video a coding chat renders: one card that follows its stages under the turn, then on
// the reply as a player (or what went wrong), and its copy in the Library.

async function ask(page: Page, prompt: string) {
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill(prompt);
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
}

// The mockup the card follows is dark; the screenshots match it.
test.use({ colorScheme: "dark" });

const stages = (card: ReturnType<Page["getByTestId"]>) => card.getByRole("list", { name: "Stages" }).getByRole("listitem");
const doneStages = (card: ReturnType<Page["getByTestId"]>) => card.getByRole("list", { name: "Stages" }).locator('li[data-state="done"]');

// After the first message the composer is a combobox (it suggests @mentions).
async function say(page: Page, prompt: string) {
  const box = page.getByLabel("Message", { exact: true });
  await box.fill(prompt);
  await box.press("Enter");
}

test("the card follows each stage", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  for (const [i, [state, done]] of ([["write", 0], ["stills", 1], ["render", 2], ["encode", 3]] as const).entries()) {
    await say(page, `video: ${state}`);
    await expect(page.getByTestId("video-card")).toHaveCount(i + 1);
    const card = page.getByTestId("video-card").last();
    await expect(card).toHaveAttribute("data-stage", state);
    await expect(card).toContainText("Black cat on a rainy cyberpunk street");
    await expect(card).toContainText("1920×1080 · 30 fps · 15 s");
    await expect(doneStages(card)).toHaveCount(done);
    await expect(stages(card).nth(done)).toHaveAttribute("data-state", "active");
    await card.screenshot({ path: `test-results/video-${state}.png` });
  }
});

test("writing shows the renderer's latest lines over a shimmer", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: write");
  const card = page.getByTestId("video-card");
  await expect(card).toContainText("Writing cyberpunk_cat.py");
  await expect(card).toContainText("1,024 lines");
  await expect(card.getByTestId("video-script")).toContainText("def render_frame(t)");
  await expect(card).toContainText("The preview shows up once the stills are rendered");
});

test("stills show their frames and the checks", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: stills");
  const card = page.getByTestId("video-card");
  await expect(card.getByTestId("video-stills").getByRole("img")).toHaveCount(4);
  await expect(card.getByTestId("video-stills")).toContainText("frame 120");
  const checks = card.getByTestId("video-checks").getByRole("listitem");
  await expect(checks).toHaveCount(4);
  await expect(checks.nth(0)).toContainText("✓ Paws stay planted");
  await expect(checks.nth(3)).toContainText("○ Neon reflections");
});

test("rendering shows progress, the latest frame and the filmstrip", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: render");
  const card = page.getByTestId("video-card");
  await expect(card.getByTestId("video-frames")).toHaveText("212 / 450");
  await expect(card.getByRole("progressbar", { name: "Render progress" })).toHaveAttribute("aria-valuenow", "47");
  await expect(card.getByTestId("video-eta")).toContainText(/Frame 212 of 450 · ~\dm \d\ds left/);
  await expect(card.getByTestId("video-strip").locator("img")).toHaveCount(14);
  await expect(card.getByTestId("video-strip").locator("> div")).toHaveCount(30);
});

test("while the turn runs the card shows live with Stop", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 60_000 });
  await ask(page, "video-live: render");
  const live = page.getByTestId("thinking").getByTestId("video-card");
  await expect(live).toBeVisible();
  await expect(live.getByRole("button", { name: "Stop" })).toBeVisible();
  await live.screenshot({ path: "test-results/video-live.png" });
});

test("a finished video plays in place and is saved to the Library", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: done");
  const card = page.getByTestId("video-card");
  await expect(card).toHaveAttribute("data-state", "done");
  await expect(doneStages(card)).toHaveCount(5);
  await expect(card).toContainText("black-cat-on-a-rainy-cyberpunk-street.mp4");
  await expect(card).toContainText("✓ Saved to Library");
  await expect(card.getByTestId("video-meta")).toHaveText("1920×1080 · 30 fps · H.264 · 24.1 MB");
  const player = card.getByTestId("video-player");
  await expect(player).toHaveAttribute("poster", /\/frames\/poster\/0\?v=1$/);
  await expect(card.getByRole("button", { name: "Play" }).first()).toBeVisible();
  await expect(card.getByRole("slider", { name: "Seek" })).toBeVisible();
  await expect(card).toContainText("0:00 / 0:15");
  await expect(card.getByRole("link", { name: "Open in Library" })).toHaveAttribute("href", /\/library\?tab=videos&item=/);
  // The card sits above the reply, and the renderer note under it.
  const reply = page.getByTestId("assistant-message").last();
  await expect(reply.getByTestId("video-renderer")).toContainText("Renderer: cyberpunk_cat.py (1,024 lines) · rendered in 1m");
  await reply.screenshot({ path: "test-results/video-done.png" });
});

test("a failed video says why, shows its log and retries from its stage", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: failed");
  const card = page.getByTestId("video-card");
  await expect(stages(card).nth(3)).toHaveAttribute("data-state", "failed");
  const alert = card.getByRole("alert");
  await expect(alert).toContainText("Encoding failed");
  await expect(alert).toContainText("ffmpeg isn't installed");
  await expect(alert).toContainText("Not saved");
  await alert.getByRole("button", { name: "Show log" }).click();
  await expect(card.getByTestId("video-log")).toContainText("ffmpeg: not found");
  await card.screenshot({ path: "test-results/video-failed.png" });
  await alert.getByRole("button", { name: "Retry encode" }).click();
  await expect(page.getByTestId("user-message").last()).toContainText('Retry the video "Black cat on a rainy cyberpunk street" from the encode step.');
});

test("a stopped video says so", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await ask(page, "video: stopped");
  await expect(page.getByTestId("video-card").getByRole("alert")).toContainText("Stopped");
});
