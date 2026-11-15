import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";

type Item = components["schemas"]["LibraryItem"];

// The Library: generated images saved from Assistant chats, private to the person.
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64");

async function installLibrary(page: Page, items: Item[]) {
  await installBoardApi(page);
  const deleted: string[] = [];
  // Registered after the board mock, so these win for /library.
  await page.route("**/api/v1/library**", async (route) => {
    const url = new URL(route.request().url());
    const m = url.pathname.match(/\/library\/([^/]+)(\/content)?$/);
    if (route.request().method() === "DELETE" && m) {
      deleted.push(m[1]);
      items.splice(items.findIndex((i) => i.id === m[1]), 1);
      return route.fulfill({ status: 204 });
    }
    if (m?.[2]) return route.fulfill({ status: 200, contentType: "image/png", body: png });
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ items, has_more: false }) });
  });
  return { deleted };
}

const item = (id: string, over: Partial<Item> = {}): Item => ({
  id, kind: "image", title: "Dragon lair", filename: `${id}.png`, content_type: "image/png", size_bytes: 2048, created_at: new Date().toISOString(), ...over,
});

test("the Library lists generated images with their source and can remove one", async ({ page }) => {
  const api = await installLibrary(page, [
    item("img-1", { chat_id: "chat-1", chat_title: "Dragon lair", project_key: "WEB", persona_id: "p-1", persona_name: "Gwen" }),
    item("img-2", { title: "Old map" }),
  ]);
  await page.goto("/library");
  // Library lives on the primary menu bar, so it reads as current.
  await expect(page.getByRole("navigation", { name: "Primary" }).locator('[aria-current="page"]')).toHaveAccessibleName(/^Library/);
  const tiles = page.getByTestId("library-item");
  await expect(tiles).toHaveCount(2);
  await expect(tiles.nth(0)).toContainText("Gwen");
  await expect(tiles.nth(0).getByRole("link", { name: "Dragon lair" })).toHaveAttribute("href", "/chat/chat-1");
  await expect(tiles.nth(1)).toContainText("chat deleted");

  await tiles.nth(1).getByRole("button", { name: "Open Old map" }).click();
  const dialog = page.getByRole("dialog", { name: "Old map" });
  await expect(dialog.getByRole("link", { name: "Download" })).toHaveAttribute("href", "/api/v1/library/img-2/content?download=true");
  await dialog.getByRole("button", { name: "Remove" }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Remove" }).click();
  await expect(tiles).toHaveCount(1);
  expect(api.deleted).toEqual(["img-2"]);
});

test("saved diagrams have their own tab and can't be references", async ({ page }) => {
  await installLibrary(page, [item("dia-1", { kind: "diagram", title: "Auth flow", filename: "diagram.svg", content_type: "image/svg+xml", chat_id: "chat-1", chat_title: "Auth flow", project_key: "WEB" })]);
  await page.goto("/library");
  await page.getByRole("tab", { name: "Diagrams" }).click();
  await page.getByRole("button", { name: "Open Auth flow" }).click();
  const dialog = page.getByRole("dialog", { name: "Auth flow" });
  await expect(dialog.getByRole("link", { name: "Download" })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Use as reference" })).toHaveCount(0);
});

test("an empty Library explains how images get there", async ({ page }) => {
  await installLibrary(page, []);
  await page.goto("/library");
  await expect(page.getByRole("heading", { name: "Nothing here yet" })).toBeVisible();
});

test("the Links tab lists saved links, filters them, plays videos and removes one", async ({ page }) => {
  const video = item("link-1", { kind: "link", title: "A talk", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", video_id: "dQw4w9WgXcQ", site: "Lab", note: "Short.", persona_name: "Gwen" });
  const site = item("link-2", { kind: "link", title: "Routes", url: "https://a.example/routes", site: "", note: "Good.", size_bytes: 0, content_type: "text/uri-list" });
  const api = await installLibrary(page, [video, site]);
  await page.route(/youtube-nocookie/, (route) => route.fulfill({ status: 200, contentType: "text/html", body: "ok" }));
  await page.goto("/library");
  await page.getByRole("tab", { name: "Links" }).click();

  const links = page.getByTestId("library-link");
  await expect(links).toHaveCount(2);
  await expect(links.first()).toContainText("From Gwen");
  await expect(links.nth(1)).toContainText("a.example");
  await expect(links.nth(1).locator("img")).toHaveCount(0);

  await page.getByRole("button", { name: "Pages" }).click();
  await expect(links).toHaveCount(1);
  await page.getByRole("button", { name: "Videos" }).click();
  await links.first().getByRole("button", { name: "Play A talk" }).click();
  await expect(links.first().locator("iframe")).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/dQw4w9WgXcQ/);

  await page.getByRole("button", { name: "All", exact: true }).click();
  // Removing is undoable: the link hides at once and is only deleted once the toast goes.
  const notifications = page.getByRole("region", { name: "Notifications" });
  await page.getByRole("button", { name: "Remove Routes" }).click();
  await expect(links).toHaveCount(1);
  await notifications.getByRole("button", { name: "Undo" }).click();
  await expect(links).toHaveCount(2);
  expect(api.deleted).toEqual([]);

  await page.getByRole("button", { name: "Remove Routes" }).click();
  await expect(links).toHaveCount(1);
  await notifications.getByRole("button", { name: "Dismiss notification" }).click();
  await expect.poll(() => api.deleted).toEqual(["link-2"]);
  await expect(links).toHaveCount(1);
});

test("links move through the reading queue and show saved summaries", async ({ page }) => {
  const a = item("link-1", { kind: "link", title: "To finish", url: "https://a.example/x", size_bytes: 0, summary: "Three points [1].\n\nSources:\n1. https://a.example/x" });
  const b = item("link-2", { kind: "link", title: "Finished", url: "https://b.example/y", size_bytes: 0, link_status: "done" });
  await installLibrary(page, [a, b]);
  const sets: unknown[] = [];
  await page.route("**/api/v1/library/*/link-status", (route) => {
    sets.push(route.request().postDataJSON());
    a.link_status = "done";
    return route.fulfill({ status: 204 });
  });
  await page.goto("/library");
  await page.getByRole("tab", { name: "Links" }).click();

  const links = page.getByTestId("library-link");
  await expect(links).toHaveCount(1);
  await expect(links.first()).toContainText("To finish");
  const summary = links.first().getByTestId("link-summary");
  await summary.getByText("Summary").click();
  await expect(summary).toContainText("Three points.");
  await expect(summary).not.toContainText("Sources:");

  await page.getByRole("button", { name: /^Done \(1\)/ }).click();
  await expect(links.first()).toContainText("Finished");
  await page.getByRole("button", { name: /^To read/ }).click();
  await links.first().getByRole("button", { name: "Mark done" }).click();
  expect(sets).toEqual([{ status: "done" }]);
  await expect(links).toHaveCount(0);
});
