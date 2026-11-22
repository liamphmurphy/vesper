import { expect, test, type Page as BrowserPage, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";
import type { Embed, Page } from "../lib/api/knowledge-hooks";

const ID = "55555555-5555-4555-8555-555555555555";
const IMG_REF = "![[attachment:img-1/diagram.png]]";
const PDF_REF = "![[attachment:pdf-1/handbook.pdf]]";
const PAGE_REF = "![[Docs/Context]]";
const PNG_1X1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
  "base64",
);

const body = [
  "# Release Architecture",
  "",
  "See [[Docs/Context|Context Doc]] and [[Missing/Page]] for details. ^intro-block",
  "",
  IMG_REF,
  "",
  "> [!tip] Fast path",
  "> Always verify migrations before rollout. ^tip-block",
  "",
  PDF_REF,
  "",
  PAGE_REF,
  "",
  "Inline math $$E = mc^2$$ and a diagram:",
  "",
  "```mermaid",
  "flowchart LR",
  "  A[Draft] --> B[Publish]",
  "```",
  "",
  "| Step | Owner |",
  "| --- | --- |",
  "| Review | [[People/Ada|Ada]] |",
].join("\n");

const json = (route: Route, data: unknown, status = 200) =>
  route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });

async function installKnowledgePrintMock(page: BrowserPage) {
  const chat = await installChatApi(page);
  const embeds: Embed[] = [
    {
      ref: IMG_REF,
      kind: "image",
      title: "diagram.png",
      available: true,
      content_type: "image/png",
      url: "/api/v1/knowledge/assets/img-1",
    },
    {
      ref: PDF_REF,
      kind: "file",
      title: "handbook.pdf",
      available: true,
      content_type: "application/pdf",
      url: "/api/v1/knowledge/assets/pdf-1",
    },
    {
      ref: PAGE_REF,
      kind: "page",
      title: "Context",
      markdown: "# Context\n\nShared background note.",
      available: true,
    },
  ];

  const note: Page = {
    id: ID,
    title: "Release Architecture",
    path: "Engineering/Specs/Release Architecture",
    audience: "private",
    body_md: body,
    version_id: "v1",
    seq: 1,
    properties: {
      owner: "[[People/Ada Lovelace]]",
      tags: ["architecture", "release"],
    },
    direct: false,
    paused: false,
    chat_id: null,
    url: `/knowledge/${ID}`,
    embeds,
    reviews: [],
    versions: [],
  };

  await page.route(/\/api\/v1\/knowledge\//, async (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname.replace("/api/v1/knowledge", "");
    if (path === "/assets/img-1") {
      return route.fulfill({ status: 200, headers: { "Content-Type": "image/png" }, body: PNG_1X1 });
    }
    if (path === "/query") {
      return json(route, { columns: [], rows: [note], has_more: false });
    }
    if (path === `/pages/${ID}/chat` && req.method() === "PUT") {
      note.chat_id = (req.postDataJSON() as { chat_id: string }).chat_id;
      return json(route, note);
    }
    if (path === `/pages/${ID}`) {
      if (req.method() === "PUT") Object.assign(note, req.postDataJSON(), { seq: note.seq + 1 });
      return json(route, note);
    }
    if (path === "/backlinks") return json(route, { linked: [], unlinked: [] });
    if (path === "/resolve") return json(route, { links: [] });
    if (path === "/suggest") return json(route, { targets: [] });
    return json(route, {});
  });

  await page.addInitScript(() => {
    const w = window as unknown as { __prints: number; __themeAtPrint?: string | null };
    w.__prints = 0;
    window.print = () => {
      w.__prints++;
      w.__themeAtPrint = document.documentElement.getAttribute("data-theme");
    };
  });

  return { note, chat };
}

test("Knowledge print view strips editor chrome, renders Obsidian syntax cleanly, keeps window dark theme, and defaults metadata off", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await installKnowledgePrintMock(page);
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem(
      "la-appearance",
      JSON.stringify({ version: 1, palette: "custom", custom: { base: "nord", dark: { bg: "#112233" }, light: { bg: "#887766", "viz-ink": "#887766" } } }),
    );
  });

  await page.goto(`/print/knowledge/${ID}?style=clean`);
  const doc = page.getByTestId("print-knowledge");
  const metaCheckbox = page.getByRole("checkbox", { name: "Include metadata" });

  await expect(doc).toHaveAttribute("data-print-style", "clean");
  await expect(doc.getByRole("heading", { name: "Release Architecture" })).toHaveCount(1);
  await expect(metaCheckbox).toBeVisible();
  await expect(metaCheckbox).not.toBeChecked();
  await expect(doc.getByText("Engineering / Specs")).toHaveCount(0);
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toHaveCount(0);
  await expect(doc.getByText("#architecture", { exact: true })).toHaveCount(0);
  await expect(doc.getByText("Context Doc", { exact: true })).toBeVisible();
  await expect(doc.getByText("Page", { exact: true })).toBeVisible();
  await expect(doc.getByRole("button", { name: /Add property|Remove / })).toHaveCount(0);
  await expect(page.getByRole("toolbar")).toHaveCount(0);

  // Obsidian block IDs and raw brackets are stripped cleanly.
  await expect(doc).not.toContainText("^intro-block");
  await expect(doc).not.toContainText("^tip-block");
  await expect(doc).not.toContainText("[!tip]");
  await expect(doc).not.toContainText("[[");

  // Callout, embeds, math, Mermaid, and table render cleanly.
  const callout = doc.locator(".print-callout");
  await expect(callout).toHaveAttribute("data-callout", "tip");
  await expect(callout.getByText("Fast path")).toBeVisible();
  await expect(callout.getByText("Always verify migrations before rollout.")).toBeVisible();

  await expect(doc.locator('.print-embed-image img[src="/api/v1/knowledge/assets/img-1"]')).toBeVisible();
  await expect(doc.locator(".print-embed-ref")).toContainText("PDF");
  await expect(doc.locator(".print-embed-ref")).toContainText("handbook.pdf");
  await expect(doc.locator(".print-embed-page")).toContainText("Shared background note.");
  const mermaidImg = doc.getByTestId("mermaid").locator("img");
  await expect(mermaidImg).toBeVisible();
  const mermaidSvg = decodeURIComponent((await mermaidImg.getAttribute("src")) ?? "").toLowerCase();
  expect(mermaidSvg).toContain("#ffffff");
  expect(mermaidSvg).not.toContain("#3b4252");
  expect(mermaidSvg).not.toContain("#15141f");
  await expect(doc.locator(".katex").first()).toBeVisible();
  await expect(doc.locator("table td", { hasText: "Ada" })).toBeVisible();

  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  // Export window keeps the user's dark theme with light text on a dark preview sheet.
  expect(await page.evaluate(() => (window as unknown as { __themeAtPrint?: string }).__themeAtPrint)).toBe("dark");
  expect(await page.evaluate(() => document.documentElement.getAttribute("data-theme"))).toBe("dark");
  expect(await page.evaluate(() => document.documentElement.style.getPropertyValue("--bg"))).toBe("#112233");
  expect(await doc.locator(".print-kn-title").evaluate((el) => getComputedStyle(el).color)).toBe("rgb(244, 244, 245)");
  const darkSheetBg = await doc.evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(darkSheetBg).not.toBe("rgba(0, 0, 0, 0)");
  expect(darkSheetBg).not.toBe("rgb(255, 255, 255)");
  expect(await page.evaluate(() => localStorage.getItem("la-theme"))).toBe("dark");
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem("la-appearance")!).palette)).toBe("custom");
  await expect(page).toHaveTitle("Release Architecture");

  await page.emulateMedia({ media: "print" });
  await expect(page.getByRole("button", { name: "Print / Save as PDF" })).toBeHidden();
  await expect(page.getByRole("group", { name: "PDF style" })).toBeHidden();
  await expect(metaCheckbox).toBeHidden();
  await expect(doc.getByRole("button", { name: "Show code" })).toBeHidden();
  // Printed PDF always uses black ink on white paper, even from dark mode.
  expect(await doc.locator(".print-kn-title").evaluate((el) => getComputedStyle(el).color)).toBe("rgb(24, 24, 27)");
  expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe("rgb(255, 255, 255)");
});

test("Knowledge print view renders black text on white paper in light mode", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await installKnowledgePrintMock(page);
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "light");
  });

  await page.goto(`/print/knowledge/${ID}?style=clean`);
  const doc = page.getByTestId("print-knowledge");
  await expect(doc.getByRole("heading", { name: "Release Architecture" })).toHaveCount(1);

  expect(await page.evaluate(() => document.documentElement.getAttribute("data-theme"))).toBe("light");
  expect(await doc.locator(".print-kn-title").evaluate((el) => getComputedStyle(el).color)).toBe("rgb(24, 24, 27)");
  expect(await doc.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(255, 255, 255)");
});

test("PDF style switching and Include metadata checkbox update the preview without extra auto-prints", async ({ page }) => {
  await installKnowledgePrintMock(page);
  await page.goto(`/print/knowledge/${ID}?style=clean`);
  const doc = page.getByTestId("print-knowledge");
  const metaCheckbox = page.getByRole("checkbox", { name: "Include metadata" });

  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  await expect(metaCheckbox).not.toBeChecked();
  await expect(doc.getByText("Engineering / Specs")).toHaveCount(0);
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toHaveCount(0);
  await expect(doc.getByText("#architecture", { exact: true })).toHaveCount(0);

  await page.getByRole("button", { name: "Editorial", exact: true }).click();
  await expect(doc).toHaveAttribute("data-print-style", "editorial");
  await expect(page).toHaveURL(new RegExp(`/print/knowledge/${ID}\\?style=editorial$`));
  const editorialFont = await doc.evaluate((el) => getComputedStyle(el).fontFamily);
  expect(editorialFont.toLowerCase()).toContain("georgia");

  await page.getByRole("button", { name: "Compact", exact: true }).click();
  await expect(doc).toHaveAttribute("data-print-style", "compact");
  await expect(page).toHaveURL(new RegExp(`/print/knowledge/${ID}\\?style=compact$`));

  await page.getByRole("button", { name: "Technical", exact: true }).click();
  await expect(doc).toHaveAttribute("data-print-style", "technical");
  await expect(page).toHaveURL(new RegExp(`/print/knowledge/${ID}\\?style=technical$`));

  await metaCheckbox.check();
  await expect(metaCheckbox).toBeChecked();
  await expect(doc.getByText("Engineering / Specs")).toBeVisible();
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toBeVisible();
  await expect(doc.getByText("#architecture", { exact: true })).toBeVisible();

  // Switching styles or toggling metadata never re-triggers auto-print; clicking the print button prints again.
  expect(await page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  await page.getByRole("button", { name: "Print / Save as PDF" }).click();
  expect(await page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(2);

  await metaCheckbox.uncheck();
  await expect(metaCheckbox).not.toBeChecked();
  await expect(doc.getByText("Engineering / Specs")).toHaveCount(0);
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toHaveCount(0);
  await expect(doc.getByText("#architecture", { exact: true })).toHaveCount(0);
});

