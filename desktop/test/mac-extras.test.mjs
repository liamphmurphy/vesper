import assert from "node:assert/strict";
import test from "node:test";
import { exportFileName, exportsToPrune, isExportDue, parseIsExcluded, timeMachineTargets } from "../dist/backups.js";
import { screencaptureArgs, screenshotFileName } from "../dist/screenshot.js";
import { defaultNativeSettings, isValidAppName, isValidTerminalCommand, normalizeFolder, normalizeNativeSettings } from "../dist/settings.js";
import { desiredSlotLimit, easingOffLabel, parseLowPowerMode } from "../dist/thermal.js";
import { appleScriptString, isInsideRoots, openCommand } from "../dist/workspace-open.js";

test("new settings default safely and repair bad input", () => {
  const d = defaultNativeSettings();
  assert.equal(d.screenshot.enabled, false, "a global shortcut is opt-in");
  assert.equal(d.backups.excludeFromTimeMachine, true);
  assert.equal(d.backups.export.enabled, false);
  assert.equal(d.power.easeOffWhenHot, true);
  assert.deepEqual(d.workspaces.editor, { kind: "terminal", command: "nvim", app: "Visual Studio Code" });

  const n = normalizeNativeSettings({
    backups: { export: { folder: "relative/dir", everyHours: 0, keep: 1000 } },
    workspaces: { terminalApp: "Ghostty", editor: { kind: "emacs", command: "nvim; rm -rf ~", app: "Zed" } },
  });
  assert.equal(n.backups.export.folder, "");
  assert.equal(n.backups.export.everyHours, 24);
  assert.equal(n.backups.export.keep, 7);
  assert.equal(n.workspaces.terminalApp, "Ghostty");
  assert.equal(n.workspaces.editor.kind, "terminal");
  assert.equal(n.workspaces.editor.command, "nvim", "a command with ; is refused");
  assert.equal(n.workspaces.editor.app, "Zed");
});

test("app names, terminal commands and folders are validated", () => {
  for (const ok of ["Terminal", "iTerm", "Visual Studio Code", "Cursor", "Zed Preview"]) assert.ok(isValidAppName(ok), ok);
  for (const bad of ["", " Terminal", "a/b", "Terminal\"; x", "x".repeat(65)]) assert.ok(!isValidAppName(bad), bad);
  for (const ok of ["nvim", "hx", "nvim -c Explore", "emacs -nw"]) assert.ok(isValidTerminalCommand(ok), ok);
  for (const bad of ["", "nvim;ls", "nvim && ls", "$(id)", "`id`", "nvim | x", "nvim > f", "nvim 'a'", "nvim  x"]) {
    assert.ok(!isValidTerminalCommand(bad), bad);
  }
  assert.equal(normalizeFolder("/Users/liam/Backups/", ""), "/Users/liam/Backups");
  assert.equal(normalizeFolder("", "/x"), "");
  assert.equal(normalizeFolder("~/Backups", "/x"), "/x");
  assert.equal(normalizeFolder("/a\nb", "/x"), "/x");
});

test("screenshot file names and screencapture arguments", () => {
  assert.equal(screenshotFileName(new Date(2026, 10, 17, 14, 5, 9)), "Screenshot 2026-11-17 at 14.05.09.png");
  assert.deepEqual(screencaptureArgs("/tmp/x/s.png"), ["-i", "-x", "-t", "png", "/tmp/x/s.png"]);
  assert.throws(() => screencaptureArgs("s.png"));
});

test("Time Machine targets are only rebuildable folders", () => {
  assert.deepEqual(timeMachineTargets("/Users/l/Library/Application Support/Vesper"), [
    "/Users/l/Library/Application Support/Vesper/vm",
    "/Users/l/Library/Application Support/Vesper/images",
  ]);
  assert.equal(parseIsExcluded("[Excluded]    /a/vm\n"), true);
  assert.equal(parseIsExcluded("[Included]    /a/vm\n"), false);
  assert.equal(parseIsExcluded("tmutil: error"), null);
});

test("scheduled exports: names, due times and pruning only our own files", () => {
  assert.equal(exportFileName(new Date(2026, 0, 2, 3, 4)), "vesper-export-2026-01-02-0304.zip");
  const names = [
    "vesper-export-2026-11-15-0900.zip",
    "vesper-export-2026-11-17-0900.zip",
    "vesper-export-2026-11-16-0900.zip",
    "vesper-export-2026-11-14-0900.zip",
    "notes.txt",
    "vesper-export-latest.zip",
    "vesper-export-2026-11-17-0900.zip.part",
  ];
  assert.deepEqual(exportsToPrune(names, 2), ["vesper-export-2026-11-15-0900.zip", "vesper-export-2026-11-14-0900.zip"]);
  assert.deepEqual(exportsToPrune(names, 0).length, 3, "always keeps at least the newest");
  const h = 60 * 60 * 1000;
  assert.equal(isExportDue(undefined, 10 * h, 24), true);
  assert.equal(isExportDue(1 * h, 10 * h, 24), false);
  assert.equal(isExportDue(1 * h, 26 * h, 24), true);
  assert.equal(isExportDue(50 * h, 10 * h, 24), true, "a clock that moved back exports");
});

test("desiredSlotLimit eases off for heat and Low Power Mode, never raises capacity", () => {
  const base = { enabled: true, thermal: "nominal", lowPowerMode: false, maxSlots: 4 };
  assert.equal(desiredSlotLimit(base), null);
  assert.equal(desiredSlotLimit({ ...base, thermal: "fair" }), null);
  assert.equal(desiredSlotLimit({ ...base, thermal: "serious" }), 2);
  assert.equal(desiredSlotLimit({ ...base, lowPowerMode: true }), 2);
  assert.equal(desiredSlotLimit({ ...base, thermal: "critical" }), 1);
  assert.equal(desiredSlotLimit({ ...base, thermal: "critical", enabled: false }), null);
  assert.equal(desiredSlotLimit({ ...base, thermal: "serious", maxSlots: 1 }), null, "a cap equal to max is no cap");
  assert.equal(desiredSlotLimit({ ...base, thermal: "serious", maxSlots: 3 }), 1);
  assert.equal(desiredSlotLimit({ ...base, maxSlots: 0, thermal: "critical" }), null);
  assert.equal(parseLowPowerMode(" displaysleep 10\n lowpowermode         1\n"), true);
  assert.equal(parseLowPowerMode(" lowpowermode         0\n"), false);
  assert.equal(parseLowPowerMode(""), false);
  assert.equal(easingOffLabel(1, "critical", false), "Mac is hot: 1 run at a time");
  assert.equal(easingOffLabel(2, "nominal", true), "Low Power Mode: 2 runs at a time");
  assert.equal(easingOffLabel(null, "critical", true), null);
});

test("workspace folders open only inside a runner's workspace root", () => {
  const roots = ["/Users/l/Vesper Workspaces"];
  assert.equal(isInsideRoots("/Users/l/Vesper Workspaces/run-1", roots), true);
  assert.equal(isInsideRoots("/Users/l/Vesper Workspaces", roots), false, "the root itself isn't a workspace");
  assert.equal(isInsideRoots("/Users/l/Vesper Workspaces-evil/x", roots), false);
  assert.equal(isInsideRoots("/Users/l/Vesper Workspaces/../.ssh", roots), false);
  assert.equal(isInsideRoots("relative/run-1", roots), false);
  assert.equal(isInsideRoots("/Users/l/Vesper Workspaces/run-1", []), false);
});

test("openCommand builds safe commands for each target", () => {
  const ws = defaultNativeSettings().workspaces;
  const dir = `/Users/l/W/it's "here"`;
  assert.equal(openCommand("finder", dir, ws), null);
  assert.deepEqual(openCommand("terminal", dir, { ...ws, terminalApp: "Ghostty" }), { file: "/usr/bin/open", args: ["-a", "Ghostty", dir] });
  assert.deepEqual(openCommand("editor", dir, { ...ws, editor: { ...ws.editor, kind: "app", app: "Zed" } }), {
    file: "/usr/bin/open",
    args: ["-a", "Zed", dir],
  });
  const nvim = openCommand("editor", dir, ws);
  assert.equal(nvim.file, "/usr/bin/osascript");
  assert.equal(
    nvim.args[1],
    `tell application "Terminal" to do script "cd '/Users/l/W/it'\\\\''s \\"here\\"' && nvim ."`,
  );
  // A hostile command in settings falls back to nvim rather than running.
  const hostile = openCommand("editor", "/w/x", { ...ws, editor: { ...ws.editor, command: "nvim; curl evil" } });
  assert.match(hostile.args[1], /&& nvim \."$/);
  assert.equal(appleScriptString('a\\b"c'), '"a\\\\b\\"c"');
  assert.throws(() => openCommand("terminal", "relative", ws));
});
