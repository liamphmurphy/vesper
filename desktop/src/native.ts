import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as NodeReadableStream } from "node:stream/web";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  net,
  powerMonitor,
  powerSaveBlocker,
  shell,
  systemPreferences,
  type IpcMainInvokeEvent,
} from "electron";
import { apiRequest, type FetchFn } from "./api";
import { exportFileName, exportsToPrune, isExportDue, parseIsExcluded, timeMachineTargets } from "./backups";
import { SCREENCAPTURE_BIN, screencaptureArgs, screenshotFileName } from "./screenshot";
import { desiredSlotLimit, easingOffLabel, isThermalState, parseLowPowerMode, type ThermalState } from "./thermal";
import { isInsideRoots, openCommand, type OpenTarget } from "./workspace-open";
import { loadAppState, saveAppState, type AppState } from "./appstate";
import { touchIdDecision, touchIdReason, isTouchIdScope } from "./biometrics";
import {
  buildCaptureRequest,
  captureResultHref,
  formatAccelerator,
  systemShortcutConflict,
  validateGlobalShortcut,
  type CaptureInput,
  type CaptureKind,
} from "./capture";
import type { DesktopConfig } from "./config";
import { hrefToVesperLink, parseVesperLink } from "./deeplink";
import { buildMultipartBody, buildSendFilesRequest, classifyDroppedFiles, type AcceptedFile, type RejectedFile } from "./drop";
import { loginItemSettingsFor, loginStatusMessage, shouldStartHidden, type LoginItemStatus } from "./login";
import { NotificationPresenter } from "./native-notify";
import { TrayController } from "./native-tray";
import {
  decisionRequest,
  replyRequest,
  shouldShowAlert,
  touchIdScopeForKind,
  type DesktopAlert,
  type InboxItemSummary,
} from "./notifications";
import { batteryWarning, prunePausedSet, runsToPauseOnSleep, runsToResume, shouldConfirmQuit, wantsSleepBlocker } from "./power";
import { pausableRuns, RunMonitor, shouldRefreshRunsForSseEvent, type RunSummary } from "./runs";
import { appBundlePath, installServices, servicesInstalled, uninstallServices } from "./services";
import { applyNativeSettingsPatch, type NativeSettings, type TouchIdScope } from "./settings";
import {
  darwinMajor,
  deriveStackHealth,
  freeDiskBytes,
  readLogTail,
  shouldAutoRestart,
  type RootfsStatus,
  type StackHealth,
} from "./stack-health";
import type { StackExit } from "./stack";
import { lastWindowClosedAction, type TrayAction } from "./tray-model";
import { isCheckDue, pickUpdate, versionTransition } from "./updates";

const execFileAsync = promisify(execFile);

/** What the native features need from main.ts. */
export interface NativeContext {
  config(): DesktopConfig;
  saveNative(next: NativeSettings): void;
  fetch: FetchFn;
  openHref(href: string): void;
  showMainWindow(): void;
  openServerSettings(): void;
  stackMode(): "local" | "remote" | "external";
  stackSnapshot(): { starting: boolean; running: boolean; startError?: string; exit?: StackExit | null };
  connectionReachable(): boolean | undefined;
  restartStack(): Promise<void>;
  isTrustedRendererUrl(url: string | undefined): boolean;
  rendererDir: string;
  preloadPath: string;
  partition: string;
  backgroundColor: string;
}

type HealthListener = (health: StackHealth) => void;

/**
 * Native macOS features (epic "Native macOS features for the microVM
 * Vesper.app", LAZYAGENTS-240..249). main.ts owns windows and the stack;
 * this owns the menu bar icon, notifications, login item, quick capture,
 * deep links, power handling, stack health, file drops, Touch ID and updates.
 */
export class NativeFeatures {
  private readonly ctx: NativeContext;
  private readonly tray: TrayController;
  readonly presenter = new NotificationPresenter();
  private readonly runMonitor: RunMonitor;
  private items: readonly InboxItemSummary[] = [];
  private count = 0;
  private runs: readonly RunSummary[] = [];
  private image?: RootfsStatus;
  private runnerOnline?: boolean;
  private healthValue: StackHealth;
  private healthTimer: NodeJS.Timeout | undefined;
  private readonly healthListeners = new Set<HealthListener>();
  private readonly pausedByVesper = new Set<string>();
  private sleepBlockerId: number | null = null;
  private batteryWarned = false;
  private registeredShortcuts: string[] = [];
  private quickCaptureActive = false;
  private shortcutError: string | null = null;
  private screenshotActive = false;
  private screenshotError: string | null = null;
  /** Temp folders holding screenshots offered to the Send picker; removed when it closes. */
  private screenshotDirs: string[] = [];
  private thermal: ThermalState = "unknown";
  private lowPowerMode = false;
  private lowPowerTimer: NodeJS.Timeout | undefined;
  /** The runner's max_concurrent and current slot_limit, from GET /api/v1/runner. */
  private runnerMaxSlots = 0;
  private runnerSlotLimit: number | null = null;
  private exportTimer: NodeJS.Timeout | undefined;
  private exporting = false;
  private timeMachineExcluded: boolean | null = null;
  private restartTimes: number[] = [];
  private ready = false;
  private readonly pendingLinks: string[] = [];
  private pendingFiles: string[] = [];
  private fileTimer: NodeJS.Timeout | undefined;
  private captureWin: BrowserWindow | null = null;
  private prefsWin: BrowserWindow | null = null;
  private logsWin: BrowserWindow | null = null;
  private sendWin: BrowserWindow | null = null;
  private sendFiles: { accepted: AcceptedFile[]; rejected: RejectedFile[] } = { accepted: [], rejected: [] };
  private appStatePath = "";
  private appState: AppState = {};
  private updateTimer: NodeJS.Timeout | undefined;
  private readonly logsPath: string;

  constructor(ctx: NativeContext) {
    this.ctx = ctx;
    this.logsPath = path.join(app.getPath("userData"), "logs", "vesper-app.log");
    this.tray = new TrayController((a) => void this.onTrayAction(a));
    this.healthValue = { phase: "starting", title: "Starting Vesper…", message: "", nextStep: "", actions: [] };
    this.runMonitor = new RunMonitor({
      fetch: ctx.fetch,
      onSnapshot: (live) => {
        this.runs = live;
        prunePausedSet(this.pausedByVesper, live);
        this.updatePowerBlocker();
        this.renderTray();
      },
      onFinished: (alert) => this.showAlert(alert),
    });
  }

  private get settings(): NativeSettings {
    return this.ctx.config().native;
  }

  // ---------------------------------------------------------------- lifecycle

  /** Called once the app is ready and config is loaded, before windows open. */
  start(): void {
    this.ready = true;
    this.appStatePath = path.join(app.getPath("userData"), "app-state.json");
    this.appState = loadAppState(this.appStatePath);
    this.registerIpc();
    this.applyTray();
    this.applyLoginItem();
    this.applyShortcuts();
    this.setupPower();
    void this.applyTimeMachine();
    this.scheduleExport(60_000);
    this.runMonitor.start(this.ctx.config().serverUrl);
    this.scheduleHealth(0);
    this.scheduleUpdateCheck(30_000);
    for (const link of this.pendingLinks.splice(0)) this.handleLink(link);
    if (this.pendingFiles.length > 0) this.flushFiles();
  }

  stop(): void {
    this.runMonitor.stop();
    if (this.healthTimer) clearTimeout(this.healthTimer);
    if (this.updateTimer) clearTimeout(this.updateTimer);
    if (this.lowPowerTimer) clearInterval(this.lowPowerTimer);
    if (this.exportTimer) clearTimeout(this.exportTimer);
    this.removeScreenshotDirs();
    globalShortcut.unregisterAll();
    this.releaseBlocker();
  }

  serverUrlChanged(url: string): void {
    this.items = [];
    this.count = 0;
    this.runs = [];
    this.image = undefined;
    this.runnerOnline = undefined;
    this.runMonitor.start(url);
    this.refreshHealth();
  }

  /** Whether this launch should start in the menu bar only (LAZYAGENTS-242). */
  startHidden(): boolean {
    if (process.platform !== "darwin" || !app.isPackaged) return false;
    let wasOpenedAtLogin = false;
    try {
      wasOpenedAtLogin = app.getLoginItemSettings({ type: "mainAppService" }).wasOpenedAtLogin;
    } catch {
      wasOpenedAtLogin = false;
    }
    return shouldStartHidden(this.settings.login, this.settings.tray.enabled, wasOpenedAtLogin);
  }

  /**
   * Version bookkeeping before the stack starts (LAZYAGENTS-249). Returns
   * "downgrade" with both versions when an older build opens newer data.
   */
  checkVersion(): { transition: ReturnType<typeof versionTransition>; last?: string; current: string } {
    const current = app.getVersion();
    const last = this.appState.lastVersion ?? loadAppState(path.join(app.getPath("userData"), "app-state.json")).lastVersion;
    return { transition: versionTransition(last, current), last, current };
  }

  recordVersion(): void {
    if (!this.appStatePath) this.appStatePath = path.join(app.getPath("userData"), "app-state.json");
    const state = loadAppState(this.appStatePath);
    this.appState = { ...state, lastVersion: app.getVersion() };
    saveAppState(this.appStatePath, this.appState);
  }

  // ---------------------------------------------------------------- inbox hooks (from InboxMonitor)

  onInboxItems(items: readonly InboxItemSummary[]): void {
    this.items = items;
    this.renderTray();
  }

  onBadge(count: number): void {
    this.count = count;
    this.renderTray();
  }

  onServerEvent(type: string): void {
    if (shouldRefreshRunsForSseEvent(type)) void this.runMonitor.refreshNow();
  }

  showAlert(alert: DesktopAlert): void {
    if (!shouldShowAlert(alert, this.settings.notifications, new Date())) return;
    this.presenter.show(alert, this.settings.notifications, {
      open: (a) => this.openFromNotification(a),
      decide: (a, d) => void this.decideFromNotification(a, d),
      reply: (a, text) => void this.replyFromNotification(a, text),
    });
  }

  private openFromNotification(alert: DesktopAlert): void {
    // Same validated path as an external vesper:// link when the href is one of its shapes.
    const link = hrefToVesperLink(alert.href);
    const parsed = link ? parseVesperLink(link) : null;
    if (parsed?.ok && parsed.target.kind === "navigate") this.ctx.openHref(parsed.target.path);
    else this.ctx.openHref(alert.href);
  }

  private async decideFromNotification(alert: DesktopAlert, decision: "approve" | "deny"): Promise<void> {
    const req = decisionRequest(alert, decision);
    if (!req) return this.openFromNotification(alert);
    if (decision === "approve") {
      const scope = touchIdScopeForKind(alert.kind);
      if (scope && !(await this.confirmTouchId(scope)).ok) {
        this.presenter.notice("Not approved", "Touch ID wasn't confirmed. Open Vesper to decide.", () => this.openFromNotification(alert), true);
        return;
      }
    }
    const res = await apiRequest(this.ctx.fetch, this.ctx.config().serverUrl, req.method, req.path, req.body);
    if (!res.ok) {
      this.presenter.notice(`Couldn't ${decision === "approve" ? "approve" : "decline"}`, res.error ?? "Open Vesper to decide.", () =>
        this.openFromNotification(alert),
      );
    }
  }

  private async replyFromNotification(alert: DesktopAlert, text: string): Promise<void> {
    const req = replyRequest(alert, text);
    if (!req) return this.openFromNotification(alert);
    const res = await apiRequest(this.ctx.fetch, this.ctx.config().serverUrl, req.method, req.path, req.body);
    if (!res.ok) {
      this.presenter.notice("Reply not sent", res.error ?? "Open Vesper to reply.", () => this.openFromNotification(alert));
    }
  }

  // ---------------------------------------------------------------- deep links (LAZYAGENTS-244)

  handleLink(raw: string): void {
    if (!this.ready) {
      if (this.pendingLinks.length < 10) this.pendingLinks.push(raw);
      return;
    }
    if (!this.settings.deepLinks.enabled) {
      console.warn("[vesper] vesper:// links are turned off in Settings; ignored a link");
      return;
    }
    const parsed = parseVesperLink(raw);
    if (!parsed.ok) {
      // Log the reason only, not the link: it came from outside the app.
      console.warn(`[vesper] rejected vesper:// link: ${parsed.reason}`);
      return;
    }
    if (parsed.target.kind === "capture") this.openCapture();
    else this.ctx.openHref(parsed.target.path);
  }

  // ---------------------------------------------------------------- tray (LAZYAGENTS-240)

  private applyTray(): void {
    if (this.settings.tray.enabled) {
      this.tray.ensure();
      this.renderTray();
    } else {
      this.tray.destroy();
      app.dock?.show();
    }
  }

  private renderTray(): void {
    if (!this.tray.active) return;
    this.tray.render(
      {
        health: this.healthValue,
        localStack: this.ctx.stackMode() === "local",
        items: this.items,
        runs: this.runs,
        pausedByVesper: this.pausedByVesper.size,
        quickCapture: { enabled: this.settings.quickCapture.enabled && this.quickCaptureActive, shortcut: this.settings.quickCapture.shortcut },
        screenshot: { enabled: this.settings.screenshot.enabled && this.screenshotActive, shortcut: this.settings.screenshot.shortcut },
        notice: easingOffLabel(this.runnerSlotLimit, this.thermal, this.lowPowerMode) ?? undefined,
      },
      this.count,
      this.settings.tray.showCount,
    );
  }

  private async onTrayAction(action: TrayAction): Promise<void> {
    switch (action.kind) {
      case "open":
        return this.ctx.showMainWindow();
      case "open-href":
        return this.ctx.openHref(action.href);
      case "quick-capture":
        return this.openCapture();
      case "screenshot":
        return this.takeScreenshot();
      case "pause-runs":
        return this.pauseRuns(pausableRuns(this.runs));
      case "resume-runs":
        return this.resumeRuns();
      case "restart-stack":
        return this.restartStack();
      case "show-logs":
        return this.openLogs();
      case "preferences":
        return this.openPreferences();
      case "quit":
        return app.quit();
    }
  }

  /** What the app does when its last window closes. */
  windowAllClosed(): void {
    const action = lastWindowClosedAction(this.settings.tray);
    if (action === "quit" || process.platform !== "darwin") app.quit();
    else if (action === "hide-dock") app.dock?.hide();
  }

  windowOpened(): void {
    if (process.platform === "darwin" && app.dock && !app.dock.isVisible()) void app.dock.show();
  }

  // ---------------------------------------------------------------- runs: pause / resume

  private async pauseRuns(runs: readonly RunSummary[]): Promise<void> {
    const url = this.ctx.config().serverUrl;
    await Promise.all(
      runs.map(async (r) => {
        const res = await apiRequest(this.ctx.fetch, url, "POST", `/api/v1/runs/${encodeURIComponent(r.id)}/pause`);
        if (res.ok) this.pausedByVesper.add(r.id);
      }),
    );
    await this.runMonitor.refreshNow();
  }

  private async resumeRuns(): Promise<void> {
    const url = this.ctx.config().serverUrl;
    await this.runMonitor.refreshNow();
    const ids = runsToResume(this.pausedByVesper, this.runMonitor.live());
    await Promise.all(
      ids.map(async (id) => {
        const res = await apiRequest(this.ctx.fetch, url, "POST", `/api/v1/runs/${encodeURIComponent(id)}/resume`);
        if (res.ok) this.pausedByVesper.delete(id);
      }),
    );
    await this.runMonitor.refreshNow();
  }

  // ---------------------------------------------------------------- login item (LAZYAGENTS-242)

  private applyLoginItem(): void {
    if (process.platform !== "darwin" || !app.isPackaged) return;
    try {
      app.setLoginItemSettings(loginItemSettingsFor(this.settings.login));
    } catch (err) {
      console.warn("[vesper] couldn't update the login item:", err);
    }
  }

  private loginStatus(): string | null {
    if (process.platform !== "darwin") return "Only on macOS.";
    if (!app.isPackaged) return this.settings.login.openAtLogin ? "Only takes effect in the packaged Vesper.app." : null;
    let status: LoginItemStatus = "unknown";
    try {
      status = app.getLoginItemSettings({ type: "mainAppService" }).status as LoginItemStatus;
    } catch {
      status = "unknown";
    }
    return loginStatusMessage(this.settings.login.openAtLogin, status);
  }

  /** A hidden (login) start that failed: say so, since there's no window to show it (LAZYAGENTS-242). */
  hiddenStartFailed(message: string): void {
    this.presenter.notice("Vesper couldn't start", `${message} Click to open Vesper.`, () => this.ctx.showMainWindow());
    this.refreshHealth();
  }

  // ---------------------------------------------------------------- quick capture (LAZYAGENTS-243)

  /** Registers the global shortcuts for Quick Capture and Screenshot to Chat, reporting conflicts. */
  private applyShortcuts(): void {
    for (const acc of this.registeredShortcuts) globalShortcut.unregister(acc);
    this.registeredShortcuts = [];
    const qc = this.settings.quickCapture;
    const ss = this.settings.screenshot;
    const capture = qc.enabled ? this.registerShortcut(qc.shortcut, () => this.openCapture(), null) : { accelerator: null, error: null };
    this.shortcutError = capture.error;
    this.quickCaptureActive = capture.accelerator !== null;
    const shot = ss.enabled
      ? this.registerShortcut(ss.shortcut, () => void this.takeScreenshot(), capture.accelerator)
      : { accelerator: null, error: null };
    this.screenshotError = shot.error;
    this.screenshotActive = shot.accelerator !== null;
    this.renderTray();
  }

  private registerShortcut(raw: string, handler: () => void, usedByCapture: string | null): { accelerator: string | null; error: string | null } {
    const v = validateGlobalShortcut(raw);
    if (!v.ok) return { accelerator: null, error: v.error };
    const label = formatAccelerator(v.accelerator);
    if (usedByCapture && usedByCapture === v.accelerator) return { accelerator: null, error: `Quick Capture already uses ${label}. Pick another shortcut.` };
    const owner = systemShortcutConflict(v.accelerator);
    if (owner) return { accelerator: null, error: `${label} belongs to ${owner}. Pick another shortcut.` };
    if (globalShortcut.isRegistered(v.accelerator)) return { accelerator: null, error: `${label} is already in use. Pick another shortcut.` };
    let ok = false;
    try {
      ok = globalShortcut.register(v.accelerator, handler);
    } catch {
      ok = false;
    }
    if (!ok) return { accelerator: null, error: `${label} is taken by macOS or another app. Pick another shortcut.` };
    this.registeredShortcuts.push(v.accelerator);
    return { accelerator: v.accelerator, error: null };
  }

  openCapture(): void {
    if (this.captureWin && !this.captureWin.isDestroyed()) {
      this.captureWin.show();
      this.captureWin.focus();
      return;
    }
    const win = new BrowserWindow({
      width: 560,
      height: 300,
      show: false,
      frame: false,
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      alwaysOnTop: true,
      skipTaskbar: true,
      title: "Quick Capture",
      backgroundColor: this.ctx.backgroundColor,
      webPreferences: this.webPreferences(),
    });
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    win.on("closed", () => {
      if (this.captureWin === win) this.captureWin = null;
    });
    win.once("ready-to-show", () => {
      win.show();
      win.focus();
    });
    this.captureWin = win;
    void win.loadFile(path.join(this.ctx.rendererDir, "capture.html"));
    if (process.platform === "darwin") app.focus({ steal: true });
  }

  // ---------------------------------------------------------------- screenshot to a chat

  /**
   * Runs the macOS region picker and offers the result to a chat. macOS asks
   * for Screen Recording permission the first time; Escape in the picker
   * cancels without a file, and then nothing happens.
   */
  async takeScreenshot(): Promise<void> {
    if (process.platform !== "darwin") return;
    let dir: string;
    try {
      dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-shot-"));
    } catch {
      return;
    }
    const file = path.join(dir, screenshotFileName(new Date()));
    try {
      await execFileAsync(SCREENCAPTURE_BIN, screencaptureArgs(file), { timeout: 5 * 60_000 });
    } catch {
      // A cancelled capture can exit non-zero; the file check below decides.
    }
    let size = 0;
    try {
      size = fs.statSync(file).size;
    } catch {
      size = 0;
    }
    if (size === 0) {
      fs.rmSync(dir, { recursive: true, force: true });
      if (systemPreferences.getMediaAccessStatus("screen") === "denied") {
        this.presenter.notice(
          "Vesper can't take screenshots",
          "Allow Vesper under System Settings › Privacy & Security › Screen & System Audio Recording, then try again.",
          () => void shell.openExternal("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture").catch(() => {}),
        );
      }
      return;
    }
    this.screenshotDirs.push(dir);
    this.offerFiles([file]);
  }

  private removeScreenshotDirs(): void {
    for (const dir of this.screenshotDirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
  }

  // ---------------------------------------------------------------- open a workspace folder

  /**
   * Shows a native menu (Finder / terminal / editor) for a run's or chat's
   * host-folder workspace. The path comes from the page, so it must resolve
   * inside a live runner's host workspaces directory, and be a folder.
   */
  async openWorkspaceMenu(event: IpcMainInvokeEvent, rawPath: unknown): Promise<{ ok: boolean; error?: string }> {
    const dir = await this.checkedWorkspace(rawPath);
    if (!dir.ok) return dir;
    const ws = this.settings.workspaces;
    const editorLabel = ws.editor.kind === "app" ? ws.editor.app : ws.editor.command.split(" ")[0];
    const pick = (target: OpenTarget) => void this.openWorkspace(dir.path, target);
    const menu = Menu.buildFromTemplate([
      { label: "Open in Finder", click: () => pick("finder") },
      { label: `Open in ${ws.terminalApp}`, click: () => pick("terminal") },
      { label: `Open in ${editorLabel}`, click: () => pick("editor") },
    ]);
    const win = BrowserWindow.fromWebContents(event.sender);
    menu.popup(win ? { window: win } : {});
    return { ok: true };
  }

  private async checkedWorkspace(rawPath: unknown): Promise<{ ok: true; path: string } | { ok: false; error: string }> {
    if (typeof rawPath !== "string" || !path.isAbsolute(rawPath) || rawPath.length > 2048) return { ok: false, error: "Not a workspace folder." };
    const status = await apiRequest<{ runners?: Array<{ host_workspaces_dir?: string }> }>(
      this.ctx.fetch,
      this.ctx.config().serverUrl,
      "GET",
      "/api/v1/runner",
      undefined,
      { timeoutMs: 4000 },
    );
    const roots = (status.data?.runners ?? [])
      .map((r) => r.host_workspaces_dir)
      .filter((d): d is string => typeof d === "string" && path.isAbsolute(d))
      .map((d) => {
        try {
          return fs.realpathSync(d);
        } catch {
          return "";
        }
      })
      .filter(Boolean);
    let real: string;
    try {
      real = fs.realpathSync(rawPath);
      if (!fs.statSync(real).isDirectory()) return { ok: false, error: "That folder isn't there any more." };
    } catch {
      return { ok: false, error: "That folder isn't on this Mac." };
    }
    if (!isInsideRoots(real, roots)) return { ok: false, error: "Only run and chat workspace folders can be opened." };
    return { ok: true, path: real };
  }

  private async openWorkspace(dir: string, target: OpenTarget): Promise<void> {
    const cmd = openCommand(target, dir, this.settings.workspaces);
    try {
      if (!cmd) {
        const err = await shell.openPath(dir);
        if (err) throw new Error(err);
      } else {
        await execFileAsync(cmd.file, cmd.args, { timeout: 15_000 });
      }
    } catch (err) {
      this.presenter.notice("Couldn't open the folder", err instanceof Error ? err.message.slice(0, 200) : String(err), undefined, true);
    }
  }

  // ---------------------------------------------------------------- easing off when hot

  private setupThermal(): void {
    try {
      const state = powerMonitor.getCurrentThermalState();
      if (isThermalState(state)) this.thermal = state;
    } catch {
      this.thermal = "unknown";
    }
    powerMonitor.on("thermal-state-change", (details) => {
      if (isThermalState(details.state)) this.thermal = details.state;
      void this.applySlotLimit();
    });
    if (process.platform === "darwin") {
      void this.readLowPowerMode();
      this.lowPowerTimer = setInterval(() => void this.readLowPowerMode(), 60_000);
    }
  }

  private async readLowPowerMode(): Promise<void> {
    try {
      const { stdout } = await execFileAsync("/usr/bin/pmset", ["-g"], { timeout: 5000 });
      const next = parseLowPowerMode(stdout);
      if (next !== this.lowPowerMode) {
        this.lowPowerMode = next;
        void this.applySlotLimit();
      }
    } catch {
      // pmset missing or failed: treat as off.
    }
  }

  /** Asks the local runner for fewer slots while hot, and lifts the cap after. Local stack only. */
  private async applySlotLimit(): Promise<void> {
    if (this.ctx.stackMode() !== "local" || !this.ctx.stackSnapshot().running || this.runnerMaxSlots < 1) return;
    const desired = desiredSlotLimit({
      enabled: this.settings.power.easeOffWhenHot,
      thermal: this.thermal,
      lowPowerMode: this.lowPowerMode,
      maxSlots: this.runnerMaxSlots,
    });
    if (desired === this.runnerSlotLimit) return;
    const res = await apiRequest<{ runners?: Array<{ slot_limit?: number }> }>(
      this.ctx.fetch,
      this.ctx.config().serverUrl,
      "PUT",
      "/api/v1/runner/slot-limit",
      { limit: desired },
    );
    if (res.ok) {
      this.runnerSlotLimit = desired;
      this.renderTray();
    }
  }

  // ---------------------------------------------------------------- backups

  /** Keeps rebuildable folders (VM disks, caches, images) out of Time Machine, or puts them back. */
  private async applyTimeMachine(): Promise<void> {
    if (process.platform !== "darwin" || this.ctx.stackMode() !== "local") return;
    const exclude = this.settings.backups.excludeFromTimeMachine;
    let all = true;
    for (const dir of timeMachineTargets(app.getPath("userData"))) {
      try {
        fs.mkdirSync(dir, { recursive: true });
        // Without -p this is a sticky exclusion on the folder itself (an xattr): no admin rights needed.
        await execFileAsync("/usr/bin/tmutil", [exclude ? "addexclusion" : "removeexclusion", dir], { timeout: 15_000 });
        const { stdout } = await execFileAsync("/usr/bin/tmutil", ["isexcluded", dir], { timeout: 15_000 });
        if (parseIsExcluded(stdout) !== true) all = false;
      } catch (err) {
        all = false;
        console.warn("[vesper] tmutil failed:", err instanceof Error ? err.message : err);
      }
    }
    this.timeMachineExcluded = all;
  }

  private scheduleExport(delayMs: number): void {
    if (this.exportTimer) clearTimeout(this.exportTimer);
    this.exportTimer = setTimeout(() => {
      void this.runExportIfDue().finally(() => this.scheduleExport(30 * 60_000));
    }, delayMs);
  }

  private async runExportIfDue(): Promise<void> {
    const exp = this.settings.backups.export;
    if (!exp.enabled || !exp.folder) return;
    if (!isExportDue(this.appState.lastExportAt, Date.now(), exp.everyHours)) return;
    const failingAlready = Boolean(this.appState.lastExportError);
    const result = await this.exportNow();
    // A failing export retries every 30 minutes; say so once, not on every retry.
    if (!result.ok && !failingAlready) {
      this.presenter.notice("Scheduled export failed", result.error ?? "Open Settings › Backups to see why.", () => this.openPreferences());
    }
  }

  /**
   * Streams GET /api/v1/instance/export into the export folder (as .part,
   * renamed when complete), then deletes Vesper's own exports beyond `keep`.
   */
  async exportNow(): Promise<{ ok: boolean; file?: string; error?: string }> {
    const exp = this.settings.backups.export;
    if (!exp.folder) return { ok: false, error: "Choose a folder first." };
    if (this.exporting) return { ok: false, error: "An export is already running." };
    this.exporting = true;
    const final = path.join(exp.folder, exportFileName(new Date()));
    const part = `${final}.part`;
    try {
      if (!fs.statSync(exp.folder).isDirectory()) throw new Error("The export folder isn't a folder.");
      const res = await this.ctx.fetch(`${this.ctx.config().serverUrl.replace(/\/+$/, "")}/api/v1/instance/export`, { method: "GET" });
      if (!res.ok || !res.body) throw new Error(`The server answered ${res.status}.`);
      await pipeline(Readable.fromWeb(res.body as unknown as NodeReadableStream<Uint8Array>), fs.createWriteStream(part, { mode: 0o600 }));
      fs.renameSync(part, final);
      for (const name of exportsToPrune(fs.readdirSync(exp.folder), exp.keep)) {
        fs.rmSync(path.join(exp.folder, name), { force: true });
      }
      this.appState = { ...this.appState, lastExportAt: Date.now(), lastExportError: undefined };
      saveAppState(this.appStatePath, this.appState);
      return { ok: true, file: final };
    } catch (err) {
      fs.rmSync(part, { force: true });
      const message = err instanceof Error ? err.message : String(err);
      this.appState = { ...this.appState, lastExportError: message.slice(0, 300) };
      saveAppState(this.appStatePath, this.appState);
      return { ok: false, error: message };
    } finally {
      this.exporting = false;
    }
  }

  // ---------------------------------------------------------------- power (LAZYAGENTS-245)

  private setupPower(): void {
    powerMonitor.on("suspend", () => void this.onSuspend());
    powerMonitor.on("resume", () => void this.onResume());
    powerMonitor.on("on-battery", () => this.onBattery(true));
    powerMonitor.on("on-ac", () => this.onBattery(false));
    this.setupThermal();
  }

  private async onSuspend(): Promise<void> {
    const toPause = runsToPauseOnSleep(this.settings.power, this.runMonitor.live());
    if (toPause.length > 0) await this.pauseRuns(toPause);
  }

  private async onResume(): Promise<void> {
    if (this.settings.power.onSleep === "pause" && this.pausedByVesper.size > 0) await this.resumeRuns();
    void this.runMonitor.refreshNow();
    // The stack may have died while asleep; health and auto-restart take it from here.
    this.refreshHealth();
  }

  private onBattery(onBattery: boolean): void {
    if (!onBattery) {
      this.batteryWarned = false;
      return;
    }
    if (this.batteryWarned) return;
    const msg = batteryWarning(this.settings.power, true, this.runMonitor.live());
    if (msg) {
      this.batteryWarned = true;
      this.presenter.notice("Running on battery", msg, () => this.ctx.openHref("/runs"), true);
    }
  }

  private updatePowerBlocker(): void {
    if (wantsSleepBlocker(this.settings.power, this.runs)) {
      if (this.sleepBlockerId === null || !powerSaveBlocker.isStarted(this.sleepBlockerId)) {
        // prevent-app-suspension keeps the system from idle-sleeping; the display may still sleep.
        this.sleepBlockerId = powerSaveBlocker.start("prevent-app-suspension");
      }
    } else {
      this.releaseBlocker();
    }
  }

  private releaseBlocker(): void {
    if (this.sleepBlockerId !== null) {
      if (powerSaveBlocker.isStarted(this.sleepBlockerId)) powerSaveBlocker.stop(this.sleepBlockerId);
      this.sleepBlockerId = null;
    }
  }

  quitNeedsConfirm(stackRunning: boolean, hasActiveRuns: boolean): boolean {
    return shouldConfirmQuit(this.settings.power, stackRunning, hasActiveRuns);
  }

  // ---------------------------------------------------------------- stack health (LAZYAGENTS-246)

  health(): StackHealth {
    return this.healthValue;
  }

  onHealth(listener: HealthListener): () => void {
    this.healthListeners.add(listener);
    return () => this.healthListeners.delete(listener);
  }

  refreshHealth(): void {
    const snap = this.ctx.stackSnapshot();
    const next = deriveStackHealth({
      mode: this.ctx.stackMode(),
      platform: process.platform,
      arch: process.arch,
      darwinMajor: process.platform === "darwin" ? darwinMajor(os.release()) : undefined,
      starting: snap.starting,
      processRunning: snap.running,
      startError: snap.startError,
      exit: snap.running ? undefined : (snap.exit ?? undefined),
      freeDiskBytes: freeDiskBytes(app.getPath("userData")),
      minFreeDiskGb: this.settings.stack.minFreeDiskGb,
      image: this.image,
      runnerOnline: this.runnerOnline,
      reachable: this.ctx.connectionReachable(),
    });
    const changed = JSON.stringify(next) !== JSON.stringify(this.healthValue);
    this.healthValue = next;
    if (changed) {
      this.renderTray();
      for (const l of this.healthListeners) l(next);
      for (const win of BrowserWindow.getAllWindows()) {
        if (!win.isDestroyed()) win.webContents.send("vesper:health", next);
      }
    }
  }

  private scheduleHealth(delayMs: number): void {
    if (this.healthTimer) clearTimeout(this.healthTimer);
    this.healthTimer = setTimeout(() => void this.pollHealth(), delayMs);
  }

  private async pollHealth(): Promise<void> {
    if (this.ctx.stackMode() === "local" && this.ctx.stackSnapshot().running) {
      const url = this.ctx.config().serverUrl;
      const [img, runner] = await Promise.all([
        apiRequest<RootfsStatus>(this.ctx.fetch, url, "GET", "/api/v1/system/vm-image", undefined, { timeoutMs: 3000 }),
        apiRequest<{ online?: boolean; runners?: Array<{ max_concurrent?: number; slot_limit?: number }> }>(
          this.ctx.fetch,
          url,
          "GET",
          "/api/v1/runner",
          undefined,
          { timeoutMs: 3000 },
        ),
      ]);
      this.image = img.ok ? img.data : undefined;
      this.runnerOnline = runner.ok && typeof runner.data?.online === "boolean" ? runner.data.online : undefined;
      const first = runner.data?.runners?.[0];
      if (runner.ok && first) {
        this.runnerMaxSlots = typeof first.max_concurrent === "number" ? first.max_concurrent : 0;
        // What the server holds, so a restarted (uncapped) runner gets the cap again below.
        this.runnerSlotLimit = typeof first.slot_limit === "number" ? first.slot_limit : null;
        void this.applySlotLimit();
      }
      if (this.timeMachineExcluded === null) void this.applyTimeMachine();
    } else {
      this.image = undefined;
      this.runnerOnline = undefined;
    }
    this.refreshHealth();
    const fast = this.healthValue.phase === "starting" || this.healthValue.phase === "downloading";
    this.scheduleHealth(fast ? 2000 : 15_000);
  }

  /** The bundled stack exited on its own. Restart it (bounded) or report it. */
  stackCrashed(exit: StackExit): void {
    this.refreshHealth();
    const now = Date.now();
    if (this.settings.stack.autoRestart && shouldAutoRestart(this.restartTimes, now)) {
      this.restartTimes = [...this.restartTimes.filter((t) => now - t < 10 * 60_000), now];
      console.warn(`[vesper] stack exited (${exit.code ?? exit.signal}); restarting`);
      void this.restartStack();
      return;
    }
    this.presenter.notice(this.healthValue.title, this.healthValue.nextStep || "Open Vesper to restart it.", () => this.openLogs());
  }

  async restartStack(): Promise<void> {
    try {
      await this.ctx.restartStack();
    } finally {
      this.scheduleHealth(0);
    }
  }

  openLogs(): void {
    if (this.logsWin && !this.logsWin.isDestroyed()) {
      this.logsWin.focus();
      return;
    }
    const win = new BrowserWindow({
      width: 860,
      height: 600,
      minWidth: 560,
      minHeight: 360,
      title: "Vesper Logs",
      backgroundColor: this.ctx.backgroundColor,
      webPreferences: this.webPreferences(),
    });
    win.on("closed", () => {
      if (this.logsWin === win) this.logsWin = null;
    });
    this.logsWin = win;
    void win.loadFile(path.join(this.ctx.rendererDir, "logs.html"));
  }

  // ---------------------------------------------------------------- files (LAZYAGENTS-247)

  /** A file opened with Vesper or dropped on its Dock icon (app "open-file"). */
  handleOpenFile(filePath: string): boolean {
    if (this.ready && !this.settings.files.dockDrop) return false;
    if (this.pendingFiles.length < 50) this.pendingFiles.push(filePath);
    if (!this.ready) return true;
    // macOS sends one open-file per file; gather a multi-file drop into one picker.
    if (this.fileTimer) clearTimeout(this.fileTimer);
    this.fileTimer = setTimeout(() => this.flushFiles(), 250);
    return true;
  }

  /** A file dropped on a window outside the composer arrives as a file:// navigation; route it here instead. */
  handleDroppedFileUrl(fileUrl: string): boolean {
    if (!this.settings.files.dockDrop) return false;
    try {
      return this.handleOpenFile(fileURLToPath(fileUrl));
    } catch {
      return false;
    }
  }

  private flushFiles(): void {
    const paths = [...new Set(this.pendingFiles.splice(0))];
    if (!this.settings.files.dockDrop || paths.length === 0) return;
    this.offerFiles(paths);
  }

  /** Opens (or refreshes) the Send to Vesper picker for these files. */
  private offerFiles(paths: readonly string[]): void {
    const stats = paths.map((p) => {
      try {
        const st = fs.statSync(p);
        return { path: p, size: st.size, isFile: st.isFile() };
      } catch {
        return { path: p, size: 0, isFile: false };
      }
    });
    this.sendFiles = classifyDroppedFiles(stats);
    if (this.sendWin && !this.sendWin.isDestroyed()) {
      this.sendWin.webContents.reload();
      this.sendWin.focus();
      return;
    }
    const win = new BrowserWindow({
      width: 560,
      height: 520,
      resizable: false,
      minimizable: false,
      maximizable: false,
      title: "Send to Vesper",
      backgroundColor: this.ctx.backgroundColor,
      webPreferences: this.webPreferences(),
    });
    win.on("closed", () => {
      if (this.sendWin === win) this.sendWin = null;
      // Screenshots exist only to be sent; once the picker is gone, so are they.
      this.removeScreenshotDirs();
    });
    this.sendWin = win;
    void win.loadFile(path.join(this.ctx.rendererDir, "send-files.html"));
    if (process.platform === "darwin") app.focus({ steal: true });
  }

  private async uploadAndSend(input: { target: string; personaId?: string; message?: string }): Promise<{ ok: boolean; error?: string }> {
    const url = this.ctx.config().serverUrl;
    const ids: string[] = [];
    for (const file of this.sendFiles.accepted) {
      let data: Buffer;
      try {
        data = fs.readFileSync(file.path);
      } catch {
        return { ok: false, error: `Couldn't read ${file.name}.` };
      }
      const { body, contentType } = buildMultipartBody(file.name, file.mime, data);
      const res = await apiRequest<{ id?: string }>(this.ctx.fetch, url, "POST", "/api/v1/chat-attachments", undefined, {
        rawBody: { data: body, contentType },
        timeoutMs: 120_000,
      });
      if (!res.ok || typeof res.data?.id !== "string") return { ok: false, error: `${file.name}: ${res.error ?? "upload failed"}` };
      ids.push(res.data.id);
    }
    const req = buildSendFilesRequest({ ...input, attachmentIds: ids });
    if (!req.ok) return { ok: false, error: req.error };
    const res = await apiRequest<{ id?: string; chat?: { id?: string } }>(this.ctx.fetch, url, "POST", req.path, req.body);
    if (!res.ok) return { ok: false, error: res.error };
    const chatId = input.target === "new" ? res.data?.id : input.target;
    const href = chatId ? captureResultHref("message", { id: chatId }) : null;
    this.sendFiles = { accepted: [], rejected: [] };
    this.sendWin?.close();
    this.ctx.openHref(href ?? "/chat");
    return { ok: true };
  }

  // ---------------------------------------------------------------- Touch ID (LAZYAGENTS-248)

  /**
   * Prompts for Touch ID when the setting asks for it in this scope. A local
   * gate only: the server never sees the result.
   */
  async confirmTouchId(scope: TouchIdScope): Promise<{ ok: boolean; prompted: boolean; error?: string }> {
    const canPrompt = process.platform === "darwin" && systemPreferences.canPromptTouchID();
    if (touchIdDecision(this.settings.touchId, scope, canPrompt) === "skip") return { ok: true, prompted: false };
    try {
      await systemPreferences.promptTouchID(touchIdReason(scope));
      return { ok: true, prompted: true };
    } catch (err) {
      // Fail closed: the person turned this on, so a cancelled or failed prompt doesn't approve.
      return { ok: false, prompted: true, error: err instanceof Error ? err.message : "Touch ID wasn't confirmed." };
    }
  }

  // ---------------------------------------------------------------- updates (LAZYAGENTS-249)

  private scheduleUpdateCheck(delayMs: number): void {
    if (this.updateTimer) clearTimeout(this.updateTimer);
    this.updateTimer = setTimeout(() => {
      void this.checkForUpdates(false).finally(() => this.scheduleUpdateCheck(6 * 60 * 60 * 1000));
    }, delayMs);
  }

  async checkForUpdates(manual: boolean): Promise<{ status: "none" | "available" | "error" | "off"; version?: string; error?: string }> {
    if (!manual && !this.settings.updates.checkEnabled) return { status: "off" };
    if (!manual && !isCheckDue(this.appState.lastUpdateCheckAt, Date.now())) return { status: "none" };
    const feedUrl = this.settings.updates.feedUrl;
    let release: unknown;
    try {
      // net.fetch uses the system proxy settings; the feed is public, so no session cookies.
      const res = await net.fetch(feedUrl, {
        headers: { Accept: "application/vnd.github+json", "User-Agent": `Vesper-Desktop/${app.getVersion()}` },
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) throw new Error(`The release feed answered ${res.status}.`);
      release = await res.json();
    } catch (err) {
      return { status: "error", error: err instanceof Error ? err.message : String(err) };
    } finally {
      this.appState = { ...this.appState, lastUpdateCheckAt: Date.now() };
      saveAppState(this.appStatePath, this.appState);
    }
    const update = pickUpdate(app.getVersion(), feedUrl, release);
    if (!update) return { status: "none" };
    if (manual || this.appState.announcedUpdate !== update.version) {
      this.appState = { ...this.appState, announcedUpdate: update.version };
      saveAppState(this.appStatePath, this.appState);
      this.presenter.notice(
        `Vesper ${update.version} is available`,
        "Click to open the download page. Drag the new Vesper.app into Applications; your data stays where it is.",
        () => void shell.openExternal(update.url).catch(() => {}),
      );
    }
    return { status: "available", version: update.version };
  }

  // ---------------------------------------------------------------- preferences

  openPreferences(): void {
    if (this.prefsWin && !this.prefsWin.isDestroyed()) {
      this.prefsWin.focus();
      return;
    }
    const win = new BrowserWindow({
      width: 760,
      height: 640,
      minWidth: 680,
      minHeight: 520,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      title: "Vesper Settings",
      backgroundColor: this.ctx.backgroundColor,
      webPreferences: this.webPreferences(),
    });
    win.on("closed", () => {
      if (this.prefsWin === win) this.prefsWin = null;
    });
    this.prefsWin = win;
    void win.loadFile(path.join(this.ctx.rendererDir, "preferences.html"));
  }

  private prefsState() {
    const canTouchId = process.platform === "darwin" && systemPreferences.canPromptTouchID();
    return {
      settings: this.settings,
      status: {
        platform: process.platform,
        packaged: app.isPackaged,
        appVersion: app.getVersion(),
        login: this.loginStatus(),
        shortcut: this.shortcutError,
        shortcutLabel: formatAccelerator(this.settings.quickCapture.shortcut),
        screenshot: this.screenshotError,
        screenshotLabel: formatAccelerator(this.settings.screenshot.shortcut),
        timeMachineExcluded: this.timeMachineExcluded,
        lastExportAt: this.appState.lastExportAt ?? null,
        lastExportError: this.appState.lastExportError ?? null,
        exporting: this.exporting,
        easingOff: easingOffLabel(this.runnerSlotLimit, this.thermal, this.lowPowerMode),
        touchIdAvailable: canTouchId,
        servicesInstalled: servicesInstalled(),
        servicesAvailable: Boolean(appBundlePath(process.execPath)),
        lastUpdateCheckAt: this.appState.lastUpdateCheckAt ?? null,
        localStack: this.ctx.stackMode() === "local",
        dataDir: app.getPath("userData"),
      },
    };
  }

  private applySettings(patch: unknown): { ok: boolean; error?: string; state: ReturnType<NativeFeatures["prefsState"]> } {
    const before = this.settings;
    const next = applyNativeSettingsPatch(before, patch);
    for (const key of ["quickCapture", "screenshot"] as const) {
      if (!next[key].enabled) continue;
      const v = validateGlobalShortcut(next[key].shortcut);
      if (!v.ok) return { ok: false, error: v.error, state: this.prefsState() };
      next[key].shortcut = v.accelerator;
    }
    this.ctx.saveNative(next);
    const changed = (k: keyof NativeSettings) => JSON.stringify(before[k]) !== JSON.stringify(next[k]);
    if (changed("tray")) this.applyTray();
    if (changed("login")) this.applyLoginItem();
    if (changed("quickCapture") || changed("screenshot")) this.applyShortcuts();
    if (changed("power")) {
      this.updatePowerBlocker();
      void this.applySlotLimit();
    }
    if (changed("stack")) this.refreshHealth();
    if (before.backups.excludeFromTimeMachine !== next.backups.excludeFromTimeMachine) void this.applyTimeMachine();
    if (JSON.stringify(before.backups.export) !== JSON.stringify(next.backups.export)) this.scheduleExport(5000);
    if (!before.updates.checkEnabled && next.updates.checkEnabled) this.scheduleUpdateCheck(1000);
    this.renderTray();
    const error =
      (next.quickCapture.enabled && changed("quickCapture") ? this.shortcutError : null) ??
      (next.screenshot.enabled && changed("screenshot") ? this.screenshotError : null) ??
      undefined;
    return { ok: !error, ...(error ? { error } : {}), state: this.prefsState() };
  }

  // ---------------------------------------------------------------- IPC

  private webPreferences(): Electron.WebPreferences {
    return {
      partition: this.ctx.partition,
      preload: this.ctx.preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    };
  }

  private trusted(event: IpcMainInvokeEvent): void {
    if (!this.ctx.isTrustedRendererUrl(event.senderFrame?.url)) throw new Error("Untrusted IPC caller");
  }

  /** The Vesper web app itself (same origin as the server URL): Touch ID on approvals, opening workspace folders. */
  private fromVesperOrigin(event: IpcMainInvokeEvent): boolean {
    try {
      const frameUrl = event.senderFrame?.url;
      if (!frameUrl) return false;
      return new URL(frameUrl).origin === new URL(this.ctx.config().serverUrl).origin;
    } catch {
      return false;
    }
  }

  private registerIpc(): void {
    const handle = (channel: string, fn: (event: IpcMainInvokeEvent, ...args: any[]) => unknown) => {
      ipcMain.handle(channel, (event, ...args) => {
        this.trusted(event);
        return fn(event, ...args);
      });
    };

    handle("vesper:prefs-get", () => this.prefsState());
    handle("vesper:prefs-set", (_e, patch: unknown) => this.applySettings(patch));
    handle("vesper:prefs-services", (_e, install: unknown) => {
      const bundle = appBundlePath(process.execPath);
      if (!bundle) return { ok: false, error: "Quick Actions need the packaged Vesper.app.", state: this.prefsState() };
      try {
        if (install === true) installServices(bundle);
        else uninstallServices();
        return { ok: true, state: this.prefsState() };
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err), state: this.prefsState() };
      }
    });
    handle("vesper:prefs-check-updates", () => this.checkForUpdates(true));
    handle("vesper:prefs-test-notification", () => {
      this.presenter.notice("Vesper notifications are on", "This is what an alert looks like.", undefined, !this.settings.notifications.sound);
    });
    handle("vesper:prefs-test-touch-id", async () => {
      if (!(process.platform === "darwin" && systemPreferences.canPromptTouchID())) return { ok: false, error: "Touch ID isn't available on this Mac." };
      try {
        await systemPreferences.promptTouchID("test Touch ID for approvals");
        return { ok: true };
      } catch (err) {
        return { ok: false, error: err instanceof Error ? err.message : String(err) };
      }
    });
    handle("vesper:open-server-settings", () => this.ctx.openServerSettings());
    handle("vesper:prefs-pick-export-folder", async (event) => {
      const win = BrowserWindow.fromWebContents(event.sender);
      const opts: Electron.OpenDialogOptions = { title: "Choose a Folder for Vesper Exports", properties: ["openDirectory", "createDirectory"] };
      const res = win ? await dialog.showOpenDialog(win, opts) : await dialog.showOpenDialog(opts);
      if (res.canceled || res.filePaths.length === 0) return { ok: true, state: this.prefsState() };
      return this.applySettings({ backups: { export: { folder: res.filePaths[0] } } });
    });
    handle("vesper:prefs-export-now", async () => {
      const result = await this.exportNow();
      return { ...result, state: this.prefsState() };
    });
    handle("vesper:open-data-dir", () => void shell.openPath(app.getPath("userData")));

    handle("vesper:capture-options", async () => {
      const url = this.ctx.config().serverUrl;
      const [personas, projects] = await Promise.all([
        apiRequest<{ personas?: Array<{ id: string; name: string }>; default_persona_id?: string }>(this.ctx.fetch, url, "GET", "/api/v1/personas"),
        apiRequest<Array<{ key: string; name: string; archived?: boolean }>>(this.ctx.fetch, url, "GET", "/api/v1/projects"),
      ]);
      return {
        reachable: personas.ok || projects.ok,
        personas: (personas.data?.personas ?? []).map((p) => ({ id: p.id, name: p.name })),
        defaultPersonaId: personas.data?.default_persona_id ?? "",
        projects: (Array.isArray(projects.data) ? projects.data : []).filter((p) => !p.archived).map((p) => ({ key: p.key, name: p.name })),
        shortcut: formatAccelerator(this.settings.quickCapture.shortcut),
      };
    });
    handle("vesper:capture-submit", async (_e, input: CaptureInput & { open?: boolean }) => {
      const built = buildCaptureRequest(input);
      if (!built.ok) return { ok: false, error: built.error };
      const res = await apiRequest(this.ctx.fetch, this.ctx.config().serverUrl, built.request.method, built.request.path, built.request.body);
      if (!res.ok) return { ok: false, error: res.error };
      const href = captureResultHref(input.kind as CaptureKind, res.data);
      this.captureWin?.close();
      if (input.open && href) this.ctx.openHref(href);
      return { ok: true };
    });
    handle("vesper:close-window", (event) => {
      BrowserWindow.fromWebContents(event.sender)?.close();
    });

    handle("vesper:send-files-get", async () => {
      const url = this.ctx.config().serverUrl;
      const [chats, personas] = await Promise.all([
        apiRequest<{ chats?: Array<{ id: string; title: string }> }>(this.ctx.fetch, url, "GET", "/api/v1/chats?persona_id=all"),
        apiRequest<{ personas?: Array<{ id: string; name: string }>; default_persona_id?: string }>(this.ctx.fetch, url, "GET", "/api/v1/personas"),
      ]);
      return {
        files: this.sendFiles.accepted.map((f) => ({ name: f.name, size: f.size })),
        rejected: this.sendFiles.rejected,
        chats: (chats.data?.chats ?? []).slice(0, 15).map((c) => ({ id: c.id, title: c.title })),
        personas: (personas.data?.personas ?? []).map((p) => ({ id: p.id, name: p.name })),
        defaultPersonaId: personas.data?.default_persona_id ?? "",
      };
    });
    handle("vesper:send-files-submit", (_e, input: { target: string; personaId?: string; message?: string }) =>
      this.uploadAndSend({
        target: typeof input?.target === "string" ? input.target : "",
        personaId: typeof input?.personaId === "string" ? input.personaId : undefined,
        message: typeof input?.message === "string" ? input.message : undefined,
      }),
    );

    handle("vesper:get-health", () => this.healthValue);
    handle("vesper:logs-get", () => ({ text: readLogTail(this.logsPath, 256 * 1024), path: this.logsPath }));
    handle("vesper:logs-reveal", () => {
      if (fs.existsSync(this.logsPath)) shell.showItemInFolder(this.logsPath);
      else void shell.openPath(path.dirname(this.logsPath));
    });
    handle("vesper:logs-copy", () => {
      clipboard.writeText(readLogTail(this.logsPath, 256 * 1024));
    });
    handle("vesper:stack-restart", () => this.restartStack());
    handle("vesper:open-logs", () => this.openLogs());

    // From the Vesper web app (not file://): a menu to open a workspace folder.
    ipcMain.handle("vesper:open-workspace-menu", (event, folder: unknown) => {
      if (!this.fromVesperOrigin(event)) throw new Error("Untrusted IPC caller");
      return this.openWorkspaceMenu(event, folder);
    });

    // From the Vesper web app (not file://): Touch ID before approving.
    ipcMain.handle("vesper:confirm-approval", async (event, scope: unknown) => {
      if (!this.fromVesperOrigin(event)) throw new Error("Untrusted IPC caller");
      if (!isTouchIdScope(scope)) return { ok: true, prompted: false };
      return this.confirmTouchId(scope);
    });
  }
}
