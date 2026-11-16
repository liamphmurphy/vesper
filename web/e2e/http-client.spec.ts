import { expect, test } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

test("bottom-right launcher opens HTTP utility, switches environments, inherits auth, and runs calls", async ({ page }) => {
  await installBoardApi(page);

  let activeEnvId = "env-nonprod";
  const workspace = {
    id: "ws-1",
    name: "Billing API",
    description: "Billing service endpoints",
    active_environment_id: activeEnvId,
    default_auth: { type: "bearer", token: "{{api_token}}" },
    default_headers: [{ key: "X-Client-Id", value: "vesper-ui", enabled: true }],
    default_vars: [],
    created_at: "2026-11-16T12:00:00Z",
    updated_at: "2026-11-16T12:00:00Z",
  };
  const environments = [
    {
      id: "env-nonprod",
      http_workspace_id: "ws-1",
      name: "nonprod",
      color: "green",
      variables: [{ key: "base_url", value: "https://api.nonprod.example.com", enabled: true }],
      sort_order: 0,
      created_at: "2026-11-16T12:00:00Z",
      updated_at: "2026-11-16T12:00:00Z",
    },
    {
      id: "env-prod",
      http_workspace_id: "ws-1",
      name: "prod",
      color: "red",
      variables: [{ key: "base_url", value: "https://api.example.com", enabled: true }],
      sort_order: 1,
      created_at: "2026-11-16T12:00:00Z",
      updated_at: "2026-11-16T12:00:00Z",
    },
  ];
  const folders = [
    {
      id: "folder-users",
      http_workspace_id: "ws-1",
      parent_folder_id: null,
      name: "Users",
      default_auth: { type: "inherit" },
      default_headers: [],
      sort_order: 0,
      created_at: "2026-11-16T12:00:00Z",
      updated_at: "2026-11-16T12:00:00Z",
    },
  ];
  const requests = [
    {
      id: "req-sync",
      http_workspace_id: "ws-1",
      folder_id: "folder-users",
      name: "Sync Users",
      method: "POST",
      url: "{{base_url}}/v1/users/sync",
      params: [],
      headers: [],
      auth: { type: "inherit" },
      body_mode: "json",
      body: '{"dry_run":false}',
      body_form: [],
      timeout_ms: 30000,
      follow_redirects: true,
      sort_order: 0,
      created_at: "2026-11-16T12:00:00Z",
      updated_at: "2026-11-16T12:00:00Z",
    },
  ];
  const executions: unknown[] = [];

  await page.route("**/api/v1/api-secrets", (route) => route.fulfill({ json: { secrets: [] } }));
  await page.route("**/api/v1/http/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    const method = route.request().method();

    if (path === "/api/v1/http/workspaces" && method === "GET") {
      return route.fulfill({ json: { workspaces: [{ ...workspace, active_environment_id: activeEnvId }] } });
    }
    if (path === "/api/v1/http/workspaces/ws-1" && method === "GET") {
      return route.fulfill({
        json: {
          workspace: { ...workspace, active_environment_id: activeEnvId },
          environments,
          folders,
          requests,
        },
      });
    }
    if (path === "/api/v1/http/workspaces/ws-1/active-environment" && method === "PATCH") {
      const body = JSON.parse(route.request().postData() ?? "{}");
      activeEnvId = body.environment_id;
      return route.fulfill({ json: { ...workspace, active_environment_id: activeEnvId } });
    }
    if (path === "/api/v1/http/requests/req-sync/executions" && method === "GET") {
      return route.fulfill({ json: { executions } });
    }
    if (path === "/api/v1/http/requests/req-sync/run" && method === "POST") {
      const env = environments.find((e) => e.id === activeEnvId);
      const exec = {
        id: "exec-1",
        http_workspace_id: "ws-1",
        request_id: "req-sync",
        environment_id: activeEnvId,
        environment_name: env?.name ?? "",
        method: "POST",
        resolved_url: `${env?.variables[0].value}/v1/users/sync`,
        request_headers: { Authorization: "[redacted]", "X-Client-Id": "vesper-ui" },
        request_body: '{"dry_run":false}',
        status_code: 200,
        status_text: "200 OK",
        duration_ms: 42,
        size_bytes: 38,
        response_headers: { "Content-Type": ["application/json"] },
        response_body: JSON.stringify({ ok: true, env: env?.name }),
        response_truncated: false,
        created_at: "2026-11-16T12:00:01Z",
      };
      executions.unshift(exec);
      return route.fulfill({ json: exec });
    }
    return route.fulfill({ status: 404, json: { code: "not_found", message: "unhandled" } });
  });

  await page.goto("/runs");
  const launcher = page.getByTestId("http-launcher");
  await expect(launcher).toBeVisible();
  await launcher.click();

  await expect(page).toHaveURL(/\/http$/);
  await expect(page.getByRole("textbox", { name: "Request name" })).toHaveValue("Sync Users");

  // Check inherited auth indicator.
  await page.getByRole("button", { name: "Auth (Inherited)" }).click();
  await expect(page.getByText(/Inheriting from Workspace "Billing API" \(Bearer Token\)/)).toBeVisible();

  // Switch active environment from nonprod to prod and send request.
  await page.getByLabel("Active environment").selectOption("env-prod");
  await page.getByRole("button", { name: /Send/ }).click();
  await expect(page.getByText("200 OK")).toBeVisible();
  await expect(page.locator("pre")).toContainText('"env": "prod"');

  // Switch to Auth & Env view.
  await page.getByRole("button", { name: "Auth & Env" }).click();
  await expect(page.getByRole("heading", { name: /Billing API — Auth Inheritance & Environments/ })).toBeVisible();
  await expect(page.getByText("Workspace Default Auth & Headers")).toBeVisible();
});
