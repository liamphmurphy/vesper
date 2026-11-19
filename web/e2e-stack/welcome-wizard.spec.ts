import { expect, test, type Page } from "@playwright/test";

// The first-run Welcome Wizard (LAZYAGENTS-102) on the real stack: no
// page.route mocks. The stack's user has never finished setup, so "/" lands in
// the wizard. Runs use the host's CLI sign-ins (RUNNER_BACKEND=local), so
// Verify lists the fake CLI's models with nothing to paste (pasting a key is
// covered by e2e/welcome-wizard.spec.ts and the Go tests), and the persona is drafted in a hidden setup
// chat where the fake harness (FAKE_HARNESS_MODE=chat-read) answers the
// "(Vesper setup)" prompts with propose_persona. Meeting the persona approves it
// through the usual proposal path, makes it the default and lands in a chat
// with it that really answers.

const API = process.env.E2E_STACK_API_URL;
if (!API) throw new Error("E2E_STACK_API_URL is not set; run `npm run e2e:stack`");

// A 1×1 PNG.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");

async function wizardCard(page: Page) {
  const wizard = page.getByTestId("welcome-wizard");
  await expect(wizard).toBeVisible();
  return wizard;
}

test("Welcome Wizard: from a fresh install to a first chat", async ({ page, request }) => {
  test.setTimeout(180_000);
  const get = async (path: string) => {
    const res = await request.get(`${API}/api/v1${path}`);
    expect(res.ok(), `${path}: ${res.status()}`).toBeTruthy();
    return res.json();
  };
  expect((await get("/me")).onboarded_at).toBeUndefined();
  const avatarUploads: string[] = [];
  page.on("request", (r) => { if (r.url().includes("/api/v1/me/avatar") && r.method() === "PUT") avatarUploads.push(r.url()); });

  await page.goto("/");
  await expect(page).toHaveURL(/\/chat\?new$/);
  const wizard = await wizardCard(page);
  await expect(wizard.getByRole("heading", { name: "Assistant" })).toBeVisible();
  const checklist = page.getByRole("region", { name: "Getting set up" });
  await expect(checklist).toBeVisible();
  await wizard.getByRole("button", { name: "Let’s begin" }).click();

  // 1 · About you: the photo is optional and only uploaded on Continue.
  await expect(wizard.getByText("First, how should I address you").first()).toBeVisible();
  await expect(wizard.getByText("Optional", { exact: true })).toBeVisible();
  await wizard.getByLabel("Your name").fill("Ada Lovelace");
  await expect(wizard.getByTestId("profile-photo")).toContainText("A");
  await wizard.getByLabel("What you do").fill("Backend engineer, Go");
  await wizard.getByLabel("Profile photo").setInputFiles({ name: "me.png", mimeType: "image/png", buffer: PNG });
  await expect(wizard.getByRole("img", { name: "Your profile photo" })).toBeVisible();
  await expect(wizard.getByRole("button", { name: "Remove" })).toBeVisible();
  expect(avatarUploads).toHaveLength(0);
  await wizard.getByRole("button", { name: "Continue" }).click();

  // 2 · Connect a harness: required, no Skip, the image-capable harnesses wear an Images badge.
  await expect(wizard.getByText("Next, I need a mind to run on").first()).toBeVisible();
  expect(avatarUploads).toHaveLength(1);
  await expect(checklist.getByRole("listitem").first()).toHaveAttribute("data-state", "done");
  await expect(wizard.getByRole("region", { name: "Codex" }).getByTestId("codex-images")).toHaveText("Images");
  await expect(wizard.getByRole("region", { name: "Antigravity" }).getByTestId("antigravity-images")).toHaveText("Images");
  await expect(wizard.getByRole("button", { name: /skip/i })).toHaveCount(0);
  const next = wizard.getByRole("button", { name: "Continue" });
  await expect(next).toBeDisabled();
  await expect(wizard.getByTestId("wizard-hint")).toHaveText("Connect at least one to continue.");
  const claude = wizard.getByRole("region", { name: "Claude Code" });
  // This stack's runner uses the host's CLI sign-ins (the fake): nothing to paste, Verify checks the sign-in.
  await expect(wizard.getByRole("note")).toContainText("sign-ins on its host");
  await expect(wizard.getByLabel("Claude Code credential")).toHaveCount(0);
  await claude.getByRole("button", { name: "Verify Claude Code" }).click();
  await expect(claude.getByTestId("claude-code-models")).toHaveText("1 model");
  await expect(claude).toHaveAttribute("data-verified", "true");
  await expect(wizard.getByTestId("wizard-hint")).toHaveText("Image generation stays off until Codex or Antigravity is connected.");
  // Antigravity is checked the same way (the fake answers `agy models`) and makes images, so the hint clears.
  const agy = wizard.getByRole("region", { name: "Antigravity" });
  await agy.getByRole("button", { name: "Verify Antigravity" }).click();
  await expect(agy.getByTestId("antigravity-models")).toHaveText("2 models");
  await expect(wizard.getByTestId("wizard-hint")).toHaveText("");
  await next.click();

  // 3 · First persona: drafted, refined, met.
  await expect(wizard.getByText("Lastly, who else would you like to talk to?").first()).toBeVisible();
  await wizard.getByRole("button", { name: "A blunt senior engineer who pairs with me" }).click();
  await wizard.getByRole("button", { name: "Draft persona" }).click();
  const draft = wizard.getByTestId("persona-draft");
  await expect(draft).toContainText("Hackerman", { timeout: 90_000 });
  await expect(draft).toContainText("Concise");
  await expect(draft.getByRole("listitem")).toHaveText(["Reproduce a bug before fixing it", "Lead with the answer", "Push back with alternatives"]);
  await wizard.getByLabel("Describe them").fill("Make them more playful");
  await wizard.getByRole("button", { name: "Redraft" }).click();
  await expect(draft).toContainText("Playful", { timeout: 90_000 });
  await wizard.getByRole("button", { name: "Meet them" }).click();

  // Finale: the new persona is the default and the welcome is a working composer again.
  await expect(page).toHaveURL(/\/chat\?new&persona=[0-9a-f-]{36}$/);
  await expect(page.getByTestId("welcome-wizard")).toHaveCount(0);
  await expect(page.getByRole("heading", { level: 1, name: "Hackerman" })).toBeVisible();
  const box = page.getByPlaceholder("Message Hackerman…");
  await expect(box).toBeVisible();
  await expect(page.getByRole("radiogroup", { name: "Who to talk to" }).getByRole("radio", { name: "Assistant" })).toBeVisible();

  const me = await get("/me");
  expect(me.name).toBe("Ada Lovelace");
  expect(me.role_title).toBe("Backend engineer, Go");
  expect(me.avatar_url).toBeTruthy();
  expect(me.onboarded_at).toBeTruthy();
  const personas = await get("/personas");
  const hackerman = personas.personas.find((p: { name: string }) => p.name === "Hackerman");
  expect(hackerman?.tone).toBe("playful");
  expect(personas.default_persona_id).toBe(hackerman.id);
  const work = await get("/memories?type=work");
  expect(work.memories.map((m: { body?: string; summary?: string }) => m.body ?? m.summary)).toContain("Backend engineer, Go");
  // The setup chat stays out of the person's chat list.
  const chats = await get("/chats");
  expect(chats.chats.filter((c: { title: string }) => c.title === "Welcome setup")).toHaveLength(0);

  await box.fill("hello there");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]{36}$/);
  await expect(page.getByText("Chat reply: ", { exact: false }).last()).toBeVisible({ timeout: 60_000 });
  const chatId = page.url().split("/").pop();
  expect((await get(`/chats/${chatId}`)).persona?.id).toBe(hackerman.id);

  // Finished: "/" never shows the wizard again; Settings can start it over.
  await page.goto("/");
  await expect(page).toHaveURL(/\/chat\?new&persona=/);
  await expect(page.getByTestId("welcome-wizard")).toHaveCount(0);
  await page.goto("/settings");
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Workspace/ }).click();
  await page.getByRole("link", { name: "Run setup again →" }).click();
  await wizardCard(page);
  expect((await get("/me")).onboarded_at).toBe(me.onboarded_at);
});

test("Welcome Wizard respects reduced motion", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/chat?new&setup");
  const wizard = await wizardCard(page);
  // The line is there in full at once, not typed out.
  await expect(wizard.locator("p[aria-live]")).toHaveText(/^Good (morning|afternoon|evening)\. I’m your Assistant.*minute\.$/);
  await expect(wizard.locator("p[aria-live] .sr-only")).toHaveCount(0);
  const motion = async (selector: string) =>
    wizard.locator(selector).first().evaluate((el) => {
      const s = getComputedStyle(el);
      return { name: s.animationName, duration: s.animationDuration };
    });
  expect(await motion(".wizard-enter")).toEqual({ name: "motion-fade-in", duration: "0.12s" });
  expect((await motion(".wizard-breathe")).name).toBe("none");
  expect((await motion(".wizard-caret")).name).toBe("none");
  await wizard.getByRole("button", { name: "Let’s begin" }).click();
  await expect(wizard.getByText("First, how should I address you").first()).toBeVisible();
  expect(await motion(".wizard-enter")).toEqual({ name: "motion-fade-in", duration: "0.12s" });
});
