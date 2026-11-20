export const DEFAULT_BACKUP_PLAYER_TYPES = ["embed", "popout", "autoplay"] as const;

export type TwitchAdStatus = "none" | "swapped" | "active";

/** Parses comma/whitespace-separated backup player_types (deduplicated, alphanumeric/-/_). */
export function parseBackupTypesInput(raw: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const part of raw.split(/[\s,]+/)) {
    const clean = part.trim().toLowerCase();
    if (!clean || !/^[a-z0-9_-]{1,32}$/.test(clean) || seen.has(clean)) continue;
    seen.add(clean);
    out.push(clean);
    if (out.length >= 8) break;
  }
  return out;
}

/** Returns true when the video canvas/element should be hidden & muted behind the ad overlay. */
export function shouldHideAdOverlay(adActive: boolean, manualReveal: boolean): boolean {
  return adActive && !manualReveal;
}

/** Formats seconds into mm:ss or h:mm:ss for VOD seek displays and ad counters. */
export function formatTwitchTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const whole = Math.floor(seconds);
  const hrs = Math.floor(whole / 3600);
  const mins = Math.floor((whole % 3600) / 60);
  const secs = whole % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return hrs > 0 ? `${hrs}:${pad(mins)}:${pad(secs)}` : `${mins}:${pad(secs)}`;
}

/** Formats live HLS latency seconds cleanly for the live indicator badge. */
export function formatTwitchLatency(latencySec: number | null | undefined): string {
  if (latencySec === null || latencySec === undefined || !Number.isFinite(latencySec) || latencySec < 0) {
    return "";
  }
  if (latencySec < 10) return `${latencySec.toFixed(1)}s`;
  return `${Math.round(latencySec)}s`;
}

/**
 * Returns true only for Vesper's same-origin Twitch HLS proxy URLs so `xhrSetup`
 * never sends Vesper credentials cross-origin to Twitch edge CDNs.
 */
export function isSameOriginTwitchPlaylistUrl(rawUrl: string, currentOrigin = "http://localhost"): boolean {
  const s = rawUrl.trim();
  if (!s) return false;
  try {
    const u = new URL(s, currentOrigin);
    if (u.origin !== new URL(currentOrigin).origin) return false;
    return u.pathname.startsWith("/api/v1/twitch/");
  } catch {
    return false;
  }
}
