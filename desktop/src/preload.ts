import { contextBridge, ipcRenderer } from "electron";

export type ConnectionPhase = "checking" | "reachable" | "unreachable";

export interface DesktopConnectionState {
  serverUrl: string;
  targetUrl: string;
  phase: ConnectionPhase;
  errorMessage?: string;
  lastCheckedAt?: string;
  localCheckoutPath?: string;
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

const api = {
  getState: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:get-state"),
  retryConnection: (): Promise<DesktopConnectionState> => ipcRenderer.invoke("vesper:retry-connection"),
  setServerUrl: (input: SetServerUrlInput): Promise<SetServerUrlResult> =>
    ipcRenderer.invoke("vesper:set-server-url", input),
  openTarget: (): Promise<void> => ipcRenderer.invoke("vesper:open-target"),
  onStateChange: (callback: (state: DesktopConnectionState) => void): (() => void) => {
    const listener = (_event: Electron.IpcRendererEvent, state: DesktopConnectionState) => {
      callback(state);
    };
    ipcRenderer.on("vesper:state", listener);
    return () => ipcRenderer.removeListener("vesper:state", listener);
  },
};

contextBridge.exposeInMainWorld("vesperDesktop", api);
