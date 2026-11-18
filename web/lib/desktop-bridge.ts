import { isNativeShell, request } from "./native-shell/bridge.ts";

/**
 * The Mac app's side of the page: its message bridge (lib/native-shell). Feature-detected: in a
 * browser, every helper here falls back to doing nothing.
 */

/** The native shell's side, injectable for tests. */
export interface NativeApi {
  active: () => boolean;
  request: (msg: { type: "confirmApproval"; scope: ApprovalScope } | { type: "openWorkspaceMenu"; folder: string }) => Promise<{ ok: boolean; error?: string }>;
}
const nativeApi: NativeApi = { active: isNativeShell, request };

export type ApprovalScope = "run_approvals" | "push_requests" | "connector_approvals" | "secret_approvals";

export class ApprovalNotConfirmedError extends Error {
  constructor() {
    super("Touch ID wasn't confirmed, so nothing was approved.");
    this.name = "ApprovalNotConfirmedError";
  }
}

/**
 * Before approving: in the Mac app, asks for Touch ID when the person
 * turned that on for this kind of approval (LAZYAGENTS-248). Throws
 * ApprovalNotConfirmedError when they cancel, so the mutation fails and
 * nothing is sent. A local gate only: the server never sees it.
 */
export async function confirmApprovalLocally(scope: ApprovalScope, native: NativeApi = nativeApi): Promise<void> {
  if (!native.active()) return;
  // The shell asks for Touch ID (or doesn't, per the person's setting) and answers; no answer fails closed.
  const reply = await native.request({ type: "confirmApproval", scope }).catch(() => undefined);
  if (!reply?.ok) throw new ApprovalNotConfirmedError();
}

/** Whether this page runs in the Mac app, which can open workspace folders. */
export function canOpenWorkspaceFolder(native: NativeApi = nativeApi): boolean {
  return native.active();
}

/**
 * Shows the Mac app's Open menu (Finder, terminal, editor) for a
 * workspace folder. Resolves to an error message, or null when the menu
 * showed. The app only opens folders inside a runner's host workspaces
 * directory.
 */
export async function openWorkspaceFolder(folder: string, native: NativeApi = nativeApi): Promise<string | null> {
  if (!native.active()) return "Opening folders needs the Vesper desktop app.";
  try {
    const res = await native.request({ type: "openWorkspaceMenu", folder });
    return res.ok ? null : (res.error ?? "Couldn't open the folder.");
  } catch {
    return "Couldn't open the folder.";
  }
}
