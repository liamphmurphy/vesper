import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, Menu, session, shell } from "electron";
import { loadConfig, normalizeServerUrl, saveConfig, type DesktopConfig } from "./config";
import type { DesktopConnectionState, SetServerUrlInput, SetServerUrlResult } from "./preload";

export const SESSION_PARTITION = "persist:vesper";

const RENDERER_DIR = path.resolve(__dirname, "../renderer");
const OFFLINE_HTML = path.join(RENDERER_DIR, "offline.html");

let configPath = "";
let currentConfig: DesktopConfig;
let settingsWindow: BrowserWindow | null = null;

interface WindowEntry {
  win: BrowserWindow;
  targetUrl: string;
  showingOffline: boolean;
}

const windows = new Map<number, WindowEntry>();
let currentState: DesktopConnectionState = {
  serverUrl: "http://localhost:8080",
  targetUrl: "http://localhost:8080",
  phase: "checking",
};

function getVesperSession() {
  return session.fromPartition(SESSION_PARTITION);
}

export function isTrustedRendererUrl(frameUrl: string | undefined): boolean {
  if (!frameUrl) return false;
  try {
    const parsed = new URL(frameUrl);
    if (parsed.protocol !== "file:") return false;
    const filePath = path.resolve(fileURLToPath(parsed));
    return filePath === RENDERER_DIR || filePath.startsWith(`${RENDERER_DIR}${path.sep}`);
  } catch {
    return false;
  }
}

async function probeServer(serverUrl: string): Promise<{ reachable: boolean; errorMessage?: string }> {
  const ses = getVesperSession();
  try {
    const response = await ses.fetch(serverUrl, {
      method: "HEAD",
      signal: AbortSignal.timeout(3500),
    });
    // Any HTTP response (including 302/401/405) means the server is up and accepting requests.
    void response.body?.cancel();
    return { reachable: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { reachable: false, errorMessage: message };
  }
}

function broadcastState(next: DesktopConnectionState) {
  currentState = next;
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.isDestroyed()) {
      win.webContents.send("vesper:state", currentState);
    }
  }
}

async function checkAndUpdateState(targetUrlOverride?: string): Promise<DesktopConnectionState> {
  const targetUrl = targetUrlOverride ?? currentConfig.serverUrl;
  broadcastState({
    serverUrl: currentConfig.serverUrl,
    targetUrl,
    phase: "checking",
    localCheckoutPath: currentConfig.localCheckoutPath,
  });

  const probe = await probeServer(currentConfig.serverUrl);
  const next: DesktopConnectionState = {
    serverUrl: currentConfig.serverUrl,
    targetUrl,
    phase: probe.reachable ? "reachable" : "unreachable",
    errorMessage: probe.errorMessage,
    lastCheckedAt: new Date().toISOString(),
    localCheckoutPath: currentConfig.localCheckoutPath,
  };
  broadcastState(next);
  return next;
}

async function navigateWindow(entry: WindowEntry, targetUrl?: string) {
  const dest = targetUrl ?? entry.targetUrl ?? currentConfig.serverUrl;
  entry.targetUrl = dest;

  const probe = await probeServer(currentConfig.serverUrl);
  if (probe.reachable) {
    entry.showingOffline = false;
    broadcastState({
      serverUrl: currentConfig.serverUrl,
      targetUrl: dest,
      phase: "reachable",
      lastCheckedAt: new Date().toISOString(),
      localCheckoutPath: currentConfig.localCheckoutPath,
    });
    await entry.win.loadURL(dest).catch(() => {
      // did-fail-load handles rendering the offline screen if navigation fails mid-flight.
    });
    return;
  }

  entry.showingOffline = true;
  broadcastState({
    serverUrl: currentConfig.serverUrl,
    targetUrl: dest,
    phase: "unreachable",
    errorMessage: probe.errorMessage,
    lastCheckedAt: new Date().toISOString(),
    localCheckoutPath: currentConfig.localCheckoutPath,
  });
  await entry.win.loadFile(OFFLINE_HTML);
}

function createVesperWindow(initialUrl?: string): BrowserWindow {
  const win = new BrowserWindow({
    width: 1280,
    height: 840,
    minWidth: 760,
    minHeight: 540,
    title: "Vesper",
    backgroundColor: "#141221",
    webPreferences: {
      partition: SESSION_PARTITION,
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  const entry: WindowEntry = {
    win,
    targetUrl: initialUrl ?? currentConfig.serverUrl,
    showingOffline: false,
  };
  windows.set(win.id, entry);

  win.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
    if (!isMainFrame || errorCode === -3) return;
    if (validatedURL.startsWith("file://")) return;
    entry.targetUrl = validatedURL || currentConfig.serverUrl;
    entry.showingOffline = true;
    broadcastState({
      serverUrl: currentConfig.serverUrl,
      targetUrl: entry.targetUrl,
      phase: "unreachable",
      errorMessage: errorDescription || `Error ${errorCode}`,
      lastCheckedAt: new Date().toISOString(),
      localCheckoutPath: currentConfig.localCheckoutPath,
    });
    void win.loadFile(OFFLINE_HTML);
  });

  win.webContents.on("did-navigate", (_event, navUrl) => {
    if (!navUrl.startsWith("file://")) {
      entry.targetUrl = navUrl;
      entry.showingOffline = false;
    }
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    try {
      const target = new URL(url);
      const server = new URL(currentConfig.serverUrl);
      if (target.origin === server.origin) {
        createVesperWindow(url);
        return { action: "deny" };
      }
    } catch {
      // Fall through to deny.
    }
    if (url.startsWith("http://") || url.startsWith("https://")) {
      void shell.openExternal(url);
    }
    return { action: "deny" };
  });

  win.on("closed", () => {
    windows.delete(win.id);
  });

  void navigateWindow(entry, entry.targetUrl);
  return win;
}

function openSettingsWindow() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.focus();
    return;
  }
  settingsWindow = new BrowserWindow({
    width: 540,
    height: 480,
    resizable: false,
    minimizable: false,
    maximizable: false,
    title: "Vesper Settings",
    backgroundColor: "#141221",
    webPreferences: {
      partition: SESSION_PARTITION,
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  settingsWindow.on("closed", () => {
    settingsWindow = null;
  });
  void settingsWindow.loadFile(OFFLINE_HTML, { query: { mode: "settings" } });
  void checkAndUpdateState();
}

function buildAppMenu() {
  const isMac = process.platform === "darwin";
  const template: Electron.MenuItemConstructorOptions[] = [
    ...(isMac
      ? [
          {
            label: app.name,
            submenu: [
              { role: "about" as const },
              { type: "separator" as const },
              {
                label: "Settings…",
                accelerator: "CmdOrCtrl+,",
                click: () => openSettingsWindow(),
              },
              { type: "separator" as const },
              { role: "services" as const },
              { type: "separator" as const },
              { role: "hide" as const },
              { role: "hideOthers" as const },
              { role: "unhide" as const },
              { type: "separator" as const },
              { role: "quit" as const },
            ],
          },
        ]
      : []),
    {
      label: "File",
      submenu: [
        {
          label: "New Window",
          accelerator: "CmdOrCtrl+N",
          click: () => createVesperWindow(),
        },
        {
          label: "Change Server URL…",
          accelerator: isMac ? undefined : "CmdOrCtrl+,",
          click: () => openSettingsWindow(),
        },
        { type: "separator" },
        isMac ? { role: "close" } : { role: "quit" },
      ],
    },
    { role: "editMenu" },
    { role: "viewMenu" },
    { role: "windowMenu" },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function registerIpc() {
  ipcMain.handle("vesper:get-state", (event): DesktopConnectionState => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    return currentState;
  });

  ipcMain.handle("vesper:retry-connection", async (event): Promise<DesktopConnectionState> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    const senderWin = BrowserWindow.fromWebContents(event.sender);
    const entry = senderWin ? windows.get(senderWin.id) : undefined;
    return checkAndUpdateState(entry?.targetUrl);
  });

  ipcMain.handle("vesper:open-target", async (event): Promise<void> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    const senderWin = BrowserWindow.fromWebContents(event.sender);
    if (senderWin && settingsWindow && senderWin.id === settingsWindow.id) {
      settingsWindow.close();
      const primary = Array.from(windows.values())[0];
      if (primary) {
        primary.win.focus();
        await navigateWindow(primary, currentConfig.serverUrl);
      } else {
        createVesperWindow();
      }
      return;
    }
    const entry = senderWin ? windows.get(senderWin.id) : undefined;
    if (entry && entry.showingOffline) {
      await navigateWindow(entry, entry.targetUrl);
    }
  });

  ipcMain.handle("vesper:set-server-url", async (event, input: SetServerUrlInput): Promise<SetServerUrlResult> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    try {
      const normalized = normalizeServerUrl(input.serverUrl);
      const nextConfig: DesktopConfig = {
        ...currentConfig,
        serverUrl: normalized,
        ...(input.localCheckoutPath !== undefined
          ? { localCheckoutPath: input.localCheckoutPath.trim() || undefined }
          : {}),
      };
      saveConfig(configPath, nextConfig);
      currentConfig = nextConfig;

      // Update main windows to point at the newly configured server URL.
      for (const entry of windows.values()) {
        entry.targetUrl = normalized;
      }

      const state = await checkAndUpdateState(normalized);
      if (state.phase === "reachable") {
        for (const entry of windows.values()) {
          void navigateWindow(entry, normalized);
        }
        if (settingsWindow && !settingsWindow.isDestroyed()) {
          settingsWindow.close();
        }
      }
      return { ok: true, state };
    } catch (err) {
      return {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
        state: currentState,
      };
    }
  });
}

void app.whenReady().then(() => {
  configPath = path.join(app.getPath("userData"), "config.json");
  currentConfig = loadConfig(configPath);
  if (process.env.VESPER_SERVER_URL) {
    try {
      currentConfig.serverUrl = normalizeServerUrl(process.env.VESPER_SERVER_URL);
    } catch {
      // Ignore invalid env override.
    }
  }
  currentState = {
    serverUrl: currentConfig.serverUrl,
    targetUrl: currentConfig.serverUrl,
    phase: "checking",
    localCheckoutPath: currentConfig.localCheckoutPath,
  };

  buildAppMenu();
  registerIpc();
  createVesperWindow();

  app.on("activate", () => {
    if (windows.size === 0) {
      createVesperWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
