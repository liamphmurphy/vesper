import { contextBridge, ipcRenderer } from "electron";

export type ConnectionPhase = "checking" | "reachable" | "unreachable";

export interface DockerStatusInfo {
  available: boolean;
  runtime: "orbstack" | "docker" | "none";
  detail?: string;
}

export interface DesktopConnectionState {
  serverUrl: string;
  targetUrl: string;
  phase: ConnectionPhase;
  errorMessage?: string;
  lastCheckedAt?: string;
  localCheckoutPath?: string;
  isLocalhost: boolean;
  docker?: DockerStatusInfo;
  stackStarting?: boolean;
}

export interface SetServerUrlInput {
  serverUrl: string;
  localCheckoutPath?: string;
}

export interface SetServerUrlResult {
  ok: boolean;
  error?: string;
  state: DesktopConnectionState;
}

export interface StartStackResult {
  ok: boolean;
  error?: string;
}

export interface BackupInspection {
  exportedAt: string;
  appVersion: string;
  schemaVersion: number;
  tableCount: number;
  totalRows: number;
  objectCount: number;
  secretsKeyFingerprint?: string;
  encryptedSecretRows: number;
  matchesCurrentKey: boolean;
}

export interface PickBackupResult {
  archivePath: string;
  inspection?: BackupInspection;
  error?: string;
}

export interface ImportBackupInput {
  archivePath: string;
  secretsKey?: string;
  dropSecrets?: boolean;
}

export interface ImportBackupResult {
  ok: boolean;
  error?: string;
}

const api = {
  getState: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:get-state"),
  retryConnection: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:retry-connection"),
  setServerUrl: (input: SetServerUrlInput): Promise<SetServerUrlResult> =>
    ipcRenderer.invoke("vesper:set-server-url", input),
  pickCheckoutFolder: (): Promise<string | null> => ipcRenderer.invoke("vesper:pick-checkout-folder"),
  pickBackupArchive: (): Promise<PickBackupResult | null> => ipcRenderer.invoke("vesper:pick-backup-archive"),
  importBackup: (input: ImportBackupInput): Promise<ImportBackupResult> =>
    ipcRenderer.invoke("vesper:import-backup", input),
  startLocalStack: (checkoutPath?: string): Promise<StartStackResult> =>
    ipcRenderer.invoke("vesper:start-local-stack", checkoutPath),
  openTarget: (): Promise<void> => ipcRenderer.invoke("vesper:open-target"),
  onStateChange: (callback: (state: DesktopConnectionState) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, state: DesktopConnectionState) => {
      callback(state);
    };
    ipcRenderer.on("vesper:state", listener);
    return () => ipcRenderer.removeListener("vesper:state", listener);
  },
  onStackLog: (callback: (chunk: string) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, chunk: string) => {
      callback(chunk);
    };
    ipcRenderer.on("vesper:stack-log", listener);
    return () => ipcRenderer.removeListener("vesper:stack-log", listener);
  },

  // Native features. The main process checks each caller: the desktop's own
  // pages (file://) for everything below except confirmApproval, which only the
  // Vesper web app at the configured server origin may call.

  /** Settings window (renderer/preferences.html). */
  getPreferences: (): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-get"),
  setPreferences: (patch: unknown): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-set", patch),
  setQuickActionsInstalled: (install: boolean): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-services", install),
  checkForUpdates: (): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-check-updates"),
  testNotification: (): Promise<void> => ipcRenderer.invoke("vesper:prefs-test-notification"),
  testTouchId: (): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-test-touch-id"),
  openServerSettings: (): Promise<void> => ipcRenderer.invoke("vesper:open-server-settings"),
  openDataDir: (): Promise<void> => ipcRenderer.invoke("vesper:open-data-dir"),
  pickExportFolder: (): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-pick-export-folder"),
  exportNow: (): Promise<unknown> => ipcRenderer.invoke("vesper:prefs-export-now"),

  /** Quick capture (renderer/capture.html). */
  getCaptureOptions: (): Promise<unknown> => ipcRenderer.invoke("vesper:capture-options"),
  submitCapture: (input: unknown): Promise<unknown> => ipcRenderer.invoke("vesper:capture-submit", input),
  closeWindow: (): Promise<void> => ipcRenderer.invoke("vesper:close-window"),

  /** Send files (renderer/send-files.html). */
  getSendFiles: (): Promise<unknown> => ipcRenderer.invoke("vesper:send-files-get"),
  submitSendFiles: (input: unknown): Promise<unknown> => ipcRenderer.invoke("vesper:send-files-submit", input),

  /** Stack health and logs (offline.html, logs.html). */
  getHealth: (): Promise<unknown> => ipcRenderer.invoke("vesper:get-health"),
  onHealth: (callback: (health: unknown) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, health: unknown) => callback(health);
    ipcRenderer.on("vesper:health", listener);
    return () => ipcRenderer.removeListener("vesper:health", listener);
  },
  getLogs: (): Promise<unknown> => ipcRenderer.invoke("vesper:logs-get"),
  revealLogs: (): Promise<void> => ipcRenderer.invoke("vesper:logs-reveal"),
  copyLogs: (): Promise<void> => ipcRenderer.invoke("vesper:logs-copy"),
  restartStack: (): Promise<void> => ipcRenderer.invoke("vesper:stack-restart"),
  openLogs: (): Promise<void> => ipcRenderer.invoke("vesper:open-logs"),

  /**
   * For the web app: a native menu to open a run's or chat's workspace folder
   * in Finder, a terminal or an editor. The main process only opens folders
   * inside a runner's host workspaces directory.
   */
  openWorkspaceMenu: (folder: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("vesper:open-workspace-menu", folder),

  /**
   * Touch ID before an approval (LAZYAGENTS-248), for the web app. Resolves
   * { ok: true } when no prompt is needed or it succeeded; { ok: false } when
   * the person cancelled. A local gate only: the server never sees it.
   */
  confirmApproval: (scope: "run_approvals" | "push_requests" | "connector_approvals" | "secret_approvals"): Promise<{ ok: boolean; prompted: boolean; error?: string }> =>
    ipcRenderer.invoke("vesper:confirm-approval", scope),
};

contextBridge.exposeInMainWorld("vesperDesktop", api);
