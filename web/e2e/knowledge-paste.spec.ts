import { expect, test, type Page as BrowserPage } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";
import type { Embed, Page } from "../lib/api/knowledge-hooks";

const ID = "55555555-5555-4555-8555-555555555555";
const mod = process.platform === "darwin" ? "Meta" : "Control";
const TINY_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=",
  "base64",
);

async function install(
  page: BrowserPage,
  opts: { body?: string; pending?: boolean; uploadStatus?: number; uploadError?: string } = {},
) {
  await installChatApi(page);
  const saved: string[] = [];
  const uploads: { filename: string; contentType: string; size: number }[] = [];
  const assets = new Map<string, { filename: string; contentType: string; body: Buffer }>();
  let assetSeq = 0;

  const note: Page = {
    id: ID,
    title: "Notes",
    path: "Docs/Notes",
    audience: "private",
    body_md: opts.body ?? "Before.",
    version_id: "v1",
    seq: 1,
    properties: {},
    direct: false,
    paused: false,
    chat_id: null,
    url: `/knowledge/${ID}`,
    embeds: [],
    reviews: opts.pending
      ? [
          {
            id: "rev-1",
            state: "suggested",
            review_state: "pending",
            changes: [{ index: 0, kind: "replace", before: "Before.", after: "Suggested.", state: "pending" }],
            author_id: "persona-1",
            created_at: "2026-11-20T20:00:00Z",
          },
        ]
      : [],
    versions: [],
  };

  await page.route(/\/api\/v1\/knowledge\//, async (route) => {
    const reqUrl = new URL(route.request().url());
    const path = reqUrl.pathname.replace("/api/v1/knowledge", "");
    const method = route.request().method();

    if (path === "/assets" && method === "POST") {
      const filename = reqUrl.searchParams.get("filename") ?? route.request().headers()["x-filename"] ?? "attachment";
      const body = route.request().postDataBuffer() ?? Buffer.alloc(0);
      if (opts.uploadStatus && opts.uploadStatus >= 400) {
        return route.fulfill({
          status: opts.uploadStatus,
          contentType: "application/json",
          body: JSON.stringify({ code: "invalid", message: opts.uploadError ?? "Upload rejected" }),
        });
      }
      const id = `asset-${++assetSeq}`;
      const contentType = filename.endsWith(".zip")
        ? "application/zip"
        : filename.endsWith(".mp3")
          ? "audio/mpeg"
          : "image/png";
      uploads.push({ filename, contentType, size: body.length });
      assets.set(id, { filename, contentType, body });
      const ref = `attachment:${id}/${filename}`;
      return route.fulfill({
        status: 201,
        contentType: "application/json",
        body: JSON.stringify({ id, ref, url: `/api/v1/knowledge/assets/${id}`, filename, content_type: contentType }),
      });
    }

    if (path.startsWith("/assets/") && method === "GET") {
      const id = path.slice("/assets/".length);
      const stored = assets.get(id);
      if (!stored) return route.fulfill({ status: 404, body: "not found" });
      return route.fulfill({
        status: 200,
        headers: { "Content-Type": stored.contentType, "X-Content-Type-Options": "nosniff" },
        body: stored.body,
      });
    }

    let data: unknown = {};
    if (path === "/query") data = { rows: [note], has_more: false };
    if (path === `/pages/${ID}`) {
      if (method === "PUT") {
        const input = route.request().postDataJSON();
        saved.push(input.body_md);
        Object.assign(note, input, { seq: note.seq + 1, version_id: `v${note.seq + 1}` });
        const embeds: Embed[] = [];
        for (const [id, stored] of assets.entries()) {
          const raw = `![[attachment:${id}/${stored.filename}]]`;
          if (note.body_md?.includes(raw)) {
            embeds.push({
              ref: raw,
              kind: "file",
              title: stored.filename,
              url: `/api/v1/knowledge/assets/${id}`,
              content_type: stored.contentType,
              available: true,
            });
          }
        }
        note.embeds = embeds;
      }
      data = note;
    }
    if (path === "/backlinks") data = { linked: [], unlinked: [] };
    if (path === "/resolve") data = { links: [] };
    return route.fulfill({ contentType: "application/json", body: JSON.stringify(data) });
  });

  await page.goto(`/knowledge/${ID}`);
  const editor = page.getByTestId("doc-editor");
  await expect(editor).toBeVisible();
  if (!opts.pending) {
    await editor.focus();
    await editor.press(`${mod}+End`);
  }
  return { editor, saved, uploads };
}

async function pasteClipboard(
  page: BrowserPage,
  payload: { files?: { name: string; type: string; bytes: number[] }[]; text?: string; html?: string },
) {
  await page.getByTestId("doc-editor").evaluate((el, data) => {
    const dt = new DataTransfer();
    for (const f of data.files ?? []) {
      dt.items.add(new File([new Uint8Array(f.bytes)], f.name, { type: f.type }));
    }
    if (data.text !== undefined) dt.setData("text/plain", data.text);
    if (data.html !== undefined) dt.setData("text/html", data.html);
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
  }, payload);
}

test("pasting a screenshot uploads it, shows inline preview immediately, and autosaves", async ({ page }) => {
  const { editor, saved, uploads } = await install(page, { body: "Before." });

  await pasteClipboard(page, {
    files: [{ name: "image.png", type: "image/png", bytes: Array.from(TINY_PNG) }],
  });

  await expect.poll(() => uploads.length).toBe(1);
  expect(uploads[0].filename).toBe("pasted-image-1.png");

  const img = editor.getByRole("img", { name: "pasted-image-1.png" });
  await expect(img).toBeVisible();
  await expect(editor.locator(".kn-source-hidden")).toContainText("![[attachment:asset-1/pasted-image-1.png]]");

  await expect.poll(() => saved.at(-1)).toBe("Before.\n\n![[attachment:asset-1/pasted-image-1.png]]\n\n");
  await expect(img).toBeVisible();
});

test("pasting a non-image binary file preserves its filename, renders download card, and autosaves", async ({ page }) => {
  const { editor, saved, uploads } = await install(page, { body: "Notes." });

  await pasteClipboard(page, {
    files: [{ name: "archive.zip", type: "application/zip", bytes: [0x50, 0x4b, 0x03, 0x04] }],
    text: "archive.zip",
  });

  await expect.poll(() => uploads.length).toBe(1);
  expect(uploads[0].filename).toBe("archive.zip");

  const figure = editor.locator("figure");
  await expect(figure).toContainText("archive.zip");
  await expect(figure.getByRole("link", { name: "Download", exact: true })).toHaveAttribute("download", "archive.zip");
  await expect.poll(() => saved.at(-1)).toBe("Notes.\n\n![[attachment:asset-1/archive.zip]]\n\n");
});

test("pasting spreadsheet cells with a synthetic preview image leaves normal text paste intact", async ({ page }) => {
  const { editor, uploads } = await install(page, { body: "Table: " });

  await pasteClipboard(page, {
    files: [{ name: "image.png", type: "image/png", bytes: Array.from(TINY_PNG) }],
    text: "A1\tB1",
    html: "<table><tr><td>A1</td><td>B1</td></tr></table>",
  });

  await expect(editor.getByRole("img")).toHaveCount(0);
  expect(uploads).toEqual([]);
});

test("upload error shows a toast and leaves the note unmodified", async ({ page }) => {
  const { editor, saved } = await install(page, {
    body: "Unchanged.",
    uploadStatus: 422,
    uploadError: "storage unavailable",
  });

  await pasteClipboard(page, {
    files: [{ name: "image.png", type: "image/png", bytes: Array.from(TINY_PNG) }],
  });

  await expect(page.getByText("Couldn’t upload pasted-image-1.png", { exact: true })).toBeVisible();
  await expect(page.getByText("storage unavailable", { exact: true })).toBeVisible();
  await expect(editor).toHaveText("Unchanged.", { useInnerText: true });
  expect(saved).toEqual([]);
});

test("pasting into a locked note with pending reviews does not upload or mutate the note", async ({ page }) => {
  const { editor, saved, uploads } = await install(page, { body: "Locked.", pending: true });

  await pasteClipboard(page, {
    files: [{ name: "image.png", type: "image/png", bytes: Array.from(TINY_PNG) }],
  });

  await expect(editor).toHaveText("Locked.", { useInnerText: true });
  expect(uploads).toEqual([]);
  expect(saved).toEqual([]);
});
