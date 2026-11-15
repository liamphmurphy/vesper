import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// Export PDF: a markdown artifact opens in a print view that draws its visuals
// in the light theme, then opens the print dialog once they're ready.

const A = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const V = "44444444-4444-4444-8444-444444444444";
const agent = { type: "agent", id: "agent-1", name: "Mastermind", color_index: 0 };

const body = [
  "# Storage plan",
  "",
  "## Overview",
  "",
  "Some **intro** text and math: $$E = mc^2$$",
  "",
  "```mermaid",
  "flowchart LR",
  "  A[Ingest] --> B[Store]",
  "```",
  "",
  "## Numbers",
  "",
  "```chart",
  JSON.stringify({ type: "bar", title: "Latency", y: { label: "ms" }, categories: ["p50", "p99"], series: [{ name: "API", values: [12, 80] }] }),
  "```",
  "",
  "```svg-steps",
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100"><title>Flow</title><rect x="10" y="10" width="60" height="40" fill="var(--viz-1-soft)"/><rect data-step="2" x="120" y="10" width="60" height="40" fill="var(--viz-2-soft)"/></svg>',
  "1. Start with the source",
  "2. Add the sink",
  "```",
].join("\n");

async function install(page: Page) {
  await installChatApi(page);
  const version = {
    id: V, seq: 1, label: "v1", note: "", created_by: agent, created_at: "2026-11-01T10:00:00Z",
    content: { kind: "markdown", content_type: "text/markdown", size_bytes: body.length, sections: 3 },
  };
  const artifact = {
    id: A, type: "spec", title: "Storage plan", summary: "How we store things.", suggestions: 0, author: agent, body_md: body,
    current_version: version, versions: [version], outline: [], read_by: [], tickets: [],
    created_at: "2026-11-01T10:00:00Z", updated_at: "2026-11-01T10:00:00Z",
  };
  await page.route(`**/api/v1/artifacts/${A}`, (route) => route.fulfill({ json: artifact }));
  // Count print calls instead of opening the dialog.
  await page.addInitScript(() => {
    const w = window as unknown as { __prints: number; __themeAtPrint?: string | null };
    w.__prints = 0;
    window.print = () => {
      w.__prints++;
      w.__themeAtPrint = document.documentElement.getAttribute("data-theme");
    };
  });
}

test("the artifact page links to the print view", async ({ page }) => {
  await install(page);
  await page.goto(`/artifacts/${A}`);
  const link = page.getByRole("link", { name: "Export PDF" });
  await expect(link).toHaveAttribute("href", `/print/artifacts/${A}`);
  await expect(link).toHaveAttribute("target", "_blank");
  // Visuals render on the artifact page too, not as code.
  await expect(page.getByTestId("chart")).toBeVisible();
});

test("the print view draws visuals in light, then prints once", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await install(page);
  await page.goto(`/print/artifacts/${A}`);
  const doc = page.getByTestId("print-artifact");
  await expect(doc.getByRole("heading", { name: "Storage plan" }).first()).toBeVisible();
  await expect(doc.getByTestId("mermaid").locator("img")).toBeVisible();
  await expect(doc.getByTestId("chart")).toBeVisible();
  await expect(doc.locator(".katex").first()).toBeVisible();
  // A step-through prints its last frame with every caption.
  await expect(doc.getByText("1/2")).toHaveCount(0);
  await expect(doc.getByRole("listitem").filter({ hasText: "Add the sink" })).toBeVisible();

  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  expect(await page.evaluate(() => (window as unknown as { __themeAtPrint?: string }).__themeAtPrint)).toBe("light");
  await expect(page).toHaveTitle("Storage plan");

  // Controls stay off the paper.
  await page.emulateMedia({ media: "print" });
  await expect(page.getByRole("button", { name: "Print / Save as PDF" })).toBeHidden();
  await expect(doc.getByRole("tab", { name: "Data" })).toBeHidden();
});

test("printing uses neutral light colors without overwriting a saved custom palette", async ({ page }) => {
  await install(page);
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem("la-appearance", JSON.stringify({ version: 1, palette: "custom", custom: { base: "nord", dark: { bg: "#112233" }, light: { bg: "#887766", "viz-ink": "#887766" } } }));
  });
  await page.goto(`/print/artifacts/${A}`);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  expect(await page.evaluate(() => document.documentElement.style.getPropertyValue("--bg"))).toBe("#f5f5f7");
  expect(await page.evaluate(() => localStorage.getItem("la-theme"))).toBe("dark");
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem("la-appearance")!).palette)).toBe("custom");
});
