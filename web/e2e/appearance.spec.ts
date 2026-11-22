import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// The pre-paint appearance script (lib/appearance-script.ts) that every web page Vesper hosts
// runs before the app loads. The Appearance settings themselves are native now.
const rootColor = (page: Page, key: string) => page.evaluate((k) => document.documentElement.style.getPropertyValue(`--${k}`), key);

test("saved custom colors apply before hydration, including derived colors", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem("la-appearance", JSON.stringify({ version: 1, palette: "custom", custom: { base: "nord", dark: { accent: "#112233", surface: "#223344" }, light: {} } }));
  });
  await page.route("**/_next/static/**/*.js", (route) => route.abort());
  await installChatApi(page);
  await page.goto("/plans", { waitUntil: "domcontentloaded" });
  await expect(page.locator("html")).toHaveAttribute("data-palette", "custom");
  expect(await rootColor(page, "accent")).toBe("#112233");
  expect(await rootColor(page, "accent-soft")).toBe("#11223326");
  expect(await rootColor(page, "viz-surface")).toBe("#223344");
});
