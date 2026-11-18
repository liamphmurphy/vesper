import test from "node:test";
import assert from "node:assert/strict";
import {
  DEV_TERMINAL_SHORTCUT_GROUPS,
  decodeOsc52,
  devTerminalShortcutGroups,
  devWorkspaceSocketUrl,
  devWorkspaceStatusLabel,
  devWorkspaceStatusTone,
  extractTerminalLines,
  filterDevWorkspaceRepos,
  formatTerminalSnapshot,
  fullscreenExitHint,
  isDevFullscreenShortcut,
  terminalSnapshotFilename,
  tmuxPrefixLabel,
} from "./dev-workspace.ts";

test("devWorkspaceSocketUrl builds ws/wss URL from location and port", () => {
  assert.equal(
    devWorkspaceSocketUrl({ protocol: "http:", hostname: "localhost" }, 8090, 120, 36),
    "ws://localhost:8090/ws?cols=120&rows=36",
  );
  assert.equal(
    devWorkspaceSocketUrl({ protocol: "https:", hostname: "vesper.tailnet.ts.net" }, 8091, 80.7, 24.2),
    "wss://vesper.tailnet.ts.net:8091/ws?cols=80&rows=24",
  );
});

test("devWorkspaceStatusTone and label map states cleanly", () => {
  assert.equal(devWorkspaceStatusTone("ready"), "done");
  assert.equal(devWorkspaceStatusTone("starting"), "human");
  assert.equal(devWorkspaceStatusTone("error"), "blocked");
  assert.equal(devWorkspaceStatusTone("stopped"), "neutral");

  assert.equal(devWorkspaceStatusLabel({ enabled: false, state: "stopped", step: null }), "Stopped (not configured)");
  assert.equal(devWorkspaceStatusLabel({ enabled: true, state: "starting", step: "Installing Nix + LazyVim" }), "Starting · Installing Nix + LazyVim");
  assert.equal(devWorkspaceStatusLabel({ enabled: true, state: "ready", step: null }), "Ready");
});

test("fullscreenExitHint reflects native and keyboard-lock state", () => {
  assert.equal(fullscreenExitHint(true, true), "Hold Esc to exit");
  assert.equal(fullscreenExitHint(true, false), "Esc or Exit");
  assert.equal(fullscreenExitHint(false, false), "Exit");
});

test("isDevFullscreenShortcut matches Cmd/Ctrl+Shift+Enter only", () => {
  const mk = (over = {}) => ({ key: "Enter", code: "Enter", metaKey: false, ctrlKey: true, altKey: false, shiftKey: true, ...over });
  assert.equal(isDevFullscreenShortcut(mk()), true);
  assert.equal(isDevFullscreenShortcut(mk({ metaKey: true, ctrlKey: false })), true);
  assert.equal(isDevFullscreenShortcut(mk({ shiftKey: false })), false);
  assert.equal(isDevFullscreenShortcut(mk({ altKey: true })), false);
  assert.equal(isDevFullscreenShortcut(mk({ metaKey: false, ctrlKey: false })), false);
  assert.equal(isDevFullscreenShortcut(mk({ key: "f", code: "KeyF" })), false);
});

test("DEV_TERMINAL_SHORTCUT_GROUPS covers LazyVim, tmux, and browser", () => {
  assert.equal(DEV_TERMINAL_SHORTCUT_GROUPS.length, 3);
  for (const g of DEV_TERMINAL_SHORTCUT_GROUPS) {
    assert.ok(g.items.length > 0);
  }
  assert.equal(tmuxPrefixLabel("C-a"), "Ctrl+a");
  const custom = devTerminalShortcutGroups("C-a");
  assert.equal(custom[1].title, "tmux (Ctrl+a prefix)");
  assert.equal(custom[1].items[0].keys, "Ctrl+a c");
});

test("extractTerminalLines trims trailing blank lines and caps output", () => {
  const rows = ["$ go test ./...", "PASS", "   ", ""];
  const buf = {
    length: rows.length,
    getLine: (i) => ({ translateToString: (trimRight) => (trimRight ? rows[i].replace(/\s+$/, "") : rows[i]) }),
  };
  assert.deepEqual(extractTerminalLines(buf, 120), ["$ go test ./...", "PASS"]);
  assert.deepEqual(extractTerminalLines(buf, 1), ["PASS"]);
});

test("formatTerminalSnapshot and terminalSnapshotFilename render markdown", () => {
  const at = Date.UTC(2026, 10, 16, 6, 15, 30);
  assert.equal(terminalSnapshotFilename(at), "dev-terminal-20261116-061530.md");
  const md = formatTerminalSnapshot({
    lines: ["$ ls", "vesper"],
    selection: "vesper",
    cols: 120,
    rows: 36,
    at,
  });
  assert.match(md, /# Dev terminal snapshot/);
  assert.match(md, /## Selected text/);
  assert.match(md, /## Visible terminal output \(2 lines\)/);
  assert.match(md, /\$ ls\nvesper/);
});

test("filterDevWorkspaceRepos matches repo_url and directory case-insensitively", () => {
  const repos = [
    { repo_url: "https://github.com/acme/alpha-service", directory: "alpha-service" },
    { repo_url: "https://github.com/other/alpha-service", directory: "alpha-service-2" },
    { repo_url: "https://github.com/acme/vesper", directory: "vesper" },
  ];
  assert.equal(filterDevWorkspaceRepos(repos, "  ").length, 3);
  assert.deepEqual(
    filterDevWorkspaceRepos(repos, "VESPER").map((r) => r.directory),
    ["vesper"],
  );
  assert.deepEqual(
    filterDevWorkspaceRepos(repos, "alpha-service-2").map((r) => r.repo_url),
    ["https://github.com/other/alpha-service"],
  );
  assert.equal(filterDevWorkspaceRepos(repos, "missing").length, 0);
});

test("decodeOsc52 decodes clipboard writes and refuses reads", () => {
  const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
  assert.equal(decodeOsc52(`c;${b64("hello world")}`), "hello world");
  assert.equal(decodeOsc52(`;${b64("multi\nline")}`), "multi\nline");
  assert.equal(decodeOsc52(`p;${b64("héllo ✓")}`), "héllo ✓");
  assert.equal(decodeOsc52("c;?"), null);
  assert.equal(decodeOsc52("c;"), null);
  assert.equal(decodeOsc52("no-separator"), null);
  assert.equal(decodeOsc52("c;not base64!"), null);
  assert.equal(decodeOsc52(`c;${Buffer.from([0xff, 0xfe]).toString("base64")}`), null);
  assert.equal(decodeOsc52(`c;${"A".repeat((1 << 20) + 4)}`), null);
});
