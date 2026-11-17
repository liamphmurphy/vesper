import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  app,
  BrowserWindow,
  clipboard,
  globalShortcut,
  ipcMain,
  net,
  powerMonitor,
  powerSaveBlocker,
  shell,
  systemPreferences,
  type IpcMainInvokeEvent,
} from "electron";
import { apiRequest, type FetchFn } from "./api";
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
  private registeredShortcut: string | null = null;
  private shortcutError: string | null = null;
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
    this.applyQuickCapture();
    this.setupPower();
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
        quickCapture: { enabled: this.settings.quickCapture.enabled && this.registeredShortcut !== null, shortcut: this.settings.quickCapture.shortcut },
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

  private applyQuickCapture(): string | null {
    if (this.registeredShortcut) {
      globalShortcut.unregister(this.registeredShortcut);
      this.registeredShortcut = null;
    }
    this.shortcutError = null;
    const qc = this.settings.quickCapture;
    if (!qc.enabled) {
      this.renderTray();
      return null;
    }
    const v = validateGlobalShortcut(qc.shortcut);
    if (!v.ok) {
      this.shortcutError = v.error;
    } else {
      const owner = systemShortcutConflict(v.accelerator);
      if (owner) {
        this.shortcutError = `${formatAccelerator(v.accelerator)} belongs to ${owner}. Pick another shortcut.`;
      } else if (globalShortcut.isRegistered(v.accelerator)) {
        this.shortcutError = `${formatAccelerator(v.accelerator)} is already in use. Pick another shortcut.`;
      } else {
        let ok = false;
        try {
          ok = globalShortcut.register(v.accelerator, () => this.openCapture());
        } catch {
          ok = false;
        }
        if (ok) this.registeredShortcut = v.accelerator;
        else this.shortcutError = `${formatAccelerator(v.accelerator)} is taken by macOS or another app. Pick another shortcut.`;
      }
    }
    this.renderTray();
    return this.shortcutError;
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

  // ---------------------------------------------------------------- power (LAZYAGENTS-245)

  private setupPower(): void {
    powerMonitor.on("suspend", () => void this.onSuspend());
    powerMonitor.on("resume", () => void this.onResume());
    powerMonitor.on("on-battery", () => this.onBattery(true));
    powerMonitor.on("on-ac", () => this.onBattery(false));
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
        apiRequest<{ online?: boolean }>(this.ctx.fetch, url, "GET", "/api/v1/runner", undefined, { timeoutMs: 3000 }),
      ]);
      this.image = img.ok ? img.data : undefined;
      this.runnerOnline = runner.ok && typeof runner.data?.online === "boolean" ? runner.data.online : undefined;
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
    if (next.quickCapture.enabled) {
      const v = validateGlobalShortcut(next.quickCapture.shortcut);
      if (!v.ok) return { ok: false, error: v.error, state: this.prefsState() };
      next.quickCapture.shortcut = v.accelerator;
    }
    this.ctx.saveNative(next);
    if (JSON.stringify(before.tray) !== JSON.stringify(next.tray)) this.applyTray();
    if (JSON.stringify(before.login) !== JSON.stringify(next.login)) this.applyLoginItem();
    if (JSON.stringify(before.quickCapture) !== JSON.stringify(next.quickCapture)) this.applyQuickCapture();
    if (JSON.stringify(before.power) !== JSON.stringify(next.power)) this.updatePowerBlocker();
    if (JSON.stringify(before.stack) !== JSON.stringify(next.stack)) this.refreshHealth();
    if (!before.updates.checkEnabled && next.updates.checkEnabled) this.scheduleUpdateCheck(1000);
    this.renderTray();
    const error = next.quickCapture.enabled ? (this.shortcutError ?? undefined) : undefined;
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

  /** The Vesper web app itself (same origin as the server URL), for Touch ID on approvals. */
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

    // From the Vesper web app (not file://): Touch ID before approving.
    ipcMain.handle("vesper:confirm-approval", async (event, scope: unknown) => {
      if (!this.fromVesperOrigin(event)) throw new Error("Untrusted IPC caller");
      if (!isTouchIdScope(scope)) return { ok: true, prompted: false };
      return this.confirmTouchId(scope);
    });
  }
}
