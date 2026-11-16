import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { _electron as electron, expect, test } from "@playwright/test";

const desktopRoot = path.resolve(__dirname, "..");

function createTempUserDataDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "vesper-electron-e2e-"));
}

async function getUnusedPort() {
  return await new Promise<number>((resolve, reject) => {
    const srv = http.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const addr = srv.address();
      if (!addr || typeof addr === "string") {
        srv.close();
        reject(new Error("Failed to acquire port"));
        return;
      }
      const { port } = addr;
      srv.close(() => resolve(port));
    });
  });
}

function startMockVesperServer() {
  return new Promise<{ server: http.Server; url: string }>((resolve) => {
    const server = http.createServer((req, res) => {
      const reqUrl = req.url ?? "/";
      if (reqUrl === "/api/v1/inbox") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ items: [] }));
        return;
      }
      if (reqUrl === "/events") {
        res.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
        });
        res.write(": ok\n\n");
        return;
      }
      if (reqUrl.startsWith("/chat/1")) {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end("<!doctype html><html><head><title>Chat 1 · Vesper</title></head><body><h1>Chat 1</h1></body></html>");
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(
        `<!doctype html><html><head><title>Inbox · Vesper</title></head><body>
          <h1>Inbox</h1>
          <button id="open-internal" onclick="window.open('/chat/1', '_blank')">Open Chat</button>
          <button id="open-external" onclick="window.open('https://example.com/docs', '_blank')">External</button>
        </body></html>`,
      );
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") throw new Error("Expected numeric port");
      resolve({ server, url: `http://127.0.0.1:${addr.port}` });
    });
  });
}

test("renders offline connection screen without uncaught errors when server is unreachable", async () => {
  const userDataDir = createTempUserDataDir();
  const unusedPort = await getUnusedPort();
  const app = await electron.launch({
    args: [desktopRoot],
    env: {
      ...process.env,
      VESPER_USER_DATA_DIR: userDataDir,
      VESPER_SERVER_URL: `http://127.0.0.1:${unusedPort}`,
    },
  });

  try {
    const page = await app.firstWindow();
    const errors: Error[] = [];
    page.on("pageerror", (err) => errors.push(err));

    await expect(page.locator("#status-label")).toHaveText("Server unreachable", { timeout: 10_000 });
    await expect(page.locator("#server-url-input")).toHaveValue(`http://127.0.0.1:${unusedPort}`);
    assert.equal(errors.length, 0);
  } finally {
    await app.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});

test("loads local Vesper server, opens internal tab, and blocks external navigation inside Electron", async () => {
  const userDataDir = createTempUserDataDir();
  const { server, url } = await startMockVesperServer();
  const app = await electron.launch({
    args: [desktopRoot],
    env: {
      ...process.env,
      VESPER_USER_DATA_DIR: userDataDir,
      VESPER_SERVER_URL: url,
    },
  });

  try {
    const page = await app.firstWindow();
    await expect(page.locator("h1")).toHaveText("Inbox", { timeout: 10_000 });

    const newWindowPromise = app.waitForEvent("window");
    await page.click("#open-internal");
    const secondPage = await newWindowPromise;
    await expect(secondPage.locator("h1")).toHaveText("Chat 1", { timeout: 10_000 });

    // External link should hand off to shell.openExternal rather than navigating or opening a 3rd window.
    await page.click("#open-external");
    await page.waitForTimeout(300);
    assert.equal(app.windows().length, 2);
    expect(page.url()).toContain(url);
  } finally {
    await app.close();
    server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});
