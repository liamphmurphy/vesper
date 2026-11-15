import { expect, test, type Page } from "@playwright/test";
import { installAgentApi } from "./mock-agent-api";

const tab = (page: Page, name: string) => page.getByRole("navigation", { name: "Work sections" }).getByRole("link", { name });

const SCOPES = { "repo:read": "allowed", "tests:run": "denied", "db:migrate": "requires_approval" };

test("one Personas list: who chats and who works, and a persona's work from its profile", async ({ page }) => {
  const mock = await installAgentApi(page, { spec: { scopes: SCOPES } });
  // The old Agents URL lands on the Personas list, showing those that take tickets.
  await page.goto("/agents");
  await expect(page).toHaveURL(/\/customization\?who=agents$/);
  await expect(page.getByTestId("all-personas")).toHaveAttribute("aria-pressed", "true");
  const rows = page.getByTestId("persona-list-row");
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText("Atlas");
  await expect(rows.first()).toContainText("Takes tickets");
  await expect(rows.first()).toContainText("opus-5.5");
  // Atlas is working on a ticket right now.
  await expect(rows.first().getByRole("link", { name: /WEB-7/ })).toBeVisible();

  await page.getByRole("radiogroup", { name: "Show personas" }).getByRole("radio", { name: /^All/ }).click();
  await expect(rows).toHaveCount(3);
  const scout = rows.filter({ hasText: "Scout" });
  await expect(scout).toContainText("Helps on runs");
  await expect(scout).toContainText("not in chat list");
  await expect(rows.filter({ hasText: "Hackerman" })).toContainText("Chat · Codes");

  // A persona's Work section switches what it does; its work settings are a link away.
  await rows.filter({ hasText: "Atlas" }).getByRole("button").first().click();
  const work = page.getByTestId("persona-work");
  await expect(work.getByRole("radio", { name: "Takes tickets" })).toHaveAttribute("aria-checked", "true");
  await expect(work.getByRole("link", { name: "Work settings" })).toHaveAttribute("href", "/agents/atlas?tab=settings");

  await page.getByTestId("all-personas").click();
  await page.getByRole("radiogroup", { name: "Show personas" }).getByRole("radio", { name: /^All/ }).click();
  await rows.filter({ hasText: "Hackerman" }).getByRole("button").first().click();
  await work.getByRole("radio", { name: "Takes tickets" }).click();
  await expect.poll(() => mock.saved.personas.map((p) => p.body.work)).toEqual(["tickets"]);
  await expect(work.getByText("@hackerman")).toBeVisible();
  await work.getByRole("switch", { name: "Show in chat list" }).click();
  await expect.poll(() => mock.saved.personas.at(-1)?.body.in_chat_list).toBe(false);
  expect(mock.unhandled).toEqual([]);
});

test("scopes matrix: every catalog scope, project overrides marked, edits need review", async ({ page }) => {
  const mock = await installAgentApi(page, { spec: { scopes: SCOPES }, override: { scopes: { "db:migrate": "denied", "prod:*": "denied" } } });
  await page.goto("/agents/atlas?tab=scopes");
  const table = page.getByRole("table");
  const row = (scope: string) => table.getByRole("row").filter({ has: page.getByText(scope, { exact: true }) });

  for (const [scope, note] of [
    ["repo:read", "Clone and read the project repo"],
    ["tests:run", "Run the test suite"],
    ["db:migrate", "Apply migrations to staging"],
    ["wiki:write", "Edit wiki pages outside the agent's own memory"],
  ]) {
    await expect(row(scope).getByText(note)).toBeVisible();
  }
  await expect(page.getByRole("button", { name: /Effective in: Web app/ })).toBeVisible();
  // The override tightens db:migrate and names a wildcard the agent never had.
  await expect(row("db:migrate").getByText("space", { exact: true })).toBeVisible();
  await expect(row("db:migrate").getByText("Web app tightens Approval")).toBeVisible();
  await expect(row("db:migrate").getByRole("radio", { name: "Approval" })).toHaveAttribute("aria-checked", "true");
  await expect(row("prod:*").getByText("not in the definition")).toBeVisible();
  await expect(row("wiki:write").getByText("not granted")).toBeVisible();

  // Edit: tests:run Denied → Approval, grant wiki:write.
  await row("tests:run").getByRole("radio", { name: "Approval" }).click();
  await expect(row("tests:run").getByText("was Denied")).toBeVisible();
  await expect(row("tests:run").getByText("after save")).toBeVisible();
  await row("wiki:write").getByRole("radio", { name: "Allowed" }).click();
  await expect(page.getByText("2 unsaved changes")).toBeVisible();
  expect(mock.saved.definition).toHaveLength(0);

  await page.keyboard.press("ControlOrMeta+s");
  const dialog = page.getByRole("dialog", { name: "Review changes to Atlas" });
  await expect(dialog.getByText("Saving creates definition v2")).toBeVisible();
  await expect(dialog.getByText("1 change requires approval at run time · 1 change widens access")).toBeVisible();
  await expect(dialog.getByText("tests:run will pause the run until a person approves each use in the Inbox.")).toBeVisible();
  await expect(dialog.getByRole("listitem").filter({ hasText: "tests:run" }).getByText("Denied → Approval")).toBeVisible();
  await expect(dialog.getByRole("listitem").filter({ hasText: "wiki:write" }).getByText("Widens access")).toBeVisible();
  await expect(dialog.getByLabel("Version note")).toHaveValue("tests:run → Requires approval; Added wiki:write");
  await dialog.getByRole("button", { name: "Save as v2" }).click();
  await expect(dialog).toBeHidden();
  const spec = (mock.saved.definition.at(-1) as { spec: { scopes: Record<string, string> }; note: string }).spec;
  expect(spec.scopes).toEqual({ ...SCOPES, "tests:run": "requires_approval", "wiki:write": "allowed" });
  await expect(page.getByRole("button", { name: /Review changes/ })).toBeDisabled();
});

test("overview: edit instructions, preview the diff, go back, save explicitly", async ({ page }) => {
  const mock = await installAgentApi(page, { spec: { instructions: "# Atlas\n\n- Keep changes small.\n- Never force-push.\n" } });
  await page.goto("/agents/atlas");
  await expect(tab(page, "Overview")).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("heading", { name: "Atlas", level: 1 }).first()).toBeVisible();
  await expect(page.getByText("Never force-push.")).toBeVisible();

  await page.getByRole("radio", { name: "Edit" }).click();
  await page.getByLabel("Instructions", { exact: true }).fill("# Atlas\n\n- Keep changes small.\n- Run make test first.\n- Never force-push.\n");
  await expect(page.getByText("edited", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Preview diff" }).click();
  const dialog = page.getByRole("dialog");
  const diff = dialog.getByRole("table", { name: "Instructions diff" });
  await expect(diff.getByRole("row").filter({ hasText: "Run make test first." })).toContainText("+");
  await expect(dialog.getByText("+1")).toBeVisible();
  await dialog.getByRole("button", { name: "Back to editing" }).last().click();
  await expect(dialog).toBeHidden();
  expect(mock.saved.definition).toHaveLength(0);

  await page.getByRole("button", { name: /Review changes/ }).click();
  await page.keyboard.press("ControlOrMeta+Enter");
  await expect(page.getByRole("dialog")).toBeHidden();
  expect((mock.saved.definition.at(-1) as { spec: { instructions: string } }).spec.instructions).toContain("Run make test first.");
});

test("skills tab marks project additions and removals", async ({ page }) => {
  const skill = (name: string) => ({ name, description: `Use for ${name}`, body: "" });
  await installAgentApi(page, {
    spec: { skills: [skill("git-workflow"), skill("release-notes")] },
    override: { model: "sonnet-5.5" },
    skillsAdd: [skill("lazyagents-wiki")],
    skillsRemove: ["release-notes"],
  });
  await page.goto("/agents/atlas?tab=skills");
  await expect(page.getByText("2 from the definition · 1 added · 1 removed")).toBeVisible();
  await expect(page.getByText("removed in Web app")).toBeVisible();
  await expect(page.getByText("added by Web app")).toBeVisible();
  await expect(page.getByRole("button", { name: "Remove skill git-workflow" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Remove skill lazyagents-wiki" })).toHaveCount(0);
});

test("memory lists the agent's namespace; activity lists runs with status and cost", async ({ page }) => {
  await installAgentApi(page);
  await page.goto("/agents/atlas?tab=memory");
  const pages = page.getByRole("list", { name: "Memory pages" });
  await expect(pages.getByRole("listitem")).toHaveCount(3);
  await expect(pages.getByRole("listitem").first()).toContainText("agents/atlas/Memory");
  await expect(pages.getByText("1 suggestion")).toBeVisible();
  await expect(page.getByText("agents/scout/Memory")).toHaveCount(0);
  await expect(page.getByText("Each run starts with selective previews, up to 1,500 tokens.")).toBeVisible();

  await tab(page, "Activity").click();
  const rows = page.getByRole("table").getByRole("row");
  await expect(rows.filter({ hasText: "WEB-5" })).toContainText("Completed");
  await expect(rows.filter({ hasText: "WEB-5" })).toContainText("$0.31");
  await expect(rows.filter({ hasText: "WEB-4" })).toContainText("Failed");
  await expect(rows.filter({ hasText: "WEB-3" })).toContainText("—");
});

test("old definition and runs links open Settings and Activity", async ({ page }) => {
  await installAgentApi(page);
  await page.goto("/agents/atlas?tab=definition");
  await expect(tab(page, "Settings")).toHaveAttribute("aria-current", "page");
  await expect(page.getByLabel("Harness", { exact: true })).toHaveValue("Claude Code");
  await expect(page.getByRole("link", { name: "Change model on persona page" })).toHaveAttribute(
    "href",
    "/customization?who=00000000-0000-4000-8000-000000000001",
  );
  await page.goto("/agents/atlas?tab=runs");
  await expect(tab(page, "Activity")).toHaveAttribute("aria-current", "page");
});

test("project overrides save skill additions and removals without replacing defaults", async ({ page }) => {
  const mock = await installAgentApi(page, { override: { model: "sonnet-5.5" } });
  await page.goto("/agents/atlas?tab=skills");
  await page.locator("#overrides").getByRole("button").filter({ hasText: "Web app" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Remove agent skills").fill("release-notes");
  await dialog.getByLabel("Added skill name").fill("project-release");
  await dialog.getByLabel("When to use this skill").fill("When releasing this project");
  await dialog.getByLabel("Skill instructions").fill("Read the project release guide.");
  await expect(dialog.getByRole("button", { name: "Save override" })).toBeDisabled();
  await dialog.getByRole("button", { name: "Add space skill" }).click();
  await dialog.getByRole("button", { name: "Save override" }).click();
  await expect(dialog).toHaveCount(0);
  expect(mock.saved.overrides[0].body).toMatchObject({
    model: "sonnet-5.5",
    skills_remove: ["release-notes"],
    skills_add: [{ name: "project-release", description: "When releasing this project", body: "Read the project release guide." }],
  });
});
