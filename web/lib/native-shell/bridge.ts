// The page's side of the native shell bridge (docs/dev/native-mac-app.md, "Page ↔ shell bridge").
// No React here, so `node --test` covers it with a fake window; the hooks are in hooks.ts.

import {
  isNativeCommand,
  isPageMessage,
  PROTOCOL_VERSION,
  type MenuItem,
  type NativeCommand,
  type PageMessage,
} from "./protocol.ts";

type Reply = Extract<NativeCommand, { type: "reply" }>;

interface NativeWindow extends EventTarget {
  __VESPER_NATIVE__?: { v?: number; platform?: string };
  webkit?: { messageHandlers?: { vesper?: { postMessage?: (msg: unknown) => void } } };
}

const win = (): NativeWindow | undefined => (globalThis as { window?: NativeWindow }).window;

/** True inside the Mac app's web view: the shell's user script set the marker and the handler exists. */
export function isNativeShell(): boolean {
  const w = win();
  return !!w && w.__VESPER_NATIVE__?.v === PROTOCOL_VERSION && typeof w.webkit?.messageHandlers?.vesper?.postMessage === "function";
}

/** Send a message to the shell. A no-op outside the native shell or for a malformed message. */
export function post(msg: PageMessage): void {
  if (!isNativeShell() || !isPageMessage(msg)) return;
  win()!.webkit!.messageHandlers!.vesper!.postMessage!(msg);
}

const lastByType = new Map<string, string>();

/** Like post, but skips a message equal (by JSON) to the last one of its type. */
export function postDeduped(msg: PageMessage): void {
  if (!isNativeShell()) return;
  const json = JSON.stringify(msg);
  if (lastByType.get(msg.type) === json) return;
  lastByType.set(msg.type, json);
  post(msg);
}

/** Forget what postDeduped sent (tests). */
export function resetDedupe(): void {
  lastByType.clear();
}

/** Listen for the shell's commands. Anything that isn't a valid v1 command is ignored. */
export function onCommand(handler: (cmd: NativeCommand) => void): () => void {
  const w = win();
  if (!w) return () => {};
  const listener = (e: Event) => {
    const detail = (e as CustomEvent).detail;
    if (isNativeCommand(detail)) handler(detail);
  };
  w.addEventListener("vesper-native", listener);
  return () => w.removeEventListener("vesper-native", listener);
}

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
export type RequestMessage = Extract<PageMessage, { requestId: string }>;

/** How long the shell gets to answer: a person is deciding for the approval, the menus, so a minute. */
const TIMEOUT_MS: Record<RequestMessage["type"], number> = {
  confirmApproval: 60_000,
  openWorkspaceMenu: 60_000,
  contextMenu: 60_000,
  // A sheet waits for the person however long they take; this only stops a lost reply leaking.
  confirm: 3_600_000,
};
const DEFAULT_TIMEOUT_MS = 10_000;

let counter = 0;
const newRequestId = () => `r${Date.now().toString(36)}-${(++counter).toString(36)}`;

/** Send a request and resolve with the shell's reply. Rejects outside the shell or on timeout. */
export function request(msg: DistributiveOmit<RequestMessage, "requestId" | "v">, opts: { timeoutMs?: number } = {}): Promise<Reply> {
  if (!isNativeShell()) return Promise.reject(new Error("Not running in the native shell"));
  const requestId = newRequestId();
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS[msg.type] ?? DEFAULT_TIMEOUT_MS;
  return new Promise<Reply>((resolve, reject) => {
    let off = () => {};
    const timer = setTimeout(() => {
      off();
      reject(new Error(`The shell didn't answer ${msg.type}`));
    }, timeoutMs);
    off = onCommand((cmd) => {
      if (cmd.type !== "reply" || cmd.requestId !== requestId) return;
      clearTimeout(timer);
      off();
      resolve(cmd);
    });
    post({ ...msg, v: PROTOCOL_VERSION, requestId } as PageMessage);
  });
}

/**
 * Asks "Are you sure?" as a sheet on the window. Resolves true only for the confirm button; false
 * when cancelled, on error, or outside the native shell (callers check isNativeShell first).
 */
export async function nativeConfirm(options: { title: string; body?: string; confirmLabel: string; cancelLabel?: string; destructive: boolean }): Promise<boolean> {
  if (!isNativeShell()) return false;
  try {
    const reply = await request({ type: "confirm", ...options });
    return reply.ok;
  } catch {
    return false;
  }
}

/**
 * Shows a native context menu at (x, y) in the page's coordinates. Resolves to the chosen item's
 * id, or null when dismissed, on error, or outside the native shell.
 */
export async function nativeContextMenu(items: MenuItem[], x: number, y: number): Promise<string | null> {
  if (!isNativeShell()) return null;
  try {
    const reply = await request({ type: "contextMenu", items, x, y });
    return reply.ok ? (reply.selectedId ?? null) : null;
  } catch {
    return null;
  }
}
