import { expect, test, type Locator, type Page as BrowserPage } from "@playwright/test";
import { jsPDF } from "jspdf";
import { installChatApi } from "./mock-chat-api";
import type { Embed, Page } from "../lib/api/knowledge-hooks";

const ID = "55555555-5555-4555-8555-555555555555";
const PDF_REF = "![[attachment:pdf-1/handbook.pdf]]";

function makeSamplePdf(pageCount: number): Buffer {
  const pdf = new jsPDF({ unit: "pt", format: "letter" });
  for (let i = 1; i <= pageCount; i++) {
    if (i > 1) pdf.addPage("letter", "portrait");
    pdf.setFillColor(24 * i, 70, 220 - 16 * i);
    pdf.rect(64, 96, 260, 120, "F");
    pdf.setTextColor(20, 24, 31);
    pdf.setFontSize(22);
    pdf.text(`Handbook Page ${i}`, 64, 72);
  }
  return Buffer.from(pdf.output("arraybuffer"));
}

async function hasNonWhitePixels(canvas: Locator): Promise<boolean> {
  return canvas.evaluate((el) => {
    const c = el as HTMLCanvasElement;
    const ctx = c.getContext("2d");
    if (!ctx || c.width === 0 || c.height === 0) return false;
    const { data } = ctx.getImageData(0, 0, c.width, c.height);
    for (let i = 0; i < data.length; i += 16) {
      const r = data[i];
      const g = data[i + 1];
      const b = data[i + 2];
      const a = data[i + 3];
      if (a > 0 && (r < 245 || g < 245 || b < 245)) return true;
    }
    return false;
  });
}

async function installKnowledgePdf(page: BrowserPage, pageCount = 8) {
  await installChatApi(page);
  const pdfBytes = makeSamplePdf(pageCount);
  const saved: string[] = [];
  const embed: Embed = {
    ref: PDF_REF,
    kind: "file",
    title: "handbook.pdf",
    available: true,
    content_type: "application/pdf",
    url: "/api/v1/knowledge/assets/pdf-1",
  };
  const note: Page = {
    id: ID,
    title: "Handbook",
    path: "Docs/Handbook",
    audience: "private",
    body_md: `Before.\n\n${PDF_REF}\n\nAfter.`,
    version_id: "v1",
    seq: 1,
    properties: {},
    direct: false,
    paused: false,
    chat_id: null,
    url: `/knowledge/${ID}`,
    embeds: [embed],
    reviews: [],
    versions: [],
  };

  await page.route(/\/api\/v1\/knowledge\//, async (route) => {
    const reqUrl = new URL(route.request().url());
    const path = reqUrl.pathname.replace("/api/v1/knowledge", "");
    if (path === "/assets/pdf-1") {
      return route.fulfill({
        status: 200,
        headers: {
          "Content-Type": "application/pdf",
          "Content-Disposition": 'attachment; filename="handbook.pdf"',
          "Content-Security-Policy": "default-src 'none'; sandbox",
          "X-Content-Type-Options": "nosniff",
        },
        body: pdfBytes,
      });
    }
    let data: unknown = {};
    if (path === "/query") data = { rows: [note], has_more: false };
    if (path === `/pages/${ID}`) {
      if (route.request().method() === "PUT") {
        const input = route.request().postDataJSON();
        saved.push(input.body_md);
        Object.assign(note, input, { seq: note.seq + 1, version_id: `v${note.seq + 1}` });
      }
      data = note;
    }
    if (path === "/backlinks") data = { linked: [], unlinked: [] };
    if (path === "/resolve") data = { links: [] };
    return route.fulfill({ contentType: "application/json", body: JSON.stringify(data) });
  });

  await page.goto(`/knowledge/${ID}`);
  const embedBox = page.getByTestId("knowledge-pdf-embed");
  await expect(embedBox).toBeVisible();
  return { embedBox, saved };
}

test("renders embedded PDF pages instead of a blank screen and opens the viewer modal instead of a blank tab", async ({ page }) => {
  const popups: string[] = [];
  page.on("popup", (p) => popups.push(p.url()));

  const { embedBox } = await installKnowledgePdf(page, 8);
  const canvas = embedBox.locator('canvas[data-rendered-page="1"]');
  await expect(canvas).toBeVisible();
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("1 / 8");
  expect(await hasNonWhitePixels(canvas)).toBe(true);

  const figure = embedBox.locator("xpath=ancestor::figure[1]");
  await expect(figure.getByRole("link", { name: "Download", exact: true })).toHaveAttribute("download", "handbook.pdf");

  await figure.getByRole("button", { name: "Open", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "handbook.pdf" });
  await expect(dialog).toBeVisible();
  const modalCanvas = dialog.locator('canvas[data-rendered-page="1"]');
  await expect(modalCanvas).toBeVisible();
  expect(await hasNonWhitePixels(modalCanvas)).toBe(true);
  expect(popups).toEqual([]);
  await expect(page).toHaveURL(new RegExp(`/knowledge/${ID}$`));
});

test("left thumbnail pane shows about 5 pages without scrolling, scrolls for longer docs, highlights active page, and jumps on click", async ({ page }) => {
  const { embedBox } = await installKnowledgePdf(page, 8);
  await expect(embedBox.locator('canvas[data-rendered-page="1"]')).toBeVisible();

  const pane = embedBox.getByTestId("pdf-thumbnails");
  const thumbs = pane.getByTestId("pdf-thumbnail");
  await expect(thumbs).toHaveCount(8);
  await expect(thumbs.first().locator('canvas[data-thumb-rendered="true"]')).toBeVisible();

  const metrics = await pane.evaluate((el) => {
    const navRect = el.getBoundingClientRect();
    const buttons = [...el.querySelectorAll<HTMLElement>('[data-testid="pdf-thumbnail"]')];
    const visibleWithoutScroll = buttons.filter((b) => {
      const r = b.getBoundingClientRect();
      return r.top >= navRect.top - 2 && r.bottom <= navRect.bottom + 2;
    }).length;
    return {
      scrollHeight: el.scrollHeight,
      clientHeight: el.clientHeight,
      visibleWithoutScroll,
    };
  });
  expect(metrics.scrollHeight).toBeGreaterThan(metrics.clientHeight);
  expect(metrics.visibleWithoutScroll).toBeGreaterThanOrEqual(4);
  expect(metrics.visibleWithoutScroll).toBeLessThanOrEqual(6);

  await expect(thumbs.nth(0)).toHaveAttribute("aria-current", "page");
  await thumbs.nth(5).click();
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("6 / 8");
  await expect(thumbs.nth(5)).toHaveAttribute("aria-current", "page");
  await expect(thumbs.nth(0)).not.toHaveAttribute("aria-current", "page");

  const page6Canvas = embedBox.locator('canvas[data-rendered-page="6"]');
  await expect(page6Canvas).toBeVisible();
  expect(await hasNonWhitePixels(page6Canvas)).toBe(true);
});

test("supports keyboard navigation without mutating editor text and toggles fullscreen", async ({ page }) => {
  const { embedBox, saved } = await installKnowledgePdf(page, 8);
  await expect(embedBox.locator('canvas[data-rendered-page="1"]')).toBeVisible();

  const viewer = embedBox.locator("[data-pdf-viewer]");
  await viewer.focus();
  await page.keyboard.press("ArrowRight");
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("2 / 8");

  await page.keyboard.press("End");
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("8 / 8");

  await page.keyboard.press("Home");
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("1 / 8");

  await page.keyboard.press("ArrowLeft");
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("1 / 8");

  // PageDown scrolls an overflowing page first, then advances on the next press.
  await page.keyboard.press("PageDown");
  if ((await embedBox.getByTestId("pdf-page-indicator").textContent()) === "1 / 8") {
    await page.keyboard.press("PageDown");
  }
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("2 / 8");

  await page.keyboard.press("PageUp");
  await expect(embedBox.getByTestId("pdf-page-indicator")).toHaveText("1 / 8");
  expect(saved).toEqual([]);

  await embedBox.getByTestId("pdf-fullscreen-toggle").click();
  await expect(viewer).toHaveAttribute("data-fullscreen", "true");
  await page.keyboard.press("Escape");
  await expect(viewer).toHaveAttribute("data-fullscreen", "false");
});
