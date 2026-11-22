import { expect, test, type Page } from "@playwright/test";
import { deckWith, installDeck } from "./mock-deck-api";

// Visual regression for the web screens: each in Vesper's default (Dusk light) and a dark
// palette (Gruvbox dark), compared against committed snapshots. A layout drift (a bar's height,
// a stacked header, a row that stops short) fails here even when every role and label is right.
// Update the snapshots on purpose with `npx playwright test e2e/visual.spec.ts --update-snapshots`.

const THEMES = [
  { name: "dusk-light", mode: "light", palette: "dusk" },
  { name: "gruvbox-dark", mode: "dark", palette: "gruvbox" },
] as const;

type Screen = { name: string; open: (page: Page) => Promise<void> };

// The web surfaces the Mac app still hosts; the rest of the shell is native now.
const SCREENS: Screen[] = [
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
