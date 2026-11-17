import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, desktopCapturer, dialog, ipcMain, safeStorage, session, shell } from "electron";
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
import { checkDockerAvailability, isLocalhostUrl, isValidVesperCheckout, startLocalComposeStack } from "./docker";
import { buildApplicationMenu } from "./menu";
import { findVesperLinkInArgv } from "./deeplink";
import { NativeFeatures } from "./native";
import { releaseAssetUrl } from "./updates";
import { InboxMonitor } from "./notifications";
import type {
  DesktopConnectionState,
  ImportBackupInput,
  ImportBackupResult,
  PickBackupResult,
  SetServerUrlInput,
  SetServerUrlResult,
  StartStackResult,
} from "./preload";
import { classifyNavigation, cleanTabTitle, ClosedTabStack } from "./routing";
import {
  ensureAuthenticatedSession,
  ensureSecretsKey,
  hasActiveRuns,
  inspectBackupArchive,
  LocalVesperStack,
  resolveBundledResources,
  runAppImportArchive,
  saveSecretsKey,
  validateSecretsKeyFormat,
} from "./stack";

export const SESSION_PARTITION = "persist:vesper";
export const TABBING_IDENTIFIER = "vesper";

if (process.env.VESPER_USER_DATA_DIR) {
  app.setPath("userData", path.resolve(process.env.VESPER_USER_DATA_DIR));
}

const RENDERER_DIR = path.resolve(__dirname, "../renderer");
const OFFLINE_HTML = path.join(RENDERER_DIR, "offline.html");

let configPath = "";
let sessionPath = "";
let currentConfig: DesktopConfig;
let settingsWindow: BrowserWindow | null = null;
let importWindow: BrowserWindow | null = null;
let isQuitting = false;
let quitConfirmed = false;
let sessionSaveTimer: NodeJS.Timeout | undefined;
let stackStarting = false;
let localStack: LocalVesperStack | null = null;
/** The bundled stack is starting (first launch, restart); drives the health view. */
let bundledStarting = false;
/** Why the bundled stack last failed to start, until it next starts. */
let bundledStartError: string | undefined;
/** A main Vesper window was open since the last time every window closed. */
let hadMainWindow = false;

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
  isLocalhost: true,
};

const native = new NativeFeatures({
  config: () => currentConfig,
  saveNative: (next) => {
    currentConfig = { ...currentConfig, native: next };
    saveConfig(configPath, currentConfig);
  },
  fetch: (url, init) => getVesperSession().fetch(url, init),
  openHref: (href) => focusOrOpenHref(href),
  showMainWindow: () => showMainWindow(),
  openServerSettings: () => openSettingsWindow(),
  stackMode: () => stackMode(),
  stackSnapshot: () => ({
    starting: bundledStarting,
    running: Boolean(localStack?.isRunning()),
    startError: bundledStartError,
    exit: localStack?.lastExit() ?? null,
  }),
  connectionReachable: () => (currentState.phase === "reachable" ? true : currentState.phase === "unreachable" ? false : undefined),
  restartStack: () => restartBundledStack(),
  isTrustedRendererUrl: (url) => isTrustedRendererUrl(url),
  rendererDir: RENDERER_DIR,
  preloadPath: path.join(__dirname, "preload.js"),
  partition: SESSION_PARTITION,
  backgroundColor: "#141221",
});

const inboxMonitor = new InboxMonitor({
  fetch: (url, init) => getVesperSession().fetch(url, init),
  onBadgeChange: (badge, count) => {
    if (process.platform === "darwin" && app.dock) {
      app.dock.setBadge(badge);
    }
    native.onBadge(count);
  },
  shouldNotify: (href) => shouldNotifyForHref(href),
  onAlert: (alert) => native.showAlert(alert),
  onItems: (items) => native.onInboxItems(items),
  onServerEvent: (type) => native.onServerEvent(type),
});

// macOS delivers vesper:// links and opened files as app events, possibly before
// "ready" (cold start); NativeFeatures queues them until it has started.
app.on("open-url", (event, url) => {
  event.preventDefault();
  native.handleLink(url);
});
app.on("open-file", (event, filePath) => {
  if (native.handleOpenFile(filePath)) event.preventDefault();
});

/** local: the bundled `vesper app`; remote: a server off this Mac; external: localhost served by something else. */
function stackMode(): "local" | "remote" | "external" {
  if (!isLocalhostUrl(currentConfig?.serverUrl ?? "")) return "remote";
  return bundledResourcesDir() ? "local" : "external";
}

function showMainWindow() {
  if (process.platform === "darwin") app.focus({ steal: true });
  const win = resolveActiveWindow();
  if (win) {
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
  } else {
    createVesperWindow({ url: currentConfig.serverUrl });
  }
}

/** Stops and starts the bundled stack (menu, tray, logs window, auto-restart after a crash). */
async function restartBundledStack(): Promise<void> {
  if (stackMode() !== "local" || bundledStarting) return;
  inboxMonitor.stop();
  await localStack?.stop();
  localStack = null;
  try {
    await startBundledStackIfLocalhost();
  } catch {
    // startBundledStackIfLocalhost recorded the error for the health view.
  }
  inboxMonitor.start(currentConfig.serverUrl);
  const state = await checkAndUpdateState();
  if (state.phase === "reachable") {
    for (const entry of windows.values()) {
      if (entry.showingOffline) void navigateWindow(entry, entry.targetUrl);
    }
  }
}

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

function shouldNotifyForHref(href: string): boolean {
  const focused = BrowserWindow.getFocusedWindow();
  if (!focused || focused.isDestroyed()) return true;
  const entry = windows.get(focused.id);
  if (!entry || entry.showingOffline) return true;
  try {
    const current = new URL(entry.targetUrl);
    const target = new URL(href, currentConfig.serverUrl);
    return `${current.pathname}${current.search}` !== `${target.pathname}${target.search}`;
  } catch {
    return true;
  }
}

function focusOrOpenHref(href: string) {
  let fullUrl: string;
  try {
    fullUrl = new URL(href, currentConfig.serverUrl).toString();
  } catch {
    fullUrl = currentConfig.serverUrl;
  }

  // A link off this server (a GitHub pull request) opens in the browser, not an app window.
  try {
    if (new URL(fullUrl).origin !== new URL(currentConfig.serverUrl).origin) {
      void shell.openExternal(fullUrl).catch(() => {});
      return;
    }
  } catch {
    // Fall through to the window lookup.
  }

  if (process.platform === "darwin") {
    app.focus({ steal: true });
  }

  for (const id of tabOrder) {
    const entry = windows.get(id);
    if (!entry || entry.win.isDestroyed()) continue;
    try {
      const tabParsed = new URL(entry.targetUrl);
      const targetParsed = new URL(fullUrl);
      if (`${tabParsed.pathname}${tabParsed.search}` === `${targetParsed.pathname}${targetParsed.search}`) {
        if (entry.win.isMinimized()) entry.win.restore();
        entry.win.show();
        entry.win.focus();
        return;
      }
    } catch {
      // Ignore unparseable window URLs.
    }
  }

  const parentWin = resolveActiveWindow();
  createVesperWindow({
    url: fullUrl,
    parentWin,
    tabbed: Boolean(parentWin),
  });
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
  native.refreshHealth();
}

async function checkAndUpdateState(targetUrlOverride?: string): Promise<DesktopConnectionState> {
  const targetUrl = targetUrlOverride ?? currentConfig.serverUrl;
  const localhost = isLocalhostUrl(currentConfig.serverUrl);
  broadcastState({
    serverUrl: currentConfig.serverUrl,
    targetUrl,
    phase: "checking",
    localCheckoutPath: currentConfig.localCheckoutPath,
    isLocalhost: localhost,
    docker: currentState.docker,
    stackStarting,
  });

  const [probe, docker] = await Promise.all([
    probeServer(currentConfig.serverUrl),
    localhost ? checkDockerAvailability() : Promise.resolve(undefined),
  ]);

  const next: DesktopConnectionState = {
    serverUrl: currentConfig.serverUrl,
    targetUrl,
    phase: probe.reachable ? "reachable" : "unreachable",
    errorMessage: probe.errorMessage,
    lastCheckedAt: new Date().toISOString(),
    localCheckoutPath: currentConfig.localCheckoutPath,
    isLocalhost: localhost,
    docker,
    stackStarting,
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

  const localhost = isLocalhostUrl(currentConfig.serverUrl);
  const probe = await probeServer(currentConfig.serverUrl);
  if (probe.reachable) {
    entry.showingOffline = false;
    broadcastState({
      serverUrl: currentConfig.serverUrl,
      targetUrl: dest,
      phase: "reachable",
      lastCheckedAt: new Date().toISOString(),
      localCheckoutPath: currentConfig.localCheckoutPath,
      isLocalhost: localhost,
      docker: currentState.docker,
      stackStarting,
    });
    await entry.win.loadURL(dest).catch(() => {
      // did-fail-load handles rendering the offline screen if navigation fails mid-flight.
    });
    return;
  }

  entry.showingOffline = true;
  const docker = localhost ? await checkDockerAvailability() : undefined;
  broadcastState({
    serverUrl: currentConfig.serverUrl,
    targetUrl: dest,
    phase: "unreachable",
    errorMessage: probe.errorMessage,
    lastCheckedAt: new Date().toISOString(),
    localCheckoutPath: currentConfig.localCheckoutPath,
    isLocalhost: localhost,
    docker,
    stackStarting,
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

  native.windowOpened();
  hadMainWindow = true;
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
    void checkAndUpdateState(entry.targetUrl).then((state) => {
      broadcastState({
        ...state,
        phase: "unreachable",
        errorMessage: errorDescription || state.errorMessage || `Error ${errorCode}`,
      });
    });
    void win.loadFile(OFFLINE_HTML);
  });

  win.webContents.on("did-finish-load", () => {
    const loadedUrl = win.webContents.getURL();
    if (!loadedUrl.startsWith("file://")) {
      void inboxMonitor.refreshNow();
    }
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
    // A file dropped on the page outside a drop target navigates to its file:// URL;
    // offer to send it to a chat instead (LAZYAGENTS-247). Only a browser-initiated
    // navigation (a drop) counts: a file:// link clicked in page content has an
    // initiator frame and is just blocked, so content can't put a local file in front
    // of the person to send.
    if (navUrl.startsWith("file://")) {
      event.preventDefault();
      if (!event.initiator) native.handleDroppedFileUrl(navUrl);
      return;
    }
    const kind = classifyNavigation(navUrl, currentConfig.serverUrl, currentConfig.playgroundPorts);
    if (kind === "vesper" || kind === "playground") return;
    event.preventDefault();
    if (kind === "external") {
      void shell.openExternal(navUrl).catch(() => {});
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
      void shell.openExternal(url).catch(() => {});
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
    width: 560,
    height: 540,
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

function openImportWindow() {
  if (importWindow && !importWindow.isDestroyed()) {
    importWindow.focus();
    return;
  }
  importWindow = new BrowserWindow({
    width: 560,
    height: 560,
    resizable: false,
    minimizable: false,
    maximizable: false,
    title: "Import Vesper Backup",
    backgroundColor: "#141221",
    webPreferences: {
      partition: SESSION_PARTITION,
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  importWindow.on("closed", () => {
    importWindow = null;
  });
  void importWindow.loadFile(OFFLINE_HTML, { query: { mode: "import" } });
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
    openSettings: () => native.openPreferences(),
    openServerSettings: () => openSettingsWindow(),
    importBackup: () => openImportWindow(),
    quickCapture: () => native.openCapture(),
    screenshot: () => void native.takeScreenshot(),
    restartStack: () => void native.restartStack(),
    showLogs: () => native.openLogs(),
    checkForUpdates: () => void manualUpdateCheck(),
  });
}

async function manualUpdateCheck() {
  const result = await native.checkForUpdates(true);
  if (result.status === "available") return;
  await dialog.showMessageBox({
    type: result.status === "error" ? "warning" : "info",
    message: result.status === "error" ? "Couldn't check for updates" : `Vesper ${app.getVersion()} is the newest version`,
    detail: result.status === "error" ? result.error : undefined,
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

  ipcMain.handle("vesper:pick-checkout-folder", async (event): Promise<string | null> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    const senderWin = BrowserWindow.fromWebContents(event.sender);
    const dialogOpts: Electron.OpenDialogOptions = {
      properties: ["openDirectory"],
      title: "Select Local Vesper Checkout",
    };
    const result = senderWin ? await dialog.showOpenDialog(senderWin, dialogOpts) : await dialog.showOpenDialog(dialogOpts);
    if (result.canceled || result.filePaths.length === 0) return null;
    const chosen = result.filePaths[0];
    currentConfig = { ...currentConfig, localCheckoutPath: chosen };
    saveConfig(configPath, currentConfig);
    broadcastState({ ...currentState, localCheckoutPath: chosen });
    return chosen;
  });

  ipcMain.handle("vesper:pick-backup-archive", async (event): Promise<PickBackupResult | null> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    const baseDir = bundledResourcesDir();
    const resources = baseDir ? resolveBundledResources(baseDir) : null;
    if (!resources) {
      return { archivePath: "", error: "Bundled Vesper runtime is not available in this build." };
    }
    const senderWin = BrowserWindow.fromWebContents(event.sender);
    const dialogOpts: Electron.OpenDialogOptions = {
      properties: ["openFile", "openDirectory"],
      title: "Select Vesper Backup (.zip or unpacked folder)",
    };
    const result = senderWin ? await dialog.showOpenDialog(senderWin, dialogOpts) : await dialog.showOpenDialog(dialogOpts);
    if (result.canceled || result.filePaths.length === 0) return null;

    const archivePath = result.filePaths[0];
    try {
      const currentKey = ensureSecretsKey(app.getPath("userData"), safeStorage);
      const inspection = await inspectBackupArchive({
        vesperBin: resources.vesperBin,
        archivePath,
        currentSecretsKey: currentKey,
      });
      return { archivePath, inspection };
    } catch (err) {
      return {
        archivePath,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  });

  ipcMain.handle("vesper:import-backup", async (event, input: ImportBackupInput): Promise<ImportBackupResult> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    if (!isLocalhostUrl(currentConfig.serverUrl)) {
      return { ok: false, error: "Switch Server URL back to http://localhost:8080 before importing into the local app." };
    }
    const baseDir = bundledResourcesDir();
    const resources = baseDir ? resolveBundledResources(baseDir) : null;
    if (!resources) {
      return { ok: false, error: "Bundled Vesper runtime is not available in this build." };
    }
    const archivePath = (input?.archivePath ?? "").trim();
    if (!archivePath) {
      return { ok: false, error: "Choose a .zip backup archive first." };
    }

    const userDataDir = app.getPath("userData");
    const dropSecrets = Boolean(input.dropSecrets);
    const providedKey = (input.secretsKey ?? "").trim();
    if (!dropSecrets && providedKey) {
      try {
        validateSecretsKeyFormat(providedKey);
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err) };
      }
    }

    if (localStack?.isRunning()) {
      const busy = await hasActiveRuns(currentConfig.serverUrl, (url, init) => getVesperSession().fetch(url, init));
      if (busy) {
        const senderWin = BrowserWindow.fromWebContents(event.sender);
        const promptOpts: Electron.MessageBoxOptions = {
          type: "warning",
          buttons: ["Import Anyway", "Cancel"],
          defaultId: 1,
          cancelId: 1,
          title: "Runs are still active",
          message: "One or more microVM runs are still in progress.",
          detail: "Importing a backup will stop the local Vesper runtime and replace the current database and blobs.",
        };
        const res = senderWin ? await dialog.showMessageBox(senderWin, promptOpts) : await dialog.showMessageBox(promptOpts);
        if (res.response === 1) {
          return { ok: false, error: "Import cancelled." };
        }
      }
    }

    let keyForImport = "";
    if (!dropSecrets) {
      if (providedKey) {
        keyForImport = providedKey;
      } else {
        try {
          const existingKey = ensureSecretsKey(userDataDir, safeStorage);
          const insp = await inspectBackupArchive({
            vesperBin: resources.vesperBin,
            archivePath,
            currentSecretsKey: existingKey,
          });
          if (insp.matchesCurrentKey) {
            keyForImport = existingKey;
          }
        } catch (err) {
          return { ok: false, error: err instanceof Error ? err.message : String(err) };
        }
      }
    }

    inboxMonitor.stop();
    await localStack?.stop();
    localStack = null;

    try {
      await runAppImportArchive({
        resources,
        userDataDir,
        archivePath,
        secretsKey: keyForImport,
        dropSecrets,
      });
    } catch (err) {
      await startBundledStackIfLocalhost().catch(() => {});
      inboxMonitor.start(currentConfig.serverUrl);
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }

    if (!dropSecrets && providedKey) {
      saveSecretsKey(userDataDir, safeStorage, providedKey);
    }

    try {
      const vesperSession = getVesperSession();
      for (const cookie of await vesperSession.cookies.get({ url: currentConfig.serverUrl })) {
        const domain = (cookie.domain ?? "").replace(/^\./, "") || new URL(currentConfig.serverUrl).hostname;
        const cookieUrl = `${cookie.secure ? "https" : "http"}://${domain}${cookie.path || "/"}`;
        await vesperSession.cookies.remove(cookieUrl, cookie.name);
      }
      await startBundledStackIfLocalhost();
      inboxMonitor.start(currentConfig.serverUrl);
      await checkAndUpdateState();

      if (windows.size === 0) {
        createVesperWindow({ url: currentConfig.serverUrl });
      } else {
        for (const entry of windows.values()) {
          entry.targetUrl = currentConfig.serverUrl;
          void navigateWindow(entry, currentConfig.serverUrl);
        }
      }
      if (importWindow && !importWindow.isDestroyed()) {
        importWindow.close();
      }
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  });

  ipcMain.handle("vesper:start-local-stack", async (event, checkoutArg?: string): Promise<StartStackResult> => {
    if (!isTrustedRendererUrl(event.senderFrame?.url)) {
      throw new Error("Untrusted IPC caller");
    }
    if (!isLocalhostUrl(currentConfig.serverUrl)) {
      return { ok: false, error: "Local stack startup is only available for localhost targets." };
    }
    if (stackStarting) {
      return { ok: false, error: "Stack startup is already in progress." };
    }

    if (bundledResourcesDir()) {
      stackStarting = true;
      broadcastState({ ...currentState, stackStarting: true });
      try {
        await startBundledStackIfLocalhost();
        await checkAndUpdateState();
        return { ok: true };
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err) };
      } finally {
        stackStarting = false;
        broadcastState({ ...currentState, stackStarting: false });
      }
    }

    const checkoutPath = (checkoutArg ?? currentConfig.localCheckoutPath ?? "").trim();
    if (!isValidVesperCheckout(checkoutPath)) {
      return { ok: false, error: "Please choose a Vesper checkout folder containing docker-compose.yml." };
    }

    if (checkoutPath !== currentConfig.localCheckoutPath) {
      currentConfig = { ...currentConfig, localCheckoutPath: checkoutPath };
      saveConfig(configPath, currentConfig);
    }

    stackStarting = true;
    broadcastState({ ...currentState, localCheckoutPath: checkoutPath, stackStarting: true });

    try {
      const result = await startLocalComposeStack(checkoutPath, (chunk) => {
        for (const win of BrowserWindow.getAllWindows()) {
          if (!win.isDestroyed()) {
            win.webContents.send("vesper:stack-log", chunk);
          }
        }
      });
      return result;
    } finally {
      stackStarting = false;
      broadcastState({ ...currentState, localCheckoutPath: checkoutPath, stackStarting: false });
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
      inboxMonitor.start(normalized);
      native.serverUrlChanged(normalized);

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

function bundledResourcesDir() {
  const candidates = app.isPackaged
    ? [process.resourcesPath]
    : [path.resolve(__dirname, "../resources")];
  for (const dir of candidates) {
    if (resolveBundledResources(dir)) {
      return dir;
    }
  }
  return null;
}

async function startBundledStackIfLocalhost(): Promise<void> {
  if (!isLocalhostUrl(currentConfig.serverUrl)) {
    return;
  }
  const baseDir = bundledResourcesDir();
  const resources = baseDir ? resolveBundledResources(baseDir) : null;
  if (!resources) {
    return;
  }

  const userDataDir = app.getPath("userData");
  const secretsKey = ensureSecretsKey(userDataDir, safeStorage);
  let targetPort = 8080;
  try {
    const parsed = new URL(currentConfig.serverUrl);
    if (parsed.port) {
      targetPort = Number(parsed.port);
    }
  } catch {
    targetPort = 8080;
  }

  if (!localStack) {
    const stack = new LocalVesperStack({
      resources,
      userDataDir,
      secretsKey,
      port: targetPort,
      nodeBin: process.execPath,
      nodeRunAsNode: true,
      onLog: (chunk) => {
        for (const win of BrowserWindow.getAllWindows()) {
          if (!win.isDestroyed()) {
            win.webContents.send("vesper:stack-log", chunk);
          }
        }
      },
      onUnexpectedExit: (exit) => {
        if (localStack === stack) native.stackCrashed(exit);
      },
      // A downloaded DMG has no agent image on a fresh Mac; fetch this version's from its release.
      ...(app.isPackaged ? { rootfsUrl: releaseAssetUrl(app.getVersion(), "agent-base.erofs") ?? undefined } : {}),
    });
    localStack = stack;
  }

  bundledStarting = true;
  bundledStartError = undefined;
  native.refreshHealth();
  let readyUrl: string;
  try {
    readyUrl = await localStack.start();
  } catch (err) {
    bundledStartError = err instanceof Error ? err.message : String(err);
    throw err;
  } finally {
    bundledStarting = false;
    native.refreshHealth();
  }
  try {
    const parsedReady = new URL(readyUrl);
    const parsedCurrent = new URL(currentConfig.serverUrl);
    const canonical = `${parsedCurrent.protocol}//${parsedCurrent.hostname}:${parsedReady.port}`;
    if (canonical !== currentConfig.serverUrl) {
      currentConfig = { ...currentConfig, serverUrl: canonical };
      currentState = { ...currentState, serverUrl: canonical, targetUrl: canonical };
    }
  } catch {
    // Keep configured serverUrl.
  }

  await ensureAuthenticatedSession({
    serverUrl: currentConfig.serverUrl,
    vesperBin: resources.vesperBin,
    runtimeJsonPath: path.join(userDataDir, "runtime.json"),
    fetch: (url, init) => getVesperSession().fetch(url, init),
  });
}

function setupDisplayMediaHandler() {
  getVesperSession().setDisplayMediaRequestHandler(async (_request, callback) => {
    try {
      const sources = await desktopCapturer.getSources({ types: ["window", "screen"] });
      const preferred =
        sources.find((s) => s.name.includes("Vesper") || s.name.includes("Playground")) ?? sources[0];
      if (!preferred) {
        callback({});
        return;
      }
      callback({ video: preferred });
    } catch {
      callback({});
    }
  });
}

void app.whenReady().then(async () => {
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
    isLocalhost: isLocalhostUrl(currentConfig.serverUrl),
  };

  setupMenu();
  setupDisplayMediaHandler();
  registerIpc();
  native.start();
  const coldStartLink = findVesperLinkInArgv(process.argv);
  if (coldStartLink) native.handleLink(coldStartLink);

  // An older build opening data a newer one migrated may fail to start (LAZYAGENTS-249).
  const version = native.checkVersion();
  if (version.transition === "downgrade" && stackMode() === "local") {
    const res = await dialog.showMessageBox({
      type: "warning",
      buttons: ["Open Anyway", "Quit"],
      defaultId: 1,
      cancelId: 1,
      message: `This Vesper (${version.current}) is older than the one that last opened your data (${version.last}).`,
      detail:
        "Its database may have changes this version doesn't know about, so it may not start. Installing the newer Vesper.app again is the safe choice. Your data isn't changed by quitting.",
    });
    if (res.response === 1) {
      app.exit(0);
      return;
    }
  } else if (version.transition !== "downgrade") {
    // A downgrade keeps the newer version on record, so the warning repeats until it's back.
    native.recordVersion();
  }

  const hidden = native.startHidden();
  if (hidden) app.dock?.hide();

  try {
    await startBundledStackIfLocalhost();
  } catch (err) {
    currentState = {
      ...currentState,
      phase: "unreachable",
      errorMessage: err instanceof Error ? err.message : String(err),
    };
    if (hidden) native.hiddenStartFailed(currentState.errorMessage ?? "The local stack didn't start.");
  }

  inboxMonitor.start(currentConfig.serverUrl);
  if (!hidden) restoreSessionWindows();

  app.on("activate", () => {
    if (windows.size === 0) {
      createVesperWindow();
    }
  });
});

app.on("before-quit", (event) => {
  if (!quitConfirmed && localStack?.isRunning()) {
    event.preventDefault();
    void (async () => {
      const busy = await hasActiveRuns(currentConfig.serverUrl, (url, init) => getVesperSession().fetch(url, init));
      if (native.quitNeedsConfirm(true, busy)) {
        const res = await dialog.showMessageBox({
          type: "warning",
          buttons: ["Quit Anyway", "Cancel"],
          defaultId: 1,
          cancelId: 1,
          title: "Runs are still active",
          message: "One or more microVM runs are still in progress.",
          detail: "Quitting Vesper will shut down the embedded runtime and stop active VMs.",
        });
        if (res.response === 1) {
          return;
        }
      }
      isQuitting = true;
      quitConfirmed = true;
      inboxMonitor.stop();
      native.stop();
      if (sessionSaveTimer) {
        clearTimeout(sessionSaveTimer);
        sessionSaveTimer = undefined;
      }
      persistSessionNow();
      await localStack?.stop();
      app.quit();
    })();
    return;
  }
  isQuitting = true;
  inboxMonitor.stop();
  native.stop();
  if (sessionSaveTimer) {
    clearTimeout(sessionSaveTimer);
    sessionSaveTimer = undefined;
  }
  persistSessionNow();
});

app.on("window-all-closed", () => {
  // Only the last Vesper window closing counts; closing Settings or Quick Capture
  // while no Vesper window is open (menu bar mode) must not quit the app.
  if (!hadMainWindow) return;
  hadMainWindow = false;
  native.windowAllClosed();
});
