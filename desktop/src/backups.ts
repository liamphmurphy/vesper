import path from "node:path";

/**
 * Backups (Time Machine exclusion and scheduled exports to a folder).
 */

/**
 * Data-directory folders Time Machine should skip. All are rebuilt or
 * re-downloaded: per-run VM disks and cache generations (vm/), and the
 * kernel and agent image (images/). The database, blobs and config stay in.
 */
export function timeMachineTargets(userDataDir: string): string[] {
  return [path.join(userDataDir, "vm"), path.join(userDataDir, "images")];
}

/** Reads `tmutil isexcluded <path>`: "[Excluded]    /path" or "[Included]    /path". */
export function parseIsExcluded(stdout: string): boolean | null {
  if (/^\s*\[Excluded\]/m.test(stdout)) return true;
  if (/^\s*\[Included\]/m.test(stdout)) return false;
  return null;
}

const EXPORT_RE = /^vesper-export-(\d{4})-(\d{2})-(\d{2})-(\d{4})\.zip$/;

/** "vesper-export-2026-11-17-1405.zip" (local time), sortable by name. */
export function exportFileName(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `vesper-export-${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}-${p(now.getHours())}${p(now.getMinutes())}.zip`;
}

/**
 * Exports to delete so only the newest `keep` remain. Only files with
 * Vesper's own export name are ever considered; anything else in the folder
 * is left alone.
 */
export function exportsToPrune(names: readonly string[], keep: number): string[] {
  const ours = names.filter((n) => EXPORT_RE.test(n)).sort().reverse();
  return ours.slice(Math.max(1, keep));
}

export function isExportDue(lastAt: number | undefined, now: number, everyHours: number): boolean {
  if (!lastAt || !Number.isFinite(lastAt) || lastAt > now) return true;
  return now - lastAt >= everyHours * 60 * 60 * 1000;
}
