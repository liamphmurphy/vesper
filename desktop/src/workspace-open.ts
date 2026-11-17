import path from "node:path";
import { shQuote } from "./services";
import { isValidAppName, isValidTerminalCommand, type NativeSettings } from "./settings";

/**
 * Open a run's or chat's host-folder workspace in Finder, a terminal or an
 * editor. The folder comes from the web page, so it's only opened when it
 * resolves inside a runner's host workspaces directory.
 */

export const OPEN_TARGETS = ["finder", "terminal", "editor"] as const;
export type OpenTarget = (typeof OPEN_TARGETS)[number];

export function isOpenTarget(value: unknown): value is OpenTarget {
  return typeof value === "string" && (OPEN_TARGETS as readonly string[]).includes(value);
}

/**
 * Whether `realDir` (already realpath'd) is strictly inside one of the
 * (realpath'd) workspace roots. The roots themselves don't count.
 */
export function isInsideRoots(realDir: string, realRoots: readonly string[]): boolean {
  if (!path.isAbsolute(realDir)) return false;
  const dir = path.normalize(realDir);
  return realRoots.some((root) => {
    if (!root || !path.isAbsolute(root)) return false;
    const r = path.normalize(root).replace(/\/+$/, "");
    return dir.startsWith(`${r}${path.sep}`) && dir.length > r.length + 1;
  });
}

/** Escapes a string for an AppleScript double-quoted literal. */
export function appleScriptString(s: string): string {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export interface OpenCommand {
  file: string;
  args: string[];
}

/**
 * The process to run for a target. Finder is null (the caller uses
 * shell.openPath). A terminal-kind editor runs its command in Terminal via
 * AppleScript `do script`: the folder is shell-quoted, the whole line is an
 * AppleScript string literal, and the command itself was validated as plain
 * words, so nothing in either can become another command.
 */
export function openCommand(target: OpenTarget, dir: string, ws: NativeSettings["workspaces"]): OpenCommand | null {
  if (!path.isAbsolute(dir)) throw new Error("workspace path must be absolute");
  switch (target) {
    case "finder":
      return null;
    case "terminal": {
      const app = isValidAppName(ws.terminalApp) ? ws.terminalApp : "Terminal";
      return { file: "/usr/bin/open", args: ["-a", app, dir] };
    }
    case "editor": {
      if (ws.editor.kind === "app") {
        const app = isValidAppName(ws.editor.app) ? ws.editor.app : "Visual Studio Code";
        return { file: "/usr/bin/open", args: ["-a", app, dir] };
      }
      const command = isValidTerminalCommand(ws.editor.command) ? ws.editor.command : "nvim";
      const line = `cd ${shQuote(dir)} && ${command} .`;
      return {
        file: "/usr/bin/osascript",
        args: ["-e", `tell application "Terminal" to do script ${appleScriptString(line)}`, "-e", 'tell application "Terminal" to activate'],
      };
    }
  }
}
