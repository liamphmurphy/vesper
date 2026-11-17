import path from "node:path";

/**
 * Screenshot to a chat: the macOS region picker (`screencapture -i`), then the
 * same Send to Vesper picker as dropped files.
 */

export const SCREENCAPTURE_BIN = "/usr/sbin/screencapture";

/** "Screenshot 2026-11-17 at 14.05.09.png", like macOS names its own. */
export function screenshotFileName(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `Screenshot ${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())} at ${p(now.getHours())}.${p(now.getMinutes())}.${p(now.getSeconds())}.png`;
}

/**
 * Interactive region (or, with Space, window) capture, no shutter sound,
 * PNG, written to `file`. Escape writes nothing.
 */
export function screencaptureArgs(file: string): string[] {
  if (!path.isAbsolute(file)) throw new Error("screenshot path must be absolute");
  return ["-i", "-x", "-t", "png", file];
}
