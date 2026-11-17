/**
 * Native macOS feature settings, stored under `native` in config.json.
 *
 * Every feature has its own switch. Defaults keep the behaviour the app had
 * before these features existed (tray present but quitting on Quit only, all
 * existing notifications on), and anything that reaches outside the app (an
 * update check over the network, a login item, a global shortcut) is opt-in.
 */

/** Inbox kinds the desktop can alert on, in the order Preferences lists them. */
export const NOTIFICATION_KINDS = [
  "approval",
  "question",
  "blocked",
  "stalled",
  "mockup",
  "planning",
  "review",
  "workflow_gate",
  "connector_approval",
  "secret_approval",
  "merged",
  "pr_approved",
  "drive_backup",
] as const;
export type NotificationKind = (typeof NOTIFICATION_KINDS)[number];

/** Approval surfaces Touch ID can guard. */
export const TOUCH_ID_SCOPES = ["run_approvals", "push_requests", "connector_approvals", "secret_approvals"] as const;
export type TouchIdScope = (typeof TOUCH_ID_SCOPES)[number];

export const SLEEP_POLICIES = ["keep", "pause"] as const;
export type SleepPolicy = (typeof SLEEP_POLICIES)[number];

/** What closing the last window does: stay in the Dock (macOS default), live only in the menu bar, or quit. */
export const LAST_WINDOW_POLICIES = ["dock", "menuBar", "quit"] as const;
export type LastWindowPolicy = (typeof LAST_WINDOW_POLICIES)[number];

export const DEFAULT_QUICK_CAPTURE_SHORTCUT = "Alt+Shift+Space";
export const DEFAULT_UPDATE_FEED_URL = "https://api.github.com/repos/liamphmurphy/vesper/releases/latest";

export interface NativeSettings {
  tray: {
    /** Show the menu bar icon. */
    enabled: boolean;
    /** What closing the last window does. "menuBar" hides the Dock icon and keeps Vesper in the menu bar. */
    onLastWindowClose: LastWindowPolicy;
    /** Show the Needs-you count next to the icon. */
    showCount: boolean;
  };
  login: {
    /** Register Vesper as a login item. */
    openAtLogin: boolean;
    /** When launched at login, start in the menu bar without opening a window. */
    startHidden: boolean;
  };
  notifications: {
    enabled: boolean;
    kinds: Record<NotificationKind, boolean>;
    /** Approve/Decline and inline Reply buttons on approvals and questions. */
    actions: boolean;
    /** Group alerts for the same run or ticket in Notification Center. */
    groupByWork: boolean;
    /** Alert once when a ticket or planning run completes or fails. */
    runFinished: boolean;
    sound: boolean;
    quietHours: { enabled: boolean; start: string; end: string };
  };
  quickCapture: {
    enabled: boolean;
    /** Electron accelerator, e.g. "Alt+Shift+Space". */
    shortcut: string;
  };
  deepLinks: {
    /** Handle vesper:// links. */
    enabled: boolean;
  };
  power: {
    /** Hold a power-save blocker (prevents idle sleep) while runs are live. */
    preventSleepWhileRunning: boolean;
    /** keep: leave runs alone across sleep; pause: pause live ticket runs on sleep and resume them on wake. */
    onSleep: SleepPolicy;
    /** Notify when the Mac switches to battery while runs are live. */
    warnOnBattery: boolean;
    /** Ask before quitting with live runs. */
    confirmQuitWithActiveRuns: boolean;
  };
  stack: {
    /** Restart the local stack automatically after it crashes (at most 3 times in 10 minutes). */
    autoRestart: boolean;
    /** Warn below this much free disk space in the data directory, in GB. */
    minFreeDiskGb: number;
  };
  files: {
    /** Accept files dropped on the Dock icon or opened with Vesper. */
    dockDrop: boolean;
  };
  touchId: {
    enabled: boolean;
    scopes: Record<TouchIdScope, boolean>;
  };
  updates: {
    /** Check the release feed for a newer DMG (network call; opt-in). */
    checkEnabled: boolean;
    feedUrl: string;
  };
}

export function defaultNativeSettings(): NativeSettings {
  return {
    tray: { enabled: true, onLastWindowClose: "dock", showCount: true },
    login: { openAtLogin: false, startHidden: true },
    notifications: {
      enabled: true,
      kinds: Object.fromEntries(NOTIFICATION_KINDS.map((k) => [k, true])) as Record<NotificationKind, boolean>,
      actions: true,
      groupByWork: true,
      runFinished: true,
      sound: true,
      quietHours: { enabled: false, start: "22:00", end: "08:00" },
    },
    quickCapture: { enabled: false, shortcut: DEFAULT_QUICK_CAPTURE_SHORTCUT },
    deepLinks: { enabled: true },
    power: {
      preventSleepWhileRunning: true,
      onSleep: "keep",
      warnOnBattery: true,
      confirmQuitWithActiveRuns: true,
    },
    stack: { autoRestart: true, minFreeDiskGb: 10 },
    files: { dockDrop: true },
    touchId: {
      enabled: false,
      scopes: Object.fromEntries(TOUCH_ID_SCOPES.map((s) => [s, true])) as Record<TouchIdScope, boolean>,
    },
    updates: { checkEnabled: false, feedUrl: DEFAULT_UPDATE_FEED_URL },
  };
}

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

export function isValidClockTime(value: unknown): value is string {
  return typeof value === "string" && TIME_RE.test(value);
}

function bool(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function obj(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

function boolMap<K extends string>(keys: readonly K[], value: unknown, fallback: Record<K, boolean>): Record<K, boolean> {
  const src = obj(value);
  return Object.fromEntries(keys.map((k) => [k, bool(src[k], fallback[k])])) as Record<K, boolean>;
}

/** Only https feeds (or http on loopback, for testing) are accepted. */
export function normalizeFeedUrl(value: unknown, fallback: string): string {
  if (typeof value !== "string" || !value.trim()) return fallback;
  try {
    const u = new URL(value.trim());
    const loopback = u.hostname === "localhost" || u.hostname === "127.0.0.1";
    if (u.protocol === "https:" || (u.protocol === "http:" && loopback)) return u.toString();
  } catch {
    // fall through
  }
  return fallback;
}

/**
 * Accepts a partial or hostile settings object (from disk or from the
 * Preferences window) and returns a complete, valid one. Unknown keys are
 * dropped; invalid values fall back to `base` (the defaults, or the current
 * settings when applying a patch).
 */
export function normalizeNativeSettings(raw: unknown, base: NativeSettings = defaultNativeSettings()): NativeSettings {
  const src = obj(raw);
  const tray = obj(src.tray);
  const login = obj(src.login);
  const notif = obj(src.notifications);
  const quiet = obj(notif.quietHours);
  const qc = obj(src.quickCapture);
  const deep = obj(src.deepLinks);
  const power = obj(src.power);
  const stack = obj(src.stack);
  const files = obj(src.files);
  const touch = obj(src.touchId);
  const updates = obj(src.updates);

  const minDisk = Number(stack.minFreeDiskGb);
  const shortcut = typeof qc.shortcut === "string" && qc.shortcut.trim() ? qc.shortcut.trim().slice(0, 64) : base.quickCapture.shortcut;

  return {
    tray: {
      enabled: bool(tray.enabled, base.tray.enabled),
      onLastWindowClose: (LAST_WINDOW_POLICIES as readonly string[]).includes(tray.onLastWindowClose as string)
        ? (tray.onLastWindowClose as LastWindowPolicy)
        : base.tray.onLastWindowClose,
      showCount: bool(tray.showCount, base.tray.showCount),
    },
    login: {
      openAtLogin: bool(login.openAtLogin, base.login.openAtLogin),
      startHidden: bool(login.startHidden, base.login.startHidden),
    },
    notifications: {
      enabled: bool(notif.enabled, base.notifications.enabled),
      kinds: boolMap(NOTIFICATION_KINDS, notif.kinds, base.notifications.kinds),
      actions: bool(notif.actions, base.notifications.actions),
      groupByWork: bool(notif.groupByWork, base.notifications.groupByWork),
      runFinished: bool(notif.runFinished, base.notifications.runFinished),
      sound: bool(notif.sound, base.notifications.sound),
      quietHours: {
        enabled: bool(quiet.enabled, base.notifications.quietHours.enabled),
        start: isValidClockTime(quiet.start) ? quiet.start : base.notifications.quietHours.start,
        end: isValidClockTime(quiet.end) ? quiet.end : base.notifications.quietHours.end,
      },
    },
    quickCapture: {
      enabled: bool(qc.enabled, base.quickCapture.enabled),
      shortcut,
    },
    deepLinks: { enabled: bool(deep.enabled, base.deepLinks.enabled) },
    power: {
      preventSleepWhileRunning: bool(power.preventSleepWhileRunning, base.power.preventSleepWhileRunning),
      onSleep: (SLEEP_POLICIES as readonly string[]).includes(power.onSleep as string)
        ? (power.onSleep as SleepPolicy)
        : base.power.onSleep,
      warnOnBattery: bool(power.warnOnBattery, base.power.warnOnBattery),
      confirmQuitWithActiveRuns: bool(power.confirmQuitWithActiveRuns, base.power.confirmQuitWithActiveRuns),
    },
    stack: {
      autoRestart: bool(stack.autoRestart, base.stack.autoRestart),
      minFreeDiskGb: Number.isFinite(minDisk) && minDisk >= 1 && minDisk <= 1000 ? Math.round(minDisk) : base.stack.minFreeDiskGb,
    },
    files: { dockDrop: bool(files.dockDrop, base.files.dockDrop) },
    touchId: {
      enabled: bool(touch.enabled, base.touchId.enabled),
      scopes: boolMap(TOUCH_ID_SCOPES, touch.scopes, base.touchId.scopes),
    },
    updates: {
      checkEnabled: bool(updates.checkEnabled, base.updates.checkEnabled),
      feedUrl: normalizeFeedUrl(updates.feedUrl, base.updates.feedUrl),
    },
  };
}

/** Applies a partial patch from the Preferences window on top of the current settings. */
export function applyNativeSettingsPatch(current: NativeSettings, patch: unknown): NativeSettings {
  return normalizeNativeSettings(deepMerge(current, obj(patch)), current);
}

function deepMerge(base: unknown, patch: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...obj(base) };
  for (const [k, v] of Object.entries(patch)) {
    if (k === "__proto__" || k === "constructor" || k === "prototype") continue;
    out[k] = v && typeof v === "object" && !Array.isArray(v) ? deepMerge(out[k], v as Record<string, unknown>) : v;
  }
  return out;
}
