/**
 * DMG update path (LAZYAGENTS-249). Decision: docs/dev/desktop-updates.md.
 *
 * Vesper.app is ad-hoc signed and not notarised, so Squirrel.Mac (Electron's
 * autoUpdater) can't apply updates: it requires a Developer ID signature that
 * matches across versions. The supported path is: check a release feed (opt-in),
 * tell the person a newer DMG exists, and open its download page. They replace
 * the app by dragging the new one into Applications. userData lives outside
 * the bundle (~/Library/Application Support/Vesper), so it survives.
 */

export interface ParsedVersion {
  major: number;
  minor: number;
  patch: number;
  pre: string;
}

export function parseVersion(raw: unknown): ParsedVersion | null {
  if (typeof raw !== "string") return null;
  const m = /^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-([0-9A-Za-z.-]{1,64}))?(?:\+[0-9A-Za-z.-]+)?$/.exec(raw.trim());
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), pre: m[4] ?? "" };
}

/** Semver-style compare; a pre-release sorts before its release. Unparseable versions compare equal. */
export function compareVersions(a: string, b: string): number {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) return 0;
  for (const k of ["major", "minor", "patch"] as const) {
    if (pa[k] !== pb[k]) return pa[k] < pb[k] ? -1 : 1;
  }
  if (pa.pre === pb.pre) return 0;
  if (!pa.pre) return 1;
  if (!pb.pre) return -1;
  return pa.pre < pb.pre ? -1 : 1;
}

export interface UpdateInfo {
  version: string;
  /** The release page to open; always https on github.com or the feed's own host. */
  url: string;
  name: string;
}

/**
 * Reads a GitHub "latest release" response. Drafts and pre-releases are
 * ignored; the page URL must be https on github.com or on the feed's host, so
 * a tampered feed can't send the person anywhere else.
 */
export function pickUpdate(currentVersion: string, feedUrl: string, release: unknown): UpdateInfo | null {
  const r = release && typeof release === "object" ? (release as Record<string, unknown>) : null;
  if (!r || r.draft === true || r.prerelease === true) return null;
  const tag = typeof r.tag_name === "string" ? r.tag_name : "";
  const version = parseVersion(tag);
  if (!version || compareVersions(tag, currentVersion) <= 0) return null;
  const page = typeof r.html_url === "string" ? r.html_url : "";
  let pageUrl: URL;
  let feedHost = "";
  try {
    pageUrl = new URL(page);
    feedHost = new URL(feedUrl).hostname;
  } catch {
    return null;
  }
  const hostOk = pageUrl.hostname === "github.com" || pageUrl.hostname === feedHost;
  if (pageUrl.protocol !== "https:" || !hostOk) return null;
  const name = typeof r.name === "string" && r.name.trim() ? r.name.trim().slice(0, 100) : tag;
  return { version: `${version.major}.${version.minor}.${version.patch}${version.pre ? `-${version.pre}` : ""}`, url: pageUrl.toString(), name };
}

export type VersionTransition = "first-run" | "same" | "upgrade" | "downgrade";

/**
 * Compares this build with the one that last opened the data directory. A
 * downgrade can leave the database at a newer schema than this build knows;
 * the app warns before starting the stack (see main.ts).
 */
export function versionTransition(lastVersion: string | undefined, currentVersion: string): VersionTransition {
  if (!lastVersion || !parseVersion(lastVersion)) return "first-run";
  const c = compareVersions(currentVersion, lastVersion);
  return c === 0 ? "same" : c > 0 ? "upgrade" : "downgrade";
}

/** Checks at most once a day. */
export function isCheckDue(lastCheckedAt: number | undefined, now: number, intervalMs = 24 * 60 * 60 * 1000): boolean {
  return !lastCheckedAt || !Number.isFinite(lastCheckedAt) || now - lastCheckedAt >= intervalMs || lastCheckedAt > now;
}
