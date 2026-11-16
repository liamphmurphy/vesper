import test from "node:test";
import assert from "node:assert/strict";
import { devWorkspaceSocketUrl, devWorkspaceStatusLabel, devWorkspaceStatusTone } from "./dev-workspace.ts";

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
