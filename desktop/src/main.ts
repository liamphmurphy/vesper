import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, session, shell } from "electron";
import {
  loadConfig,
  loadSession,
  normalizeServerUrl,
  saveConfig,
  saveSession,
  type DesktopConfig,
  type SessionState,
  type WindowBounds,
} from "./config";
import { buildApplicationMenu } from "./menu";
import type { DesktopConnectionState, SetServerUrlInput, SetServerUrlResult } from "./preload";
import { classifyNavigation, cleanTabTitle, ClosedTabStack } from "./routing";

export const SESSION_PARTITION = "persist:vesper";
export const TABBING_IDENTIFIER = "vesper";

const RENDERER_DIR = path.resolve(__dirname, "../renderer");
const OFFLINE_HTML = path.join(RENDERER_DIR, "offline.html");

let configPath = "";
let sessionPath = "";
let currentConfig: DesktopConfig;
let settingsWindow: BrowserWindow | null = null;
let isQuitting = false;
let sessionSaveTimer: NodeJS.Timeout | undefined;

interface WindowEntry {
  win: BrowserWindow;
  targetUrl: string;
  showingOffline: boolean;
}

const windows = new Map<number, WindowEntry>();
const tabOrder: number[] = [];
const closedTabStack = new ClosedTabStack(25);

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
    // Any HTTP response (including 302/401/405) means the server is accepting connections.
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

function captureWindowBounds(win: BrowserWindow): WindowBounds {
  const b = win.getBounds();
  return {
    x: b.x,
    y: b.y,
    width: b.width,
    height: b.height,
    isMaximized: win.isMaximized(),
  };
}

function snapshotSession(): SessionState {
  const orderedEntries = tabOrder
    .map((id) => windows.get(id))
    .filter((entry): entry is WindowEntry => Boolean(entry && !entry.win.isDestroyed()));

  const tabs = orderedEntries.map((entry) => entry.targetUrl);
  const focused = BrowserWindow.getFocusedWindow();
  const focusedIdx = focused ? orderedEntries.findIndex((entry) => entry.win.id === focused.id) : -1;
  const activeIndex = focusedIdx >= 0 ? focusedIdx : 0;
  const refWin = (focusedIdx >= 0 ? orderedEntries[focusedIdx]?.win : orderedEntries[0]?.win) ?? undefined;

  return {
    tabs,
    activeIndex,
    ...(refWin ? { bounds: captureWindowBounds(refWin) } : {}),
  };
}

function persistSessionNow() {
  if (!sessionPath) return;
  try {
    saveSession(sessionPath, snapshotSession());
  } catch {
    // Non-fatal: disk write errors shouldn't break tab closing or quit.
  }
}

function scheduleSessionSave() {
  if (isQuitting) return;
  if (sessionSaveTimer) clearTimeout(sessionSaveTimer);
  sessionSaveTimer = setTimeout(() => {
    sessionSaveTimer = undefined;
    persistSessionNow();
  }, 300);
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

interface CreateWindowOptions {
  url?: string;
  parentWin?: BrowserWindow;
  tabbed?: boolean;
  background?: boolean;
  bounds?: WindowBounds;
}

function insertTabOrder(winId: number, parentId?: number) {
  if (parentId !== undefined) {
    const idx = tabOrder.indexOf(parentId);
    if (idx >= 0) {
      tabOrder.splice(idx + 1, 0, winId);
      return;
    }
  }
  tabOrder.push(winId);
}

function createVesperWindow(opts: CreateWindowOptions = {}): BrowserWindow {
  const parentWin = opts.parentWin && !opts.parentWin.isDestroyed() ? opts.parentWin : undefined;
  const fallbackBounds = parentWin ? captureWindowBounds(parentWin) : opts.bounds;

  const win = new BrowserWindow({
    width: fallbackBounds?.width ?? 1280,
    height: fallbackBounds?.height ?? 840,
    ...(fallbackBounds?.x !== undefined ? { x: fallbackBounds.x } : {}),
    ...(fallbackBounds?.y !== undefined ? { y: fallbackBounds.y } : {}),
    minWidth: 760,
    minHeight: 540,
    show: !opts.background,
    title: "Vesper",
    tabbingIdentifier: TABBING_IDENTIFIER,
    backgroundColor: "#141221",
    webPreferences: {
      partition: SESSION_PARTITION,
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  if (fallbackBounds?.isMaximized && !opts.tabbed) {
    win.maximize();
  }

  const entry: WindowEntry = {
    win,
    targetUrl: opts.url ?? currentConfig.serverUrl,
    showingOffline: false,
  };
  windows.set(win.id, entry);
  insertTabOrder(win.id, opts.tabbed && parentWin ? parentWin.id : undefined);

  if (opts.tabbed && parentWin && typeof parentWin.addTabbedWindow === "function") {
    const previousFocus = BrowserWindow.getFocusedWindow() ?? parentWin;
    parentWin.addTabbedWindow(win);
    if (opts.background) {
      win.showInactive();
      if (!previousFocus.isDestroyed()) {
        previousFocus.focus();
      }
    } else {
      win.show();
      win.focus();
    }
  } else if (opts.background) {
    win.showInactive();
  }

  win.on("page-title-updated", (event, title) => {
    event.preventDefault();
    win.setTitle(cleanTabTitle(title));
  });

  // macOS Cocoa "+" button in the native tab bar emits new-window-for-tab on the active window.
  win.on("new-window-for-tab", () => {
    createVesperWindow({ url: currentConfig.serverUrl, parentWin: win, tabbed: true });
  });

  win.on("swipe", (_event, direction) => {
    if (direction === "left" && win.webContents.navigationHistory.canGoBack()) {
      win.webContents.navigationHistory.goBack();
    } else if (direction === "right" && win.webContents.navigationHistory.canGoForward()) {
      win.webContents.navigationHistory.goForward();
    }
  });

  win.on("app-command", (_event, command) => {
    if (command === "browser-backward" && win.webContents.navigationHistory.canGoBack()) {
      win.webContents.navigationHistory.goBack();
    } else if (command === "browser-forward" && win.webContents.navigationHistory.canGoForward()) {
      win.webContents.navigationHistory.goForward();
    }
  });

  win.on("moved", scheduleSessionSave);
  win.on("resized", scheduleSessionSave);

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
      scheduleSessionSave();
    }
  });

  win.webContents.on("did-navigate-in-page", (_event, navUrl, isMainFrame) => {
    if (isMainFrame && !navUrl.startsWith("file://")) {
      entry.targetUrl = navUrl;
      scheduleSessionSave();
    }
  });

  win.webContents.on("will-navigate", (event, navUrl) => {
    if (isTrustedRendererUrl(navUrl)) return;
    const kind = classifyNavigation(navUrl, currentConfig.serverUrl, currentConfig.playgroundPorts);
    if (kind === "vesper" || kind === "playground") return;
    event.preventDefault();
    if (kind === "external") {
      void shell.openExternal(navUrl);
    }
  });

  win.webContents.setWindowOpenHandler(({ url, disposition }) => {
    const kind = classifyNavigation(url, currentConfig.serverUrl, currentConfig.playgroundPorts);
    if (kind === "vesper" || kind === "playground") {
      createVesperWindow({
        url,
        parentWin: win,
        tabbed: true,
        background: disposition === "background-tab",
      });
      return { action: "deny" };
    }
    if (kind === "external") {
      void shell.openExternal(url);
    }
    return { action: "deny" };
  });

  win.on("closed", () => {
    if (!isQuitting) {
      closedTabStack.push(entry.targetUrl);
    }
    windows.delete(win.id);
    const idx = tabOrder.indexOf(win.id);
    if (idx >= 0) tabOrder.splice(idx, 1);
    if (!isQuitting) {
      scheduleSessionSave();
    }
  });

  scheduleSessionSave();
  void navigateWindow(entry, entry.targetUrl);
  return win;
}

function resolveActiveWindow(focusedWin?: BrowserWindow): BrowserWindow | undefined {
  if (focusedWin && !focusedWin.isDestroyed() && windows.has(focusedWin.id)) {
    return focusedWin;
  }
  const active = BrowserWindow.getFocusedWindow();
  if (active && !active.isDestroyed() && windows.has(active.id)) {
    return active;
  }
  const firstId = tabOrder[0];
  return firstId !== undefined ? windows.get(firstId)?.win : undefined;
}

function cycleTab(delta: 1 | -1, focusedWin?: BrowserWindow) {
  const current = resolveActiveWindow(focusedWin);
  if (!current) return;
  if (process.platform === "darwin") {
    if (delta === 1 && typeof current.selectNextTab === "function") {
      current.selectNextTab();
      return;
    }
    if (delta === -1 && typeof current.selectPreviousTab === "function") {
      current.selectPreviousTab();
      return;
    }
  }
  if (tabOrder.length <= 1) return;
  const idx = tabOrder.indexOf(current.id);
  const nextIdx = (idx + delta + tabOrder.length) % tabOrder.length;
  windows.get(tabOrder[nextIdx])?.win.focus();
}

function selectTabByNumber(n: number) {
  if (tabOrder.length === 0) return;
  const index = n === 9 ? tabOrder.length - 1 : n - 1;
  if (index < 0 || index >= tabOrder.length) return;
  const target = windows.get(tabOrder[index])?.win;
  if (target && !target.isDestroyed()) {
    target.focus();
  }
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

function setupMenu() {
  buildApplicationMenu({
    newTab: (focusedWin) => {
      const parentWin = resolveActiveWindow(focusedWin);
      createVesperWindow({
        url: currentConfig.serverUrl,
        parentWin,
        tabbed: Boolean(parentWin),
      });
    },
    newWindow: () => {
      createVesperWindow({ url: currentConfig.serverUrl, tabbed: false });
    },
    reopenClosedTab: (focusedWin) => {
      const url = closedTabStack.pop();
      if (!url) return;
      const parentWin = resolveActiveWindow(focusedWin);
      createVesperWindow({
        url,
        parentWin,
        tabbed: Boolean(parentWin),
      });
    },
    closeTab: (focusedWin) => {
      const target = focusedWin && !focusedWin.isDestroyed() ? focusedWin : BrowserWindow.getFocusedWindow();
      target?.close();
    },
    closeAllTabsInWindow: (focusedWin) => {
      const target = resolveActiveWindow(focusedWin);
      if (!target) return;
      for (const entry of Array.from(windows.values())) {
        if (!entry.win.isDestroyed()) {
          entry.win.close();
        }
      }
    },
    selectNextTab: (focusedWin) => cycleTab(1, focusedWin),
    selectPreviousTab: (focusedWin) => cycleTab(-1, focusedWin),
    selectTabIndex: (n) => selectTabByNumber(n),
    goBack: (focusedWin) => {
      const target = resolveActiveWindow(focusedWin);
      if (target?.webContents.navigationHistory.canGoBack()) {
        target.webContents.navigationHistory.goBack();
      }
    },
    goForward: (focusedWin) => {
      const target = resolveActiveWindow(focusedWin);
      if (target?.webContents.navigationHistory.canGoForward()) {
        target.webContents.navigationHistory.goForward();
      }
    },
    openSettings: () => openSettingsWindow(),
  });
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
      const primary = resolveActiveWindow();
      if (primary) {
        const entry = windows.get(primary.id);
        primary.focus();
        if (entry) await navigateWindow(entry, currentConfig.serverUrl);
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

      for (const entry of windows.values()) {
        entry.targetUrl = normalized;
      }
      persistSessionNow();

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

function restoreSessionWindows() {
  const saved = loadSession(sessionPath);
  // Restore tabs matching the active server origin or playground ports; otherwise start fresh on serverUrl.
  const restorable = saved.tabs.filter((tabUrl) => {
    const kind = classifyNavigation(tabUrl, currentConfig.serverUrl, currentConfig.playgroundPorts);
    return kind === "vesper" || kind === "playground";
  });

  if (restorable.length === 0) {
    createVesperWindow({ url: currentConfig.serverUrl, bounds: saved.bounds });
    return;
  }

  let firstWin: BrowserWindow | undefined;
  const created: BrowserWindow[] = [];
  for (let i = 0; i < restorable.length; i++) {
    const win = createVesperWindow({
      url: restorable[i],
      parentWin: firstWin,
      tabbed: Boolean(firstWin),
      bounds: i === 0 ? saved.bounds : undefined,
    });
    if (!firstWin) firstWin = win;
    created.push(win);
  }

  const active = created[Math.min(saved.activeIndex, created.length - 1)];
  if (active && !active.isDestroyed()) {
    active.focus();
  }
}

void app.whenReady().then(() => {
  configPath = path.join(app.getPath("userData"), "config.json");
  sessionPath = path.join(app.getPath("userData"), "session.json");
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

  setupMenu();
  registerIpc();
  restoreSessionWindows();

  app.on("activate", () => {
    if (windows.size === 0) {
      createVesperWindow();
    }
  });
});

app.on("before-quit", () => {
  isQuitting = true;
  if (sessionSaveTimer) {
    clearTimeout(sessionSaveTimer);
    sessionSaveTimer = undefined;
  }
  persistSessionNow();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
