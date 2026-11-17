import { TOUCH_ID_SCOPES, type TouchIdScope } from "./settings";

/**
 * Optional Touch ID before approving (LAZYAGENTS-248).
 *
 * This is a local gate only. It runs in the desktop app before the app sends
 * the approval; the server never sees or verifies it. It stops someone using
 * an unlocked Mac from approving with a click. It does not stop a forged API
 * call, a browser session, or anything else holding the session cookie.
 */

export interface TouchIdSettings {
  enabled: boolean;
  scopes: Record<TouchIdScope, boolean>;
}

export function isTouchIdScope(value: unknown): value is TouchIdScope {
  return typeof value === "string" && (TOUCH_ID_SCOPES as readonly string[]).includes(value);
}

export type TouchIdDecision = "prompt" | "skip";

/**
 * Whether an approval in `scope` needs Touch ID. "skip" when the setting is
 * off, the scope is off, or the Mac can't prompt (no sensor, clamshell,
 * not enrolled): the existing click-to-approve flow then applies unchanged.
 */
export function touchIdDecision(settings: TouchIdSettings, scope: unknown, canPrompt: boolean): TouchIdDecision {
  if (!settings.enabled || !canPrompt || !isTouchIdScope(scope)) return "skip";
  return settings.scopes[scope] ? "prompt" : "skip";
}

const REASONS: Record<TouchIdScope, string> = {
  run_approvals: "approve an agent's request",
  push_requests: "approve a push and pull request",
  connector_approvals: "allow a connector tool call",
  secret_approvals: "allow a request that uses a secret",
};

/** The text macOS shows under "Vesper is trying to …". */
export function touchIdReason(scope: TouchIdScope): string {
  return REASONS[scope];
}
