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

test("Knowledge print view strips editor chrome, renders Obsidian syntax cleanly, and prints in neutral light", async ({ page }) => {
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

  await expect(doc).toHaveAttribute("data-print-style", "clean");
  await expect(doc.getByRole("heading", { name: "Release Architecture" })).toHaveCount(1);
  await expect(doc.getByText("Engineering / Specs")).toBeVisible();
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toBeVisible();
  await expect(doc.getByText("#architecture", { exact: true })).toBeVisible();
  await expect(doc.getByText("Context Doc", { exact: true })).toBeVisible();
  await expect(doc.getByText("Page", { exact: true })).toBeVisible();
  await expect(doc.locator("button")).toHaveCount(0);
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
  await expect(doc.getByTestId("mermaid").locator("img")).toBeVisible();
  await expect(doc.locator(".katex").first()).toBeVisible();
  await expect(doc.locator("table td", { hasText: "Ada" })).toBeVisible();

  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  expect(await page.evaluate(() => (window as unknown as { __themeAtPrint?: string }).__themeAtPrint)).toBe("light");
  expect(await page.evaluate(() => document.documentElement.style.getPropertyValue("--bg"))).toBe("#f5f5f7");
  expect(await page.evaluate(() => localStorage.getItem("la-theme"))).toBe("dark");
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem("la-appearance")!).palette)).toBe("custom");
  await expect(page).toHaveTitle("Release Architecture");

  await page.emulateMedia({ media: "print" });
  await expect(page.getByRole("button", { name: "Print / Save as PDF" })).toBeHidden();
  await expect(page.getByRole("group", { name: "PDF style" })).toBeHidden();
});

test("PDF style switching and Properties toggle update the preview without extra auto-prints", async ({ page }) => {
  await installKnowledgePrintMock(page);
  await page.goto(`/print/knowledge/${ID}?style=clean`);
  const doc = page.getByTestId("print-knowledge");

  await expect.poll(() => page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);

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

  // Switching styles never re-triggers the initial auto-print; clicking the print button prints again.
  expect(await page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(1);
  await page.getByRole("button", { name: "Print / Save as PDF" }).click();
  expect(await page.evaluate(() => (window as unknown as { __prints: number }).__prints)).toBe(2);

  await page.getByRole("button", { name: "Properties", exact: true }).click();
  await expect(doc.getByText("Engineering / Specs")).toHaveCount(0);
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toHaveCount(0);

  await page.getByRole("button", { name: "Properties", exact: true }).click();
  await expect(doc.getByText("Engineering / Specs")).toBeVisible();
  await expect(doc.getByText("Ada Lovelace", { exact: true })).toBeVisible();
});

test("live Knowledge editor hides formatting toolbar, status bar, and property controls under print media", async ({ page }) => {
  await installKnowledgePrintMock(page);
  await page.goto(`/knowledge/${ID}`);
  await expect(page.getByTestId("doc-editor")).toBeVisible();
  await expect(page.getByRole("toolbar", { name: "Formatting" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Add property" })).toBeVisible();

  await page.emulateMedia({ media: "print" });
  await expect(page.getByRole("toolbar", { name: "Formatting" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Add property" })).toBeHidden();
  await expect(page.getByText(/\d+ words/)).toBeHidden();
});

test("native toolbar Print or save as PDF submenu routes styles and pre-fills Ask a Persona without auto-sending", async ({ page }) => {
  const { chat } = await installKnowledgePrintMock(page);
  await page.addInitScript(() => {
    const sent: unknown[] = [];
    Object.assign(window, {
      __shellMessages: sent,
      __VESPER_NATIVE__: { v: 1, platform: "macos" },
      webkit: { messageHandlers: { vesper: { postMessage: (m: unknown) => sent.push(m) } } },
    });
  });

  await page.goto(`/knowledge/${ID}`);
  await expect(page.getByTestId("doc-editor")).toBeVisible();

  // Wait for the native toolbar message to include kn.more with its Print or save as PDF submenu.
  await expect
    .poll(() =>
      page.evaluate(() => {
        const msgs = (window as unknown as { __shellMessages: Array<{ type: string; items?: Array<{ id: string; menu?: Array<{ id: string; children?: Array<{ id: string; separator?: boolean }> }> }> }> }).__shellMessages;
        const toolbars = msgs.filter((m) => m.type === "toolbar" && m.items?.some((i) => i.id === "kn.more"));
        return toolbars.at(-1)?.items?.map((i) => i.id) ?? [];
      }),
    )
    .toEqual(["kn.audience", "kn.mode", "kn.copy-link", "kn.more"]);

  const printSubmenuIds = await page.evaluate(() => {
    const msgs = (window as unknown as { __shellMessages: Array<{ type: string; items?: Array<{ id: string; menu?: Array<{ id: string; children?: Array<{ id: string; separator?: boolean }> }> }> }> }).__shellMessages;
    const toolbar = msgs.filter((m) => m.type === "toolbar" && m.items?.some((i) => i.id === "kn.more")).at(-1);
    const more = toolbar?.items?.find((i) => i.id === "kn.more");
    const print = more?.menu?.find((m) => m.id === "print");
    return print?.children?.map((c) => (c.separator ? "---" : c.id)) ?? [];
  });
  expect(printSubmenuIds).toEqual(["print:clean", "print:editorial", "print:compact", "print:technical", "---", "print:ask-persona"]);

  // Choosing a style dispatches openInMain for /print/knowledge/<id>?style=editorial in a new tab.
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("vesper-native", { detail: { v: 1, type: "toolbar.action", itemId: "kn.more", menuItemId: "print:editorial" } }));
  });
  await expect
    .poll(() =>
      page.evaluate(() =>
        (window as unknown as { __shellMessages: Array<{ type: string; path?: string; newTab?: boolean }> }).__shellMessages.find((m) => m.type === "openInMain"),
      ),
    )
    .toEqual({ v: 1, type: "openInMain", path: `/print/knowledge/${ID}?style=editorial`, newTab: true });

  // Choosing Ask a Persona opens the chat inspector tab with the render_pdf prompt in its panel spec.
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("vesper-native", { detail: { v: 1, type: "toolbar.action", itemId: "kn.more", menuItemId: "print:ask-persona" } }));
  });
  const panelSpec = await expect
    .poll(async () =>
      page.evaluate(() => {
        const msgs = (window as unknown as {
          __shellMessages: Array<{
            type: string;
            model?: {
              open: boolean;
              activeTabId: string;
              tabs: Array<{ id: string; panel?: { kind: string; key: string; propsJson: string } }>;
            };
          }>;
        }).__shellMessages;
        const latest = msgs.filter((m) => m.type === "inspector" && m.model?.open && m.model?.activeTabId === "chat").at(-1);
        const chatTab = latest?.model?.tabs.find((t) => t.id === "chat");
        if (!chatTab?.panel) return null;
        const parsed = JSON.parse(chatTab.panel.propsJson) as { prompt?: { text: string; key: number } | null; request?: number };
        return parsed.prompt?.text ? chatTab.panel : null;
      }),
    )
    .not.toBeNull()
    .then(() =>
      page.evaluate(() => {
        const msgs = (window as unknown as {
          __shellMessages: Array<{
            type: string;
            model?: { open: boolean; activeTabId: string; tabs: Array<{ id: string; panel?: { kind: string; key: string; propsJson: string } }> };
          }>;
        }).__shellMessages;
        const latest = msgs.filter((m) => m.type === "inspector" && m.model?.open && m.model?.activeTabId === "chat").at(-1);
        return latest!.model!.tabs.find((t) => t.id === "chat")!.panel!;
      }),
    );

  const parsedProps = JSON.parse(panelSpec.propsJson) as { prompt: { text: string; key: number }; request: number };
  expect(parsedProps.prompt.text).toContain("[[Engineering/Specs/Release Architecture]]");
  expect(parsedProps.prompt.text).toContain("render_pdf");

  // Mount /inspector-panel with that panel spec and verify the composer is pre-filled without sending.
  await page.goto("/inspector-panel");
  await expect
    .poll(() =>
      page.evaluate(() =>
        (window as unknown as { __shellMessages: Array<{ type: string }> }).__shellMessages.some((m) => m.type === "ready"),
      ),
    )
    .toBe(true);

  await page.evaluate((spec) => {
    window.dispatchEvent(
      new CustomEvent("vesper-native", {
        detail: {
          v: 1,
          type: "panel.context",
          context: {
            active: spec,
            keepKeys: [spec.key],
          },
        },
      }),
    );
  }, panelSpec);

  const input = page.getByRole("combobox", { name: "Message" });
  await expect(input).toBeVisible();
  await expect(input).toHaveValue(parsedProps.prompt.text);
  expect(chat.posted).toHaveLength(0);
  expect(chat.created).toHaveLength(1);
});
