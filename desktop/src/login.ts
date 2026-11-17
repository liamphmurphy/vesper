/**
 * Launch at login (LAZYAGENTS-242).
 *
 * macOS 13+ registers the app itself as a login item (SMAppService
 * mainAppService); `openAsHidden` no longer exists there, so a login launch is
 * detected with `wasOpenedAtLogin` and the app skips opening a window.
 */

export interface LoginSettings {
  openAtLogin: boolean;
  startHidden: boolean;
}

/** Arguments for app.setLoginItemSettings. */
export function loginItemSettingsFor(settings: LoginSettings): { openAtLogin: boolean; type: "mainAppService" } {
  return { openAtLogin: settings.openAtLogin, type: "mainAppService" };
}

/**
 * Whether this launch should start without a window. Needs the menu bar icon,
 * or the person would have no way to reach the app.
 */
export function shouldStartHidden(settings: LoginSettings, trayEnabled: boolean, wasOpenedAtLogin: boolean): boolean {
  return wasOpenedAtLogin && settings.openAtLogin && settings.startHidden && trayEnabled;
}

export type LoginItemStatus = "enabled" | "not-registered" | "requires-approval" | "not-found" | "unknown";

/** A sentence for Preferences explaining the login item's state, or null when nothing needs saying. */
export function loginStatusMessage(wanted: boolean, status: LoginItemStatus): string | null {
  if (!wanted) return null;
  switch (status) {
    case "enabled":
      return null;
    case "requires-approval":
      return "macOS needs your OK: open System Settings › General › Login Items and allow Vesper.";
    case "not-found":
      return "macOS couldn't find Vesper to register it. Move Vesper.app to Applications and try again.";
    case "not-registered":
      return "Vesper isn't registered as a login item yet. Toggle the setting off and on again.";
    default:
      return null;
  }
}
