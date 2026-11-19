import { expect, test } from "@playwright/test";
import type { Schemas } from "../lib/api/client";
import { installChatApi } from "./mock-chat-api";

const runId = "00000000-0000-4000-8000-000000000101";
const otherId = "00000000-0000-4000-8000-000000000102";
const at = "2026-11-06T22:00:00Z";
const snapshot: Schemas["EnvironmentSnapshot"] = {
  run_id: runId, runner_id: "mac-local", backend: "microvm", recorded_at: at,
  ticket_key: "WEB-1", project_key: "WEB", project_name: "Web app",
  report: {
    status: "ready", manifest: ".lazyagents-deps.json", go_modules: ["server"], npm_projects: ["web"], playwright: ["web"],
    tools: [{ name: "go", available: true, version: "go version go1.26.0 darwin/arm64" }, { name: "node", available: true, version: "v24.21.0" }],
    caches: [{ name: "npm downloads", path: "/runner/cache/npm", shared: true, exists: true, writable: true },
      { name: "Go build", path: "/workspace/.lazyagents/cache/go-build", shared: false, exists: false, writable: false }],
    packages: [{ name: "next", version: "16.4.3", ecosystem: "npm", project: "web" }],
  },
};
const environment: Schemas["RunnerEnvironment"] = {
  runner: { online: true, runners: [{ id: "mac-local", backend: "microvm", heartbeat_at: at, max_concurrent: 2, running: 1 }], slots: 2, busy: 1, live: 1, queued: 0, host_folder_workspaces: false },
  snapshots: [snapshot, { ...snapshot, run_id: otherId, runner_id: "docker-offline", backend: "microvm", report: { ...snapshot.report, status: "failed", error: "missing required tool: sqlc", tools: [{ name: "sqlc", available: false }] } }],
};

test("environment shows measured tools, project libraries, caches and setup failures", async ({ page }) => {
  await installChatApi(page);
  await page.route("**/api/v1/runner/environment*", (route) => route.fulfill({ json: environment }));
  await page.goto("/settings#runners");
  await page.getByRole("link", { name: "View runner environment" }).click();
  await expect(page.getByRole("heading", { name: "Runner environment", exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "go version go1.26.0 darwin/arm64" })).toBeVisible();
  await expect(page.getByText("/runner/cache/npm", { exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "16.4.3" })).toBeVisible();
  await expect(page.getByText("Not created yet", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "WEB-1 run log" })).toHaveAttribute("href", `/runs/${runId}`);
  await page.screenshot({ path: "test-results/runner-environment-desktop.png", fullPage: true });
  await page.getByLabel("Space and runner").selectOption(otherId);
  await expect(page.getByRole("alert").filter({ hasText: "Dependency setup failed" })).toContainText("missing required tool: sqlc");
  await expect(page.getByText("Runner offline", { exact: true })).toBeVisible();
  await expect(page.getByRole("rowheader", { name: "sqlc" })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "test-results/runner-environment-mobile.png", fullPage: true });
});

test("exact-run environment keeps its query and handles older runs without reports", async ({ page }) => {
  await installChatApi(page);
  let requested = "";
  await page.route("**/api/v1/runner/environment*", (route) => {
    requested = new URL(route.request().url()).searchParams.get("run_id") ?? "";
    return route.fulfill({ json: { ...environment, snapshots: [] } });
  });
  await page.goto(`/settings/runner?run_id=${runId}`);
  await expect(page.getByRole("heading", { name: "No environment recorded for this run" })).toBeVisible();
  expect(requested).toBe(runId);
  await expect(page.getByRole("link", { name: "View latest environments" })).toHaveAttribute("href", "/settings/runner");
});

test("environment request errors can be retried", async ({ page }) => {
  await installChatApi(page);
  let recover = false;
  await page.route("**/api/v1/runner/environment*", (route) => recover
    ? route.fulfill({ json: environment })
    : route.fulfill({ status: 503, json: { code: "internal", message: "Runner service unavailable" } }));
  await page.goto("/settings/runner");
  await expect(page.getByRole("alert").filter({ hasText: "Couldn’t load" })).toContainText("Runner service unavailable", { timeout: 15_000 });
  recover = true;
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.getByRole("cell", { name: "v24.21.0" })).toBeVisible();
});

test("test environments show what was inferred and learned, and can be edited or forgotten", async ({ page }) => {
  await installChatApi(page);
  await page.route("**/api/v1/runner/environment*", (route) => route.fulfill({ json: environment }));
  const learned: Schemas["TestEnvironment"] = {
    repo: "github.com/acme/app", inferred_from: [".github/workflows/ci.yml"], learned_from_run_id: runId,
    created_at: at, updated_at: at,
    recipe: {
      services: [{ name: "postgres", image: "postgres:17-alpine", expose: { TEST_DATABASE_URL: "postgres://postgres@postgres:5432/postgres" } }],
      nix_packages: ["nixpkgs#protobuf"],
    },
  };
  let environments = [learned];
  let saved: unknown = null;
  let forgotten = "";
  await page.route("**/api/v1/runner/test-environments*", async (route) => {
    const req = route.request();
    if (req.method() === "PUT") {
      saved = req.postDataJSON();
      environments = [{ ...learned, recipe: (saved as { recipe: Schemas["TestRecipe"] }).recipe, edited_at: at }];
      return route.fulfill({ json: environments[0] });
    }
    if (req.method() === "DELETE") {
      forgotten = new URL(req.url()).searchParams.get("repo") ?? "";
      environments = [];
      return route.fulfill({ status: 204 });
    }
    return route.fulfill({ json: { environments } });
  });
  await page.goto("/settings/runner");
  const card = page.getByRole("region", { name: "Test environments" }).or(page.locator("section", { hasText: "Test environments" })).first();
  await expect(card.getByText("github.com/acme/app", { exact: true })).toBeVisible();
  await expect(card.getByText("postgres:17-alpine")).toBeVisible();
  await expect(card.getByText("TEST_DATABASE_URL")).toBeVisible();
  await expect(card.getByText("nixpkgs#protobuf")).toBeVisible();
  await expect(card.getByText(/read from \.github\/workflows\/ci\.yml/)).toBeVisible();
  await card.screenshot({ path: "test-results/test-environments.png" });

  await card.getByRole("button", { name: "Edit" }).click();
  const editor = card.getByLabel("Test environment for github.com/acme/app as JSON");
  await editor.fill("{ not json");
  await expect(card.getByRole("alert")).toBeVisible();
  await expect(card.getByRole("button", { name: "Save" })).toBeDisabled();
  await editor.fill(JSON.stringify({ nix_packages: ["nixpkgs#jq"] }));
  await card.getByRole("button", { name: "Save" }).click();
  await expect(card.getByText("nixpkgs#jq")).toBeVisible();
  expect(saved).toEqual({ repo: "github.com/acme/app", recipe: { nix_packages: ["nixpkgs#jq"] } });

  await card.getByRole("button", { name: "Forget" }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Forget" }).click();
  await expect(card.getByText(/None yet/)).toBeVisible();
  expect(forgotten).toBe("github.com/acme/app");
});
