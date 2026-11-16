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

const api = {
  getState: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:get-state"),
  retryConnection: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:retry-connection"),
  setServerUrl: (input: SetServerUrlInput): Promise<SetServerUrlResult> =>
    ipcRenderer.invoke("vesper:set-server-url", input),
  pickCheckoutFolder: (): Promise<string | null> => ipcRenderer.invoke("vesper:pick-checkout-folder"),
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
};

contextBridge.exposeInMainWorld("vesperDesktop", api);
