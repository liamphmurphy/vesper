import fs from "node:fs";
import path from "node:path";

/**
 * Small bits the app remembers between launches that aren't settings:
 * the version that last opened the data directory (downgrade warning) and
 * when it last checked for updates. Kept in app-state.json beside config.json.
 */
export interface AppState {
  lastVersion?: string;
  lastUpdateCheckAt?: number;
  /** An update the person already heard about, so it's announced once. */
  announcedUpdate?: string;
  /** The last successful export to the backup folder, and the last failure's message. */
  lastExportAt?: number;
  lastExportError?: string;
}

export function loadAppState(filePath: string): AppState {
  try {
    const raw = JSON.parse(fs.readFileSync(filePath, "utf8")) as Record<string, unknown>;
    return {
      ...(typeof raw.lastVersion === "string" ? { lastVersion: raw.lastVersion.slice(0, 64) } : {}),
      ...(typeof raw.lastUpdateCheckAt === "number" && Number.isFinite(raw.lastUpdateCheckAt) ? { lastUpdateCheckAt: raw.lastUpdateCheckAt } : {}),
      ...(typeof raw.announcedUpdate === "string" ? { announcedUpdate: raw.announcedUpdate.slice(0, 64) } : {}),
      ...(typeof raw.lastExportAt === "number" && Number.isFinite(raw.lastExportAt) ? { lastExportAt: raw.lastExportAt } : {}),
      ...(typeof raw.lastExportError === "string" ? { lastExportError: raw.lastExportError.slice(0, 300) } : {}),
    };
  } catch {
    return {};
  }
}

export function saveAppState(filePath: string, state: AppState): void {
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const tmp = `${filePath}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, "utf8");
    fs.renameSync(tmp, filePath);
  } catch {
    // Non-fatal.
  }
}
