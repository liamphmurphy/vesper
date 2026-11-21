import test from "node:test";
import assert from "node:assert/strict";
import { devWorkspaceStatusLabel, devWorkspaceStatusTone, filterDevWorkspaceRepos } from "./dev-workspace.ts";

test("devWorkspaceStatusTone and label map states cleanly", () => {
  assert.equal(devWorkspaceStatusTone("ready"), "done");
  assert.equal(devWorkspaceStatusTone("starting"), "human");
  assert.equal(devWorkspaceStatusTone("error"), "blocked");
  assert.equal(devWorkspaceStatusTone("stopped"), "neutral");

  assert.equal(devWorkspaceStatusLabel({ enabled: false, state: "stopped", step: null }), "Stopped (not configured)");
  assert.equal(devWorkspaceStatusLabel({ enabled: true, state: "starting", step: "Installing Nix + LazyVim" }), "Starting · Installing Nix + LazyVim");
  assert.equal(devWorkspaceStatusLabel({ enabled: true, state: "ready", step: null }), "Ready");
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
