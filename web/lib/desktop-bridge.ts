/**
 * The macOS desktop app's preload bridge (desktop/src/preload.ts), when this
 * page runs inside it. Feature-detected: in a browser, or a desktop build
 * without a feature, every helper here falls back to doing nothing.
 */

export type ApprovalScope = "run_approvals" | "push_requests" | "connector_approvals" | "secret_approvals";

interface DesktopBridge {
  confirmApproval?: (scope: ApprovalScope) => Promise<{ ok: boolean; prompted: boolean; error?: string }>;
}

function bridge(): DesktopBridge | undefined {
  if (typeof window === "undefined") return undefined;
  return (window as unknown as { vesperDesktop?: DesktopBridge }).vesperDesktop;
}

export class ApprovalNotConfirmedError extends Error {
  constructor() {
    super("Touch ID wasn't confirmed, so nothing was approved.");
    this.name = "ApprovalNotConfirmedError";
  }
}

/**
 * Before approving: in the desktop app, asks for Touch ID when the person
 * turned that on for this kind of approval (LAZYAGENTS-248). Throws
 * ApprovalNotConfirmedError when they cancel, so the mutation fails and
 * nothing is sent. A local gate only: the server never sees it.
 */
export async function confirmApprovalLocally(scope: ApprovalScope, getBridge: () => DesktopBridge | undefined = bridge): Promise<void> {
  const confirmApproval = getBridge()?.confirmApproval;
  if (typeof confirmApproval !== "function") return;
  let result: { ok: boolean } | undefined;
  try {
    result = await confirmApproval(scope);
  } catch {
    // The bridge is there but refused the call (e.g. an older desktop build): behave like a browser.
    return;
  }
  if (!result?.ok) throw new ApprovalNotConfirmedError();
}
