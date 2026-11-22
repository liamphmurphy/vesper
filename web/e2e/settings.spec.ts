import { expect, test, type Page } from "@playwright/test";
import { generateKeyPairSync } from "node:crypto";
import { catalog, installChatApi, openEmptyChat } from "./mock-chat-api";

const at = "2026-11-04T12:00:00Z";
const SECRET = "sk-proj-super-secret-value-WXYZ";

type Secret = { id: string; name: string; grants_scope?: string; created_at: string; updated_at: string; last_used_at?: string; project?: unknown };

/** Secrets, projects and runner mocks on top of the shared API mock. */
async function installSettingsApi(page: Page, opts: { runners?: boolean; secretsFail?: boolean; signIn?: boolean; noClaude?: boolean; hostDir?: string } = {}) {
  const api = await installChatApi(page, { codexAvailable: false });
  const secrets: Secret[] = [
    { id: "s1", name: "harness:anthropic", created_at: at, updated_at: at, last_used_at: at },
    { id: "s2", name: "git:ssh", grants_scope: "repo:write", created_at: at, updated_at: at },
    { id: "s3", name: "db:staging", grants_scope: "db:migrate", created_at: at, updated_at: at },
  ].filter((s) => !(opts.noClaude && s.name === "harness:anthropic"));
  const puts: Record<string, unknown>[] = [];
  let modelFetches = 0;
  const project = { id: "p1", key: "WEB", name: "Web app", color: "#6e56cf", repo_url: "git@github.com:acme/web.git", default_branch: "main", archived: false, revision: 1 };
  await page.route("**/api/v1/secrets", async (route) => {
    const req = route.request();
    if (opts.secretsFail) return route.fulfill({ status: 500, json: { error: { code: "internal", message: "The API is unavailable." } } });
    if (req.method() === "PUT") {
      const body = req.postDataJSON() as { name: string; value: string };
      puts.push(body);
      const s = { id: `s${secrets.length + 1}`, name: body.name, created_at: at, updated_at: new Date().toISOString() };
      secrets.push(s);
      return route.fulfill({ json: s });
    }
    return route.fulfill({ json: { secrets, key_configured: true, sign_in_available: !!opts.signIn, known: [{ name: "db:staging", description: "Staging database URL" }] } });
  });
  // Sign-ins: the runner shows the provider's page (and code), then stores the login.
  const signIns: Record<string, { id: string; provider: string; status: string; url: string; user_code: string; needs_code: boolean; error: string; expires_at: string; polls: number; pasted?: string }> = {};
  const secretFor: Record<string, string> = { claude: "harness:anthropic", codex: "harness:openai", github: "git:pat" };
  await page.route("**/api/v1/sign-ins", async (route) => {
    const { provider } = route.request().postDataJSON() as { provider: string };
    const s = { id: `si-${provider}`, provider, status: "pending", url: "", user_code: "", needs_code: false, error: "", expires_at: at, polls: 0 };
    signIns[s.id] = s;
    return route.fulfill({ status: 201, json: s });
  });
  await page.route("**/api/v1/sign-ins/*/code", async (route) => {
    const id = route.request().url().split("/").at(-2)!;
    const s = signIns[id];
    s.pasted = (route.request().postDataJSON() as { code: string }).code;
    s.needs_code = false;
    return route.fulfill({ json: s });
  });
  await page.route("**/api/v1/sign-ins/*", async (route) => {
    const id = route.request().url().split("/").at(-1)!;
    const s = signIns[id];
    if (route.request().method() === "DELETE") {
      s.status = "cancelled";
      return route.fulfill({ status: 204 });
    }
    s.polls++;
    if (s.status === "pending" && s.polls >= 2) {
      s.status = "running";
      if (s.provider === "claude") {
        s.url = "https://claude.com/cai/oauth/authorize?code=true";
        s.needs_code = true;
      } else {
        s.url = s.provider === "codex" ? "https://auth.openai.com/codex/device" : "https://github.com/login/device";
        s.user_code = "AB12-CD34";
      }
    } else if (s.status === "running" && (s.provider === "claude" ? !!s.pasted : s.polls >= 4)) {
      s.status = "done";
      secrets.push({ id: `s${secrets.length + 1}`, name: secretFor[s.provider], created_at: at, updated_at: new Date().toISOString() });
    }
    return route.fulfill({ json: s });
  });
  await page.route("**/api/v1/projects", (route) => route.fulfill({ json: [project] }));
  let hostFolders = false;
  let maxSubagents = 3;
  let maxDelegations = 3;
  let tierRouting = true;
  let tierModels: Record<string, { fast?: string; standard?: string; deep?: string }> = {};
  const runnerPuts: Record<string, unknown>[] = [];
  const runnerStatus = () =>
    opts.runners === false
      ? { online: false, runners: [], slots: 0, busy: 0, live: 0, queued: 3, host_folder_workspaces: hostFolders, max_concurrent_subagents: maxSubagents, max_parallel_delegations: maxDelegations, subagent_tier_routing: tierRouting, subagent_tier_models: tierModels }
      : {
          online: true,
          runners: [{ id: "mbp-4242", backend: "microvm", max_concurrent: 4, running: 2, version: "0.9.1", heartbeat_at: new Date().toISOString(), ...(opts.hostDir ? { host_workspaces_dir: opts.hostDir } : {}) }],
          slots: 4, busy: 2, live: 2, queued: 3, host_folder_workspaces: hostFolders, max_concurrent_subagents: maxSubagents, max_parallel_delegations: maxDelegations, subagent_tier_routing: tierRouting, subagent_tier_models: tierModels,
        };
  await page.route("**/api/v1/runner", (route) => route.fulfill({ json: runnerStatus() }));
  await page.route("**/api/v1/runner/settings", (route) => {
    const body = route.request().postDataJSON() as {
      host_folder_workspaces?: boolean;
      max_concurrent_subagents?: number;
      max_parallel_delegations?: number;
      subagent_tier_routing?: boolean;
      subagent_tier_models?: Record<string, { fast?: string; standard?: string; deep?: string }>;
    };
    runnerPuts.push(body);
    if (body.host_folder_workspaces !== undefined) hostFolders = body.host_folder_workspaces;
    if (body.max_concurrent_subagents !== undefined) maxSubagents = body.max_concurrent_subagents;
    if (body.max_parallel_delegations !== undefined) maxDelegations = body.max_parallel_delegations;
    if (body.subagent_tier_routing !== undefined) tierRouting = body.subagent_tier_routing;
    if (body.subagent_tier_models !== undefined) tierModels = body.subagent_tier_models;
    return route.fulfill({ json: runnerStatus() });
  });
  // Like the server: Codex is available once harness:openai exists.
  await page.route("**/api/v1/chat-models", (route) => {
    modelFetches++;
    return route.fulfill({ json: catalog(secrets.some((s) => s.name === "harness:openai")) });
  });
  return { api, puts, runnerPuts, signIns, models: () => modelFetches };
}

test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

test("a full load hydrates Settings after the shell's data arrives and lands on the #section", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await installSettingsApi(page);
  // Hold back only the Settings chunk so the shell's queries always resolve before it hydrates.
  await page.route("**/_next/static/chunks/**", async (route) => {
    const response = await route.fetch();
    const body = await response.body();
    if (body.includes("Shared by every space. Secret encryption is configured on the API server.")) await new Promise((r) => setTimeout(r, 1500));
    await route.fulfill({ response, body });
  });
  await page.goto("/settings#appearance");
  await expect(page.getByRole("link", { name: /Workspace/ }).getByRole("img", { name: "Configured" })).toBeVisible();
  expect(errors).toEqual([]);
  await expect(page.getByRole("heading", { name: "Appearance", exact: true })).toBeInViewport();
});

test("SSH private keys keep their line breaks when replaced or added as an override", async ({ page }) => {
  const mock = await installSettingsApi(page);
  const privateKey = generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  await page.goto("/settings#secrets");
  await page.getByRole("button", { name: "Replace GitHub SSH key" }).click();
  const value = page.getByLabel("New value for git:ssh");
  await expect(value).toBeFocused();
  await value.fill(privateKey);
  await page.getByRole("button", { name: "Save key" }).click();
  await expect(value).toHaveCount(0);
  expect(mock.puts).toEqual([{ name: "git:ssh", value: privateKey }]);
  expect(await page.content()).not.toContain(privateKey);

  await page.getByRole("button", { name: "Add credential" }).click();
  await page.locator("#secrets").getByLabel("Name", { exact: true }).fill("git:ssh");
  await page.locator("#secrets").getByLabel("Value", { exact: true }).fill(privateKey);
  await page.getByRole("button", { name: "Scope", exact: true }).click();
  await page.getByRole("menuitem", { name: "Web app", exact: true }).click();
  await page.getByRole("button", { name: "Save credential" }).click();
  await expect(page.locator("#secrets").getByLabel("Value", { exact: true })).toHaveCount(0);
  expect(mock.puts[1]).toEqual({ name: "git:ssh", value: privateKey, project_key: "WEB" });
  expect(await page.content()).not.toContain(privateKey);
});

test("provider credentials show status and unlocks, are write-only, and saving refreshes the model picker", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/chat?project=WEB");
  await openEmptyChat(page);
  await page.getByRole("button", { name: /^Model and effort for the next message/ }).click();
  await expect(page.getByRole("menuitem", { name: /Codex gpt-5-codex/ })).toHaveAttribute("aria-disabled", "true");
  await page.keyboard.press("Escape");
  const before = mock.models();
  // Settings is the gear in the right rail's foot; it opens client-side, so the model cache survives.
  await page.getByRole("complementary", { name: "Right rail" }).getByRole("link", { name: /Settings/ }).click();
  await expect(page.getByRole("complementary", { name: "Right rail" })).toContainText("a setting runs need is missing");
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /Secrets & Credentials/ }).click();

  await expect(page.getByRole("heading", { name: "Secrets & Credentials", level: 1 })).toBeVisible();
  await expect(page.getByRole("status").filter({ hasText: "Codex can’t run" })).toBeVisible();
  const conn = page.locator("#secrets li");
  await expect(conn.filter({ hasText: "harness:anthropic" })).toContainText("Set");
  await expect(conn.filter({ hasText: "harness:anthropic" })).toContainText("✓ Claude Code");
  await expect(conn.filter({ hasText: "harness:openai" })).toContainText("Not set");
  await expect(conn.filter({ hasText: "harness:openai" })).toContainText("✕ Codex");
  await expect(page.locator("#secrets")).not.toContainText("••••");
  await page.screenshot({ path: "test-results/settings-desktop.png", fullPage: true });

  await page.getByRole("button", { name: "Add OpenAI key" }).click();
  const value = page.getByLabel("New value for harness:openai");
  await expect(value).toBeFocused();
  await expect(value).toHaveAttribute("type", "password");
  await value.fill(SECRET);
  await page.getByRole("button", { name: "Save key" }).click();
  await expect(page.getByRole("status").filter({ hasText: "harness:openai saved. Codex is now available." })).toBeVisible();
  expect(mock.puts).toEqual([{ name: "harness:openai", value: SECRET }]);
  await expect(page.getByLabel("New value for harness:openai")).toHaveCount(0);
  await expect(page.getByText("Codex can’t run")).toHaveCount(0);
  await expect(page.getByRole("complementary", { name: "Right rail" })).not.toContainText("a setting runs need is missing");
  expect(await page.content()).not.toContain(SECRET);

  // Switching from one Replace to another remounts the form with the new name.
  await page.getByRole("button", { name: "Replace db:staging" }).click();
  await page.getByRole("button", { name: "Add credential" }).click();
  const name = page.locator("#secrets").getByLabel("Name", { exact: true });
  await expect(name).toHaveValue("");
  await page.getByRole("button", { name: "Cancel" }).click();
  await expect(page.getByRole("button", { name: "Delete harness:anthropic" })).toBeVisible();

  // The chat model cache was invalidated, so back in chat Codex is selectable
  // without a reload (the cache is otherwise fresh for a minute). Back returns to the empty chat from before.
  await page.goBack();
  await page.goBack();
  await expect(page).toHaveURL(/\/chat\//);
  await page.getByRole("button", { name: /^Model and effort for the next message/ }).click();
  await expect(page.getByRole("menuitem", { name: /Codex gpt-5-codex/ })).not.toHaveAttribute("aria-disabled", "true");
  expect(mock.models()).toBeGreaterThan(before);
});

test("Backup & move exports everything as a download", async ({ page }) => {
  await installSettingsApi(page);
  let hits = 0;
  await page.route("**/api/v1/instance/export", (route) => {
    hits++;
    return route.fulfill({
      status: 200,
      headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="vesper-export-2026-11-12.zip"', "cache-control": "no-store" },
      body: "PK",
    });
  });
  await page.goto("/settings");
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: "Backup & move" }).click();
  const section = page.locator("#backup");
  await expect(section.getByRole("heading", { name: "Backup & move" })).toBeVisible();
  // Import is a command, not a button: it needs an empty instance and the same SECRETS_KEY.
  await expect(section).toContainText("SECRETS_KEY");
  await expect(section.getByRole("button", { name: /import/i })).toHaveCount(0);

  const download = page.waitForEvent("download");
  await section.getByRole("link", { name: "Export everything" }).click();
  expect((await download).suggestedFilename()).toBe("vesper-export-2026-11-12.zip");
  expect(hits).toBe(1);
});

test("runner backends show current values and what they control", async ({ page }) => {
  await installSettingsApi(page);
  await page.goto("/settings#runners");
  const runners = page.locator("#runners");
  await expect(runners.getByRole("rowheader", { name: "mbp-4242" })).toBeVisible();
  await expect(runners).toContainText("RUNNER_BACKEND = docker");
  await expect(runners).toContainText("RUNNER_MAX_CONCURRENT = 4");
  await expect(runners).toContainText("How many runs one runner executes at once");
  await expect(runners).toContainText("2 of 4");
});

test("host folders can only be turned on when a runner has a folder", async ({ page }) => {
  await installSettingsApi(page);
  await page.goto("/settings#runners");
  const runners = page.locator("#runners");
  const toggle = runners.getByRole("switch", { name: "Keep new checkouts in a folder on this machine" });
  await expect(toggle).toHaveAttribute("aria-checked", "false");
  await expect(toggle).toBeDisabled();
  await expect(runners).toContainText("Set VESPER_WORKSPACES_DIR to an absolute path");
});

test("host folders turn on for new runs and show where checkouts go", async ({ page }) => {
  const mock = await installSettingsApi(page, { hostDir: "/Users/me/vesper/workspaces" });
  await page.goto("/settings#runners");
  const runners = page.locator("#runners");
  await expect(runners).toContainText("/Users/me/vesper/workspaces/<run>");
  const toggle = runners.getByRole("switch", { name: "Keep new checkouts in a folder on this machine" });
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  expect(mock.runnerPuts).toEqual([{ host_folder_workspaces: true }]);
  // A reload reads it back from the server.
  await page.reload();
  await expect(runners.getByRole("switch", { name: "Keep new checkouts in a folder on this machine" })).toHaveAttribute("aria-checked", "true");
});

test("subagent and delegation concurrency limits show defaults, validate input, and persist", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/settings#runners");
  const runners = page.locator("#runners");

  const subInput = runners.getByLabel("Max concurrent subagents", { exact: true });
  const delInput = runners.getByLabel("Max parallel delegations", { exact: true });
  await expect(subInput).toHaveValue("3");
  await expect(delInput).toHaveValue("3");

  // Stepper adjusts subagent limit and saves partial payload.
  await runners.getByRole("button", { name: "Increase max concurrent subagents" }).click();
  await expect(subInput).toHaveValue("4");
  expect(mock.runnerPuts.at(-1)).toEqual({ max_concurrent_subagents: 4 });

  // Direct numeric input + Enter updates delegation limit.
  await delInput.fill("5");
  await delInput.press("Enter");
  await expect(delInput).toHaveValue("5");
  expect(mock.runnerPuts.at(-1)).toEqual({ max_parallel_delegations: 5 });

  // Out-of-range input shows validation error without sending a PUT.
  const putCountBefore = mock.runnerPuts.length;
  await subInput.fill("17");
  await subInput.press("Enter");
  await expect(runners.getByRole("alert")).toContainText("Enter a whole number between 1 and 16.");
  expect(mock.runnerPuts.length).toBe(putCountBefore);
  await subInput.press("Escape");
  await expect(subInput).toHaveValue("4");
  await expect(runners.getByRole("alert")).toHaveCount(0);

  // Reload preserves updated values from the server.
  await page.reload();
  await expect(runners.getByLabel("Max concurrent subagents", { exact: true })).toHaveValue("4");
  await expect(runners.getByLabel("Max parallel delegations", { exact: true })).toHaveValue("5");
});

test("sections show empty and error states independently", async ({ page }) => {
  await installSettingsApi(page, { runners: false, secretsFail: true });
  await page.goto("/settings#secrets");
  await expect(page.getByRole("alert").filter({ hasText: "Couldn’t load provider credentials" })).toBeVisible();
  await expect(page.locator("#secrets").getByRole("button", { name: "Retry" })).toBeVisible();
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Runners/ }).click();
  await expect(page.locator("#runners")).toContainText("No runner online");
  await expect(page.locator("#runners")).toContainText("RUNNER_BACKEND = not reported");
  // Settings has no Projects section: a space's work is managed on its page (LAZYAGENTS-213).
  await expect(page.locator("#projects")).toHaveCount(0);
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Workspace/ }).click();
  await expect(page.locator("#workspace")).toContainText("Acme");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "test-results/settings-mobile.png", fullPage: true });
});

test("unset providers can be signed in from Settings; the login itself never reaches the page", async ({ page }) => {
  const mock = await installSettingsApi(page, { signIn: true, noClaude: true });
  await page.goto("/settings#secrets");
  const conn = page.locator("#secrets li");
  // Only unset keys a sign-in can fill: not the SSH key, and not one already set.
  await expect(page.getByRole("button", { name: "Sign in to OpenAI" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Sign in to GitHub token" })).toBeVisible();
  await expect(conn.filter({ hasText: "git:ssh" }).getByRole("button", { name: /Sign in/ })).toHaveCount(0);

  // Codex: open the page and enter the code there; Vesper stores the login.
  await page.getByRole("button", { name: "Sign in to OpenAI" }).click();
  const codex = page.getByLabel("OpenAI sign-in");
  await expect(codex).toContainText("Starting a sign-in container");
  await expect(codex.getByRole("link", { name: "Open the OpenAI sign-in page" })).toHaveAttribute("href", "https://auth.openai.com/codex/device");
  await expect(codex.getByLabel("One-time code")).toHaveText("AB12-CD34");
  await page.screenshot({ path: "test-results/settings-sign-in.png", fullPage: true });
  await expect(page.getByRole("status").filter({ hasText: "harness:openai saved" })).toBeVisible();
  await expect(conn.filter({ hasText: "harness:openai" })).toContainText("Set");
  await expect(page.getByRole("button", { name: "Sign in to OpenAI" })).toHaveCount(0);

  // Claude: the page shows a code to paste back.
  await page.getByRole("button", { name: "Sign in to Anthropic" }).click();
  const claude = page.getByLabel("Anthropic sign-in");
  await expect(claude.getByRole("link", { name: "Open the Anthropic sign-in page" })).toHaveAttribute("href", /^https:\/\/claude\.com\//);
  await claude.getByLabel("Code from the Claude page").fill("abc#def");
  await claude.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByRole("status").filter({ hasText: "harness:anthropic saved" })).toBeVisible();
  expect(mock.signIns["si-claude"].pasted).toBe("abc#def");

  // Cancelling stops the sign-in and brings the buttons back.
  await page.getByRole("button", { name: "Sign in to GitHub token" }).click();
  await page.getByLabel("GitHub token sign-in").getByRole("button", { name: "Cancel" }).click();
  await expect(page.getByRole("button", { name: "Sign in to GitHub token" })).toBeVisible();
  await expect.poll(() => mock.signIns["si-github"].status).toBe("cancelled");
});

test("sign-in is hidden without a Docker runner", async ({ page }) => {
  await installSettingsApi(page, { signIn: false, noClaude: true });
  await page.goto("/settings#secrets");
  await expect(page.getByRole("button", { name: "Add OpenAI key" })).toBeVisible();
  await expect(page.getByRole("button", { name: /^Sign in to/ })).toHaveCount(0);
});

test("repository discovery saves repositories and organizations shared by all personas", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/settings#repositories");
  const section = page.locator("#repositories");
  await section.getByText("Enter a repository or owner manually", { exact: true }).click();
  await expect(section).toContainText("Access comes from your GitHub credential");
  await section.getByLabel("GitHub repository", { exact: true }).fill("acme/app");
  await section.getByRole("button", { name: "Save source" }).click();
  await expect(section.getByRole("button", { name: "Remove acme/app", exact: true })).toBeVisible();
  await section.getByLabel("Repository source type").selectOption("organization");
  await section.getByLabel("GitHub username or organization", { exact: true }).fill("acme");
  await section.getByRole("button", { name: "Save source" }).click();
  await expect(section.getByRole("button", { name: "Remove acme", exact: true })).toBeVisible();
  await section.getByRole("button", { name: "Refresh owner repositories" }).click();
  await expect(section.getByRole("button", { name: "Refresh owner repositories" })).toBeEnabled();
  await section.getByRole("button", { name: "Remove acme/app", exact: true }).click();
  await expect(section.getByRole("button", { name: "Remove acme/app", exact: true })).toHaveCount(0);
  expect(mock.api.unhandled).toEqual([]);
});


test("repository discovery saves all repositories under a plain username", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/settings#repositories");
  const section = page.locator("#repositories");
  await section.getByText("Enter a repository or owner manually", { exact: true }).click();
  await section.getByLabel("Repository source type").selectOption({ label: "All repos under a username or organization" });
  await section.getByLabel("GitHub username or organization", { exact: true }).fill("liamphmurphy");
  await section.getByRole("button", { name: "Save source" }).click();
  await expect(section.getByRole("list", { name: "Saved repository sources" }).getByText("liamphmurphy", { exact: true })).toBeVisible();
  await expect(section.getByText("All repositories", { exact: true })).toBeVisible();
  await section.getByRole("button", { name: "Refresh owner repositories" }).click();
  await expect(section.getByRole("button", { name: "Refresh owner repositories" })).toBeEnabled();
  await section.getByRole("button", { name: "Remove liamphmurphy", exact: true }).click();
  await expect(section.getByRole("list", { name: "Saved repository sources" }).getByText("liamphmurphy", { exact: true })).toHaveCount(0);
  expect(mock.api.unhandled).toEqual([]);
});


test("repository discovery offers connected account and org presets without automatically adding them", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/settings#repositories");
  const section = page.locator("#repositories");
  const saved = section.getByRole("list", { name: "Saved repository sources" });
  const account = section.getByRole("button", { name: "Add all repositories under liamphmurphy", exact: true });
  const org = section.getByRole("button", { name: "Add all repositories under acme", exact: true });
  await expect(account).toContainText("Your account");
  await expect(org).toContainText("Organization");
  await expect(saved.locator("li")).toHaveCount(0);
  await account.click();
  await expect(account).toBeDisabled();
  await expect(saved.getByText("liamphmurphy", { exact: true })).toBeVisible();
  await org.click();
  await expect(org).toBeDisabled();
  await expect(saved.locator("li")).toHaveCount(2);
  await page.reload();
  await expect(account).toBeDisabled();
  await expect(org).toBeDisabled();
  expect(mock.api.unhandled).toEqual([]);
});

test("partial GitHub discovery keeps the account preset and manual owner entry usable", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.route("**/api/v1/repositories/presets", (route) => route.fulfill({ json: { owners: [{ login: "liamphmurphy", organization: false }], warning: "Some organizations could not be listed with this GitHub connection." } }));
  await page.goto("/settings#repositories");
  const section = page.locator("#repositories");
  await expect(section.getByRole("status")).toContainText("Some organizations could not be listed");
  await section.getByRole("button", { name: "Add all repositories under liamphmurphy" }).click();
  await expect(section.getByRole("button", { name: "Remove liamphmurphy", exact: true })).toBeVisible();
  await section.getByText("Enter a repository or owner manually", { exact: true }).click();
  await section.getByLabel("Repository source type").selectOption("organization");
  await section.getByLabel("GitHub username or organization").fill("other-team");
  await section.getByRole("button", { name: "Save source" }).click();
  await expect(section.getByRole("button", { name: "Remove other-team", exact: true })).toBeVisible();
  expect(mock.api.unhandled).toEqual([]);
});

test("manual repository entry works when no GitHub presets can be loaded", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.route("**/api/v1/repositories/presets", (route) => route.fulfill({ status: 409, json: { code: "conflict", message: "Add a GitHub token in Settings." } }));
  await page.goto("/settings#repositories");
  const section = page.locator("#repositories");
  await expect(section.getByRole("status")).toContainText("Add a GitHub token");
  await section.getByText("Enter a repository or owner manually", { exact: true }).click();
  await section.getByLabel("GitHub repository", { exact: true }).fill("acme/manual");
  await section.getByRole("button", { name: "Save source" }).click();
  await expect(section.getByRole("button", { name: "Remove acme/manual", exact: true })).toBeVisible();
  expect(mock.api.unhandled).toEqual([]);
});


test("GitHub presets refresh after credentials change", async ({ page }) => {
  const mock = await installSettingsApi(page);
  let lookups = 0;
  await page.route("**/api/v1/repositories/presets", (route) => {
    lookups++;
    return route.fulfill({ json: { owners: [{ login: lookups === 1 ? "previous-account" : "new-account", organization: false }] } });
  });
  await page.goto("/settings#repositories");
  await expect(page.locator("#repositories").getByRole("button", { name: "Add all repositories under previous-account" })).toBeVisible();
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /Secrets & Credentials/ }).click();
  await page.getByRole("button", { name: "Add credential", exact: true }).click();
  const secrets = page.locator("#secrets");
  await secrets.getByLabel("Name", { exact: true }).fill("git:pat");
  await secrets.getByLabel("Value", { exact: true }).fill("fixture-github-token");
  await secrets.getByRole("button", { name: "Save credential", exact: true }).click();
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Repositories/ }).click();
  const section = page.locator("#repositories");
  await expect(section.getByRole("button", { name: "Add all repositories under new-account" })).toBeVisible();
  await expect(section.getByRole("button", { name: "Add all repositories under previous-account" })).toHaveCount(0);
  expect(mock.api.unhandled).toEqual([]);
});

// Images can be made by Codex or Antigravity: Auto, or one of them, saved for the workspace.
test("image engine: auto by default, shows what is connected, and saves the choice", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.goto("/settings#images");
  const section = page.locator("#images");
  const group = section.getByRole("radiogroup", { name: "Image engine" });
  await expect(group.getByRole("radio", { name: /^Auto/ })).toHaveAttribute("aria-checked", "true");
  await expect(group.getByRole("radio", { name: /^Auto/ })).toContainText("Use the first connected: Codex.");
  await expect(group.getByRole("radio", { name: /^Codex/ })).toContainText("Connected");
  await expect(group.getByRole("radio", { name: /^Antigravity/ })).toContainText("Not connected: no harness:google secret");
  await group.getByRole("radio", { name: /^Antigravity/ }).click();
  await expect(group.getByRole("radio", { name: /^Antigravity/ })).toHaveAttribute("aria-checked", "true");
  await page.reload();
  await expect(page.locator("#images").getByRole("radio", { name: /^Antigravity/ })).toHaveAttribute("aria-checked", "true");
  expect(mock.api.unhandled).toEqual([]);
});

test("dev workspace configured repositories are collapsed by default, filterable, and clearable", async ({ page }) => {
  const mock = await installSettingsApi(page);
  await page.route("**/api/v1/github/review-requests*", (route) =>
    route.fulfill({ json: { items: [], configured: false } }),
  );
  let customGitconfig: string | null = null;
  let repos = Array.from({ length: 560 }, (_, i) => {
    const name = `repo-${String(i).padStart(3, "0")}`;
    return { repo_url: `https://github.com/org/${name}`, directory: name };
  });
  await page.route("**/api/v1/dev-workspace", async (route) => {
    const req = route.request();
    if (req.method() === "PATCH") {
      const body = req.postDataJSON() as { repos?: string[]; custom_gitconfig?: string | null };
      if (Array.isArray(body.repos)) {
        repos = body.repos.map((url) => ({ repo_url: url, directory: url.split("/").pop() || "repo" }));
      }
      if ("custom_gitconfig" in body) {
        customGitconfig = body.custom_gitconfig ?? null;
      }
    }
    return route.fulfill({
      json: {
        enabled: true,
        nix_mode: "default",
        repos,
        extra_packages: [],
        custom_gitconfig: customGitconfig,
        tmux_prefix: "C-b",
        state: "ready",
        action: null,
        step: null,
        error: null,
        port: 8090,
        arch: "x86_64-linux",
        updated_at: at,
      },
    });
  });

  await page.goto("/settings#dev-workspace");
  const section = page.locator("#dev-workspace");
  const gitconfigBox = section.getByLabel("Custom .gitconfig");
  await gitconfigBox.fill("[pull]\n\trebase = true\n");
  await section.getByRole("button", { name: "Save .gitconfig" }).click();
  await expect(gitconfigBox).toHaveValue("[pull]\n\trebase = true\n");

  const toggle = section.getByRole("button", { name: "560 repositories configured" });
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(section.getByText("https://github.com/org/repo-000")).toHaveCount(0);

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(section.getByText("https://github.com/org/repo-000")).toBeVisible();

  await section.getByLabel("Filter configured repositories").fill("repo-420");
  await expect(section.getByText("https://github.com/org/repo-420")).toBeVisible();
  await expect(section.getByText("https://github.com/org/repo-000")).toHaveCount(0);

  await section.getByRole("button", { name: "Clear all" }).click();
  await section.getByRole("button", { name: "Remove all 560" }).click();
  await expect(section.getByRole("button", { name: /repositories configured/ })).toHaveCount(0);
  expect(mock.api.unhandled).toEqual([]);
});
