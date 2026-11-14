import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import { installChatApi, openEmptyChat, persona } from "./mock-chat-api";
import { deckWith, installDeck } from "./mock-deck-api";

// Visual regression for the shell: the key screens in Vesper's default (Dusk light) and a dark
// palette (Gruvbox dark), compared against committed snapshots. A layout drift (a bar's height,
// a stacked header, a row that stops short) fails here even when every role and label is right.
// Update the snapshots on purpose with `npx playwright test e2e/visual.spec.ts --update-snapshots`.

const THEMES = [
  { name: "dusk-light", mode: "light", palette: "dusk" },
  { name: "gruvbox-dark", mode: "dark", palette: "gruvbox" },
] as const;

type Screen = { name: string; open: (page: Page) => Promise<void> };

const board = (path: string): Screen["open"] => async (page) => {
  await installBoardApi(page);
  await page.goto(path);
};
const chat = (path: string): Screen["open"] => async (page) => {
  await installChatApi(page);
  await page.goto(path);
};

const SCREENS: Screen[] = [
  { name: "chat-new", open: chat("/chat?new") },
  { name: "chat-empty", open: async (page) => { await installChatApi(page); await openEmptyChat(page); } },
  // Personas of your own: the Chats list's one persona filter chip.
  { name: "chat-personas", open: async (page) => {
    await installChatApi(page, { personas: [persona(1, { name: "Atlas", is_default: true }), persona(2, { name: "Nova" })] });
    await openEmptyChat(page);
  } },
  { name: "runs", open: board("/runs") },
  { name: "tickets-list", open: board("/tickets?project=WEB") },
  { name: "tickets-board", open: board("/tickets?layout=board&project=WEB") },
  { name: "tickets-epics", open: board("/tickets?layout=epics&project=WEB") },
  { name: "ticket", open: board("/tickets/WEB-1") },
  { name: "run", open: async (page) => {
    await installBoardApi(page);
    const agent = { id: "agent-builder", name: "Builder", handle: "builder", color_index: 0 };
    const run = {
      id: "11111111-1111-4111-8111-111111111111", ticket_key: "WEB-1", purpose: "ticket", work_title: "Build ticket modal", project_key: "WEB",
      agent, mode: "managed", state: "running", harness: "claude-code", model: "opus", started_at: "2026-11-14T14:30:00Z",
      tool_calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, plan: [], scopes: [], approval_scopes: [],
    };
    await page.route("**/api/v1/runs?*", (route) => route.fulfill({ json: { runs: [run], has_more: false } }));
    await page.route(`**/api/v1/runs/${run.id}?*`, (route) => route.fulfill({ json: { run, child_runs: [], turns: [], approvals: [], events: [] } }));
    await page.goto(`/runs/${run.id}`);
  } },
  { name: "settings", open: board("/settings") },
  { name: "library", open: board("/library") },
  { name: "knowledge-home", open: chat("/knowledge") },
  { name: "slides-editor", open: async (page) => { await installDeck(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]); } },
];

test.use({ viewport: { width: 1400, height: 900 }, reducedMotion: "reduce" });

for (const theme of THEMES) {
  for (const screen of SCREENS) {
    test(`${screen.name} (${theme.name})`, async ({ page }) => {
      // A fixed clock: greetings, dates and "2h ago" read the same on every run.
      await page.clock.setFixedTime(new Date("2026-11-14T15:00:00Z"));
      await page.addInitScript(([mode, palette]) => {
        localStorage.setItem("la-theme", mode);
        localStorage.setItem("la-appearance", JSON.stringify({ version: 1, palette }));
      }, [theme.mode, theme.palette] as const);
      await screen.open(page);
      await page.waitForLoadState("networkidle");
      await page.evaluate(() => document.fonts.ready);
      await expect(page).toHaveScreenshot(`${screen.name}-${theme.name}.png`, {
        animations: "disabled",
        caret: "hide",
        // Relative times come from mock data stamped with the real clock, so they're masked.
        mask: [page.locator("time")],
        // A little room for anti-aliasing between machines; a missing chip or a moved bar is thousands.
        maxDiffPixels: 100,
      });
    });
  }
}
