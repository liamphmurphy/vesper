import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { _electron as electron, expect, test, type ElectronApplication, type Page } from "@playwright/test";

// Native features (epic "Native macOS features for the microVM Vesper.app").
// Run on a Mac: `npm run test:e2e`. These need a real display; the tray,
// Notification Center, Touch ID, login items and sleep/wake can't be driven
// from Playwright and are covered by unit tests plus the manual checklist in
// docs/dev/desktop-native.md.

const desktopRoot = path.resolve(__dirname, "..");

interface MockServer {
  server: http.Server;
  url: string;
  posts: Array<{ url: string; body: string }>;
}

function startMockVesperServer(): Promise<MockServer> {
  const posts: MockServer["posts"] = [];
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const reqUrl = req.url ?? "/";
      if (req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          posts.push({ url: reqUrl, body });
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ id: "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b" }));
        });
        return;
      }
      if (reqUrl === "/api/v1/inbox") return json(res, { items: [] });
      if (reqUrl.startsWith("/api/v1/runs")) return json(res, { runs: [], has_more: false });
      if (reqUrl === "/api/v1/personas") return json(res, { personas: [{ id: "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", name: "Meow" }] });
      if (reqUrl === "/api/v1/projects") return json(res, [{ key: "PAY", name: "Payments", archived: false }]);
      if (reqUrl === "/events") {
        res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
        res.write(": ok\n\n");
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(`<!doctype html><html><head><title>Inbox · Vesper</title></head><body><h1>Inbox</h1></body></html>`);
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") throw new Error("Expected numeric port");
      resolve({ server, url: `http://127.0.0.1:${addr.port}`, posts });
    });
  });
}

function json(res: http.ServerResponse, body: unknown) {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

async function launch(serverUrl: string, extraArgs: string[] = []) {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-native-e2e-"));
  const app = await electron.launch({
    args: [desktopRoot, ...extraArgs],
    env: { ...process.env, VESPER_USER_DATA_DIR: userDataDir, VESPER_SERVER_URL: serverUrl },
  });
  return { app, userDataDir };
}

async function windowByTitle(app: ElectronApplication, title: string): Promise<Page> {
  await expect.poll(async () => (await Promise.all(app.windows().map((w) => w.title()))).includes(title), { timeout: 10_000 }).toBe(true);
  for (const w of app.windows()) if ((await w.title()) === title) return w;
  throw new Error(`no window titled ${title}`);
}

test("vesper://capture opens Quick Capture, and Esc closes it without sending anything", async () => {
  const mock = await startMockVesperServer();
  const { app, userDataDir } = await launch(mock.url, ["vesper://capture"]);
  try {
    const capture = await windowByTitle(app, "Quick Capture");
    await expect(capture.locator("#text")).toBeVisible();
    await capture.locator("#text").fill("draft that should not be sent");
    await capture.keyboard.press("Escape");
    await expect.poll(async () => (await Promise.all(app.windows().map((w) => w.title()))).includes("Quick Capture")).toBe(false);
    expect(mock.posts).toEqual([]);
  } finally {
    await app.close();
    mock.server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});

test("Quick Capture saves a note through the knowledge capture API", async () => {
  const mock = await startMockVesperServer();
  const { app, userDataDir } = await launch(mock.url, ["vesper://capture"]);
  try {
    const capture = await windowByTitle(app, "Quick Capture");
    await capture.locator("#text").fill("buy oat milk");
    await capture.keyboard.press(process.platform === "darwin" ? "Meta+Enter" : "Control+Enter");
    await expect.poll(() => mock.posts.length).toBe(1);
    expect(mock.posts[0].url).toBe("/api/v1/knowledge/capture");
    expect(JSON.parse(mock.posts[0].body)).toEqual({ body_md: "buy oat milk" });
  } finally {
    await app.close();
    mock.server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});

test("a malformed vesper:// link is ignored: no extra window, no navigation", async () => {
  const mock = await startMockVesperServer();
  const { app, userDataDir } = await launch(mock.url, ["vesper://ticket/../../settings?x=1"]);
  try {
    const page = await app.firstWindow();
    await expect(page.locator("h1")).toHaveText("Inbox", { timeout: 10_000 });
    await page.waitForTimeout(500);
    expect(app.windows().length).toBe(1);
    expect(new URL(page.url()).pathname).toBe("/");
  } finally {
    await app.close();
    mock.server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});

test("Settings changes persist to config.json", async () => {
  test.skip(process.platform !== "darwin", "Settings… lives in the macOS app menu");
  const mock = await startMockVesperServer();
  const { app, userDataDir } = await launch(mock.url);
  try {
    await app.firstWindow();
    await app.evaluate(({ Menu }) => {
      const appMenu = Menu.getApplicationMenu()?.items[0]?.submenu;
      appMenu?.items.find((i) => i.label === "Settings…")?.click();
    });
    const prefs = await windowByTitle(app, "Vesper Settings");
    await prefs.locator('[data-key="tray.onLastWindowClose"] button[data-value="menuBar"]').click();
    await prefs.locator('nav button[data-section="notifications"]').click();
    await prefs.locator('input[data-key="notifications.kinds.merged"]').uncheck();
    await expect
      .poll(() => {
        try {
          return JSON.parse(fs.readFileSync(path.join(userDataDir, "config.json"), "utf8")).native;
        } catch {
          return null;
        }
      })
      .toMatchObject({ tray: { onLastWindowClose: "menuBar" }, notifications: { kinds: { merged: false } } });
  } finally {
    await app.close();
    mock.server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});
