import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";

type Item = components["schemas"]["LibraryItem"];
type Preview = components["schemas"]["LibraryFilePreview"];

// The Library's Files and Exports tabs: type-badge tiles, a read-only preview that never
// renders a page, and exports that say whether their source changed.

const file = (id: string, over: Partial<Item> = {}): Item => ({
  id, kind: "file", title: "render_riff.py", filename: "render_riff.py", content_type: "text/plain; charset=utf-8", size_bytes: 4096, detail: "112 lines",
  source: "generated", persona_name: "Hackerman", chat_id: "chat-1", chat_title: "Heavy metal music", created_at: new Date().toISOString(), ...over,
});

const exportItem = (id: string, status: "current" | "changed" | "deleted", over: Partial<Item> = {}): Item => ({
  id, kind: "export", title: "Q4 planning deck", filename: "Q4 planning deck.pdf", content_type: "application/pdf", size_bytes: 3_100_000, detail: "14 slides", source: "generated",
  export_source: { kind: "slides", id: "deck-1", status, ...(status === "deleted" ? {} : { title: "Q4 planning deck" }) }, created_at: new Date().toISOString(), ...over,
});

const previews: Record<string, Preview> = {
  "f-py": { kind: "text", lines: ["import mido", "from mido import Message", "<script>alert(1)</script>"], total: 112, truncated: true },
  "f-csv": { kind: "table", rows: [["id", "amount"], ["1", "5.50"], ["2", "7.25"]], total: 1205, truncated: true },
  "f-zip": { kind: "zip", entries: [{ name: "src/b.py", size: 2048 }, { name: "a.py", size: 512 }], total: 18, truncated: true },
  "f-pdf": { kind: "none", total: 0, truncated: false },
};

async function installLibrary(page: Page, items: Item[]) {
  await installBoardApi(page);
  const seen = { uploaded: [] as string[], deleted: [] as string[] };
  await page.route("**/api/v1/library**", async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const m = url.pathname.match(/\/library\/([^/]+)(\/content|\/preview)?$/);
    if (m?.[2] === "/preview") return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(previews[m[1]] ?? previews["f-pdf"]) });
    if (req.method() === "DELETE" && m) {
      seen.deleted.push(m[1]);
      items.splice(items.findIndex((i) => i.id === m[1]), 1);
      return route.fulfill({ status: 204 });
    }
    if (req.method() === "POST" && url.pathname.endsWith("/library")) {
      const name = /filename="([^"]+)"/.exec(req.postData() ?? "")?.[1] ?? "";
      seen.uploaded.push(name);
      const it = file("up-1", { title: name, filename: name, source: "upload", chat_id: undefined, persona_name: undefined, detail: "3 lines" });
      items.unshift(it);
      return route.fulfill({ status: 201, contentType: "application/json", body: JSON.stringify(it) });
    }
    const kind = url.searchParams.get("kind");
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ items: items.filter((i) => !kind || i.kind === kind), has_more: false }) });
  });
  return seen;
}

test("the Files tab shows type badges with a summary, size and source", async ({ page }) => {
  await installLibrary(page, [
    file("f-py"),
    file("f-csv", { title: "payouts-q3.csv", filename: "payouts-q3.csv", content_type: "text/csv", detail: "1,205 rows · 3 columns", source: "upload", chat_id: undefined, persona_name: undefined }),
    file("f-zip", { title: "metal-riff-project.zip", filename: "metal-riff-project.zip", content_type: "application/zip", detail: "18 files", size_bytes: 2_516_582 }),
  ]);
  await page.goto("/library");
  await page.getByRole("tab", { name: "Files" }).click();
  const tiles = page.getByTestId("library-item");
  await expect(tiles).toHaveCount(3);
  await expect(tiles.nth(0)).toContainText("PY");
  await expect(tiles.nth(0)).toContainText("112 lines · 4 KB");
  await expect(tiles.nth(0)).toContainText("Hackerman");
  await expect(tiles.nth(1)).toContainText("CSV");
  await expect(tiles.nth(1)).toContainText("1,205 rows · 3 columns");
  await expect(tiles.nth(1)).toContainText("Uploaded by you");
  await expect(tiles.nth(2)).toContainText("ZIP");
  await expect(tiles.nth(2)).toContainText("18 files");
});

test("a text file previews as text, never as markup", async ({ page }) => {
  await installLibrary(page, [file("f-py")]);
  await page.goto("/library?tab=files&item=f-py");
  const dialog = page.getByRole("dialog", { name: "render_riff.py" });
  const preview = dialog.getByTestId("file-preview");
  await expect(preview).toHaveAttribute("data-kind", "text");
  await expect(preview).toContainText("import mido");
  // The script tag is text on the page, not an element.
  await expect(preview).toContainText("<script>alert(1)</script>");
  await expect(preview.locator("script")).toHaveCount(0);
  await expect(preview).toContainText("Showing the start of the file");
  await expect(dialog.getByRole("link", { name: "Download" })).toHaveAttribute("href", "/api/v1/library/f-py/content?download=true");
  await expect(dialog.getByRole("link", { name: "Open chat" })).toHaveAttribute("href", "/chat/chat-1");
});

test("a CSV previews as a table and a zip as a list that says nothing is unpacked", async ({ page }) => {
  await installLibrary(page, [file("f-csv", { title: "payouts-q3.csv", filename: "payouts-q3.csv" }), file("f-zip", { title: "bundle.zip", filename: "bundle.zip" })]);
  await page.goto("/library?tab=files&item=f-csv");
  const table = page.getByRole("dialog", { name: "payouts-q3.csv" }).getByTestId("file-preview");
  await expect(table).toHaveAttribute("data-kind", "table");
  await expect(table.getByRole("row")).toHaveCount(3);
  await expect(table.getByRole("cell", { name: "7.25" })).toBeVisible();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Open bundle.zip" }).click();
  const zip = page.getByRole("dialog", { name: "bundle.zip" }).getByTestId("file-preview");
  await expect(zip).toHaveAttribute("data-kind", "zip");
  await expect(zip.getByRole("listitem")).toHaveCount(2);
  await expect(zip).toContainText("src/b.py");
  await expect(zip).toContainText("Showing 2 of 18 files. Nothing is unpacked.");
});

test("a file with nothing to show says to download it", async ({ page }) => {
  await installLibrary(page, [file("f-xlsx", { title: "Model.xlsx", filename: "Model.xlsx", content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", detail: undefined })]);
  await page.goto("/library?tab=files&item=f-xlsx");
  await expect(page.getByRole("dialog", { name: "Model.xlsx" }).getByTestId("file-preview")).toContainText("No preview for this type of file");
});

test("a PDF opens an inline PDF preview in its dialog", async ({ page }) => {
  await installLibrary(page, [file("f-pdf", { title: "Report.pdf", filename: "Report.pdf", content_type: "application/pdf", detail: "2 pages · Letter" })]);
  await page.goto("/library?tab=files&item=f-pdf");
  const preview = page.getByRole("dialog", { name: "Report.pdf" }).getByTestId("file-preview");
  await expect(preview).toHaveAttribute("data-kind", "pdf");
});

test("removing a file asks first and says file", async ({ page }) => {
  const seen = await installLibrary(page, [file("f-py")]);
  await page.goto("/library?tab=files&item=f-py");
  const dialog = page.getByRole("dialog", { name: "render_riff.py" });
  await dialog.getByRole("button", { name: "Remove" }).click();
  const confirm = page.getByRole("alertdialog");
  await expect(confirm).toContainText("this file");
  await confirm.getByRole("button", { name: "Remove" }).click();
  await expect(page.getByTestId("library-item")).toHaveCount(0);
  expect(seen.deleted).toEqual(["f-py"]);
});

test("the Exports tab says whether each source changed since", async ({ page }) => {
  await installLibrary(page, [
    exportItem("e-1", "changed"),
    exportItem("e-2", "current", { title: "Onboarding flow", filename: "Onboarding flow.png", content_type: "image/png", detail: undefined, export_source: { kind: "designs", id: "design-1", title: "Onboarding flow", status: "current" } }),
    exportItem("e-3", "deleted", { title: "Launch notes", filename: "Launch notes.md", content_type: "text/markdown", detail: "412 words", export_source: { kind: "docs", id: "doc-1", status: "deleted" } }),
  ]);
  await page.goto("/library");
  await page.getByRole("tab", { name: "Exports" }).click();
  const tiles = page.getByTestId("library-item");
  await expect(tiles).toHaveCount(3);
  await expect(tiles.nth(0)).toContainText("PDF · from Slides");
  await expect(tiles.nth(0)).toContainText("14 slides · 3.0 MB");
  const changed = tiles.nth(0).getByTestId("export-source");
  await expect(changed).toHaveAttribute("data-status", "changed");
  await expect(changed).toContainText("Slides › Q4 planning deck (edited since)");
  await expect(changed.getByRole("link")).toHaveAttribute("href", "/apps/slides/deck-1");
  await expect(tiles.nth(1).getByTestId("export-source")).toContainText("Designs › Onboarding flow (up to date)");
  await expect(tiles.nth(1).getByTestId("export-source").getByRole("link")).toHaveAttribute("href", "/apps/designs/design-1");
  const gone = tiles.nth(2).getByTestId("export-source");
  await expect(gone).toHaveAttribute("data-status", "deleted");
  await expect(gone).toContainText("Docs (source deleted)");
  await expect(gone.getByRole("link")).toHaveCount(0);
});

test("empty Files and Exports tabs say how things get there", async ({ page }) => {
  await installLibrary(page, []);
  await page.goto("/library?tab=files");
  await expect(page.getByText("When a persona that can code hands you a file")).toBeVisible();
  await page.getByRole("tab", { name: "Exports" }).click();
  await expect(page.getByText("Export a deck, design or document and choose Save to Library")).toBeVisible();
});

test("any file can be uploaded, and the new file shows under Files", async ({ page }) => {
  const seen = await installLibrary(page, []);
  await page.goto("/library?tab=files");
  await page.getByLabel("File to upload").setInputFiles({ name: "notes.py", mimeType: "", buffer: Buffer.from("print(1)\n") });
  await expect(page.getByTestId("library-item")).toHaveCount(1);
  expect(seen.uploaded).toEqual(["notes.py"]);
});
