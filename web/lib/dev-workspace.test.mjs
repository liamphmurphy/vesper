import test from "node:test";
import assert from "node:assert/strict";
import {
  DEV_TERMINAL_SHORTCUT_GROUPS,
  devWorkspaceSocketUrl,
  devWorkspaceStatusLabel,
  devWorkspaceStatusTone,
  fullscreenExitHint,
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

test("DEV_TERMINAL_SHORTCUT_GROUPS covers LazyVim, tmux, and browser", () => {
  assert.equal(DEV_TERMINAL_SHORTCUT_GROUPS.length, 3);
  for (const g of DEV_TERMINAL_SHORTCUT_GROUPS) {
    assert.ok(g.items.length > 0);
  }
});
