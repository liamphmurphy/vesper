import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

const presets = ["Dusk", "Catppuccin", "Nord", "Dracula", "Gruvbox", "Solarized", "Rosé Pine", "Tokyo Night", "Everforest", "Ayu", "Flexoki", "GitHub", "One", "Kanagawa", "Monokai Pro", "High Contrast"];
const rootColor = (page: Page, key: string) => page.evaluate((k) => document.documentElement.style.getPropertyValue(`--${k}`), key);
async function settings(page: Page) {
  await installChatApi(page);
  await page.goto("/settings#appearance");
  await expect(page.getByRole("radio", { name: "Neutral", exact: true })).toBeVisible();
}

test("the accent color follows presets, mode and custom colors without reloading", async ({ page }) => {
  await settings(page);
  // The controls are visible in server HTML before their handlers hydrate.
  await expect(async () => {
    await page.getByRole("radio", { name: "Dark", exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark", { timeout: 250 });
  }).toPass();
  await expect.poll(() => rootColor(page, "accent")).toBe("#9b8cff");
  const accent = page.locator('input[name="color-palette"]:checked');
  await expect(accent).toHaveCSS("accent-color", "rgb(155, 140, 255)");
  await page.getByRole("radio", { name: "Nord", exact: true }).check();
  await expect.poll(() => rootColor(page, "accent")).toBe("#88c0d0");
  await expect(accent).toHaveCSS("accent-color", "rgb(136, 192, 208)");
  await page.getByRole("radio", { name: "Light", exact: true }).click();
  await expect.poll(() => rootColor(page, "accent")).toBe("#5e81ac");
  await expect(accent).toHaveCSS("accent-color", "rgb(94, 129, 172)");

  await page.getByRole("button", { name: "Customize this palette" }).click();
  await page.getByRole("radio", { name: "Light colors", exact: true }).click();
  await page.getByRole("button", { name: "Accent", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#cc4400");
  await expect(accent).toHaveCSS("accent-color", "rgb(204, 68, 0)");
  await page.reload();
  await expect(page.getByRole("radio", { name: "Custom", exact: true })).toBeChecked();
  await expect(accent).toHaveCSS("accent-color", "rgb(204, 68, 0)");
  await page.getByRole("button", { name: "Reset palette", exact: true }).click();
  await page.getByRole("radio", { name: "Dark", exact: true }).click();
  await expect(accent).toHaveCSS("accent-color", "rgb(155, 140, 255)");
});

test("named palettes work independently of mode, persist, and remain usable on mobile", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await settings(page);
  for (const name of presets) {
    await page.getByRole("radio", { name, exact: true }).check();
    await page.getByRole("radio", { name: "Dark", exact: true }).click();
    const dark = await rootColor(page, "bg");
    await page.getByRole("radio", { name: "Light", exact: true }).click();
    await expect.poll(() => rootColor(page, "bg")).not.toBe(dark);
    await expect(page.getByRole("radio", { name, exact: true })).toBeChecked();
  }
  await page.reload();
  await expect(page.getByRole("radio", { name: "High Contrast", exact: true })).toBeChecked();
  await expect(page.getByRole("radio", { name: "Light", exact: true })).toHaveAttribute("aria-checked", "true");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("radio", { name: "Custom", exact: true }).check();
  await expect(page.getByRole("slider", { name: /Color wheel/ })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: "test-results/appearance-mobile.png", fullPage: true });
  expect(errors).toEqual([]);
});

test("custom radial controls, overrides, contrast, reset, import and export", async ({ page }) => {
  await settings(page);
  await page.getByRole("radio", { name: "Dark", exact: true }).click();
  await page.getByRole("radio", { name: "Nord", exact: true }).check();
  await page.getByRole("button", { name: "Customize this palette" }).click();
  await page.getByRole("button", { name: "Accent", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#ffcc88");
  await expect.poll(() => rootColor(page, "accent")).toBe("#ffcc88");
  const wheel = page.getByRole("slider", { name: /Color wheel/ });
  await wheel.focus(); await page.keyboard.press("ArrowRight");
  await expect.poll(() => rootColor(page, "accent")).not.toBe("#ffcc88");
  const edited = await rootColor(page, "accent");
  await page.getByRole("radio", { name: "Light colors", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#663399");
  await expect.poll(() => rootColor(page, "accent")).toBe(edited);
  await page.getByRole("radio", { name: "Light", exact: true }).click();
  await expect.poll(() => rootColor(page, "accent")).toBe("#663399");
  await page.getByRole("button", { name: "Text", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#eceff4");
  await expect(page.getByRole("status", { name: "Palette contrast" })).toContainText("fall below");
  await page.getByRole("button", { name: "Reset this color" }).click();
  await expect.poll(() => rootColor(page, "text")).not.toBe("#eceff4");
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export palette" }).click();
  expect((await download).suggestedFilename()).toBe("vesper-palette.json");
  const payload = { version: 1, palette: "custom", custom: { base: "nord", light: { accent: "#445588", "viz-1": "#994411" }, dark: {} } };
  await page.getByLabel("Palette JSON file").setInputFiles({ name: "palette.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(payload)) });
  await expect.poll(() => rootColor(page, "accent")).toBe("#445588");
  await expect.poll(() => rootColor(page, "viz-1")).toBe("#994411");
  await page.reload();
  await expect.poll(() => rootColor(page, "accent")).toBe("#445588");
  await page.screenshot({ path: "test-results/appearance-custom.png", fullPage: true });
  await page.getByRole("button", { name: "Reset palette", exact: true }).click();
  await expect(page.getByRole("radio", { name: "Neutral", exact: true })).toBeChecked();
  await expect.poll(() => rootColor(page, "accent")).toBe("#5b4bd6");
});

test("system mode follows OS changes and storage synchronizes across tabs", async ({ page, context }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await settings(page);
  await page.getByRole("radio", { name: "Nord", exact: true }).check();
  await page.getByRole("radio", { name: "System", exact: true }).click();
  await expect.poll(() => rootColor(page, "bg")).toBe("#2e3440");
  await page.emulateMedia({ colorScheme: "light" });
  await expect.poll(() => rootColor(page, "bg")).toBe("#eceff4");
  const other = await context.newPage();
  await settings(other);
  await expect(other.getByRole("radio", { name: "Nord", exact: true })).toBeChecked();
  await other.getByRole("radio", { name: "Catppuccin", exact: true }).check();
  await expect(page.getByRole("radio", { name: "Catppuccin", exact: true })).toBeChecked();
  await expect.poll(() => rootColor(page, "bg")).toBe("#eff1f5");
});

test("saved custom colors apply before hydration, including derived colors", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem("la-appearance", JSON.stringify({ version: 1, palette: "custom", custom: { base: "nord", dark: { accent: "#112233", surface: "#223344" }, light: {} } }));
  });
  await page.route("**/_next/static/**/*.js", (route) => route.abort());
  await installChatApi(page);
  await page.goto("/settings", { waitUntil: "domcontentloaded" });
  await expect(page.locator("html")).toHaveAttribute("data-palette", "custom");
  expect(await rootColor(page, "accent")).toBe("#112233");
  expect(await rootColor(page, "accent-soft")).toBe("#11223326");
  expect(await rootColor(page, "viz-surface")).toBe("#223344");
});

test("blocked storage still lets the current visit change mode and palette", async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error("Storage blocked"); };
    Storage.prototype.setItem = () => { throw new Error("Storage blocked"); };
  });
  await settings(page);
  await page.getByRole("radio", { name: "Dark", exact: true }).click();
  await page.getByRole("radio", { name: "Nord", exact: true }).check();
  await expect.poll(() => rootColor(page, "bg")).toBe("#2e3440");
  await expect(page.getByText("Browser storage is unavailable.", { exact: false })).toBeVisible();
  await expect(page.getByRole("radio", { name: "Nord", exact: true })).toBeChecked();
});

test("open SVGs and charts update across tabs and downloads preserve custom colors", async ({ page, context }) => {
  await settings(page);
  await page.getByRole("radio", { name: "Dark", exact: true }).click();
  const chat = await context.newPage();
  await installChatApi(chat, { replyDelayMs: 10 });
  await chat.goto("/chat?project=WEB");
  const composer = chat.getByRole("combobox", { name: "Message" });
  await composer.fill("viz: all"); await composer.press("Enter");
  const img = chat.getByRole("img", { name: "Client and server", exact: true });
  await expect(img).toBeVisible();
  await page.getByRole("button", { name: "Customize this palette" }).click();
  await page.getByRole("button", { name: "Diagram panel", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#123456");
  const decoded = async () => decodeURIComponent((await img.getAttribute("src")) ?? "");
  await expect.poll(decoded).toContain('fill="#123456"');
  await expect(chat.getByTestId("svg-fence").first().getByRole("link", { name: "Download SVG" })).toHaveAttribute("href", /%23123456/);
  await page.getByRole("button", { name: "Diagram 1", exact: true }).click();
  await page.getByRole("textbox", { name: "Hex color", exact: true }).fill("#cc8844");
  await expect(chat.getByTestId("chart").locator('path[fill="#cc8844"]').first()).toBeVisible();
  await expect.poll(decoded).toContain("#cc8844");
});

test("Mermaid and syntax colors refresh when another tab changes palette", async ({ page, context }) => {
  await settings(page);
  await page.getByRole("radio", { name: "Dark", exact: true }).click();
  const chat = await context.newPage();
  await installChatApi(chat, { replyDelayMs: 10 });
  await chat.goto("/chat?project=WEB");
  const composer = chat.getByRole("combobox", { name: "Message" });
  await composer.fill("rich: visuals"); await composer.press("Enter");
  const mermaid = chat.getByTestId("mermaid").locator("img");
  await expect(mermaid).toBeVisible();
  const before = await mermaid.getAttribute("src");
  await page.getByRole("radio", { name: "Nord", exact: true }).check();
  await expect(mermaid).not.toHaveAttribute("src", before!);
  await expect.poll(async () => decodeURIComponent((await mermaid.getAttribute("src")) ?? "").toLowerCase()).toContain("#eceff4");
  await composer.fill("code: colors"); await composer.press("Enter");
  const token = chat.locator(".shiki-tok").filter({ hasText: /^function$/ }).last();
  await expect(token).toBeVisible();
  const previousColor = await token.evaluate((el) => getComputedStyle(el).color);
  await page.getByRole("radio", { name: "Gruvbox", exact: true }).check();
  await expect.poll(() => token.evaluate((el) => getComputedStyle(el).color)).not.toBe(previousColor);
});
