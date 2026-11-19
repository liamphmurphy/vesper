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
  // HTTP Client lives in the Apps menu's Tools, beside Workflows and Reports.
  await page.getByRole("button", { name: "Apps" }).click();
  await page.getByRole("link", { name: "HTTP Client" }).click();

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

test("right-click menus add a request or import a cURL command at a folder", async ({ page }) => {
  await installBoardApi(page);
  const stamp = "2026-11-16T12:00:00Z";
  const workspace = {
    id: "ws-1", name: "Billing API", description: "", active_environment_id: null,
    default_auth: { type: "none" }, default_headers: [], default_vars: [], created_at: stamp, updated_at: stamp,
  };
  const folder = {
    id: "folder-users", http_workspace_id: "ws-1", parent_folder_id: null, name: "Users",
    default_auth: { type: "inherit" }, default_headers: [], sort_order: 0, created_at: stamp, updated_at: stamp,
  };
  const request = {
    id: "req-sync", http_workspace_id: "ws-1", folder_id: null, name: "Health", method: "GET", url: "{{base_url}}/health",
    params: [], headers: [], auth: { type: "inherit" }, body_mode: "none", body: "", body_form: [],
    timeout_ms: 30000, follow_redirects: true, sort_order: 0, created_at: stamp, updated_at: stamp,
  };
  const created: { folder_id: string | null }[] = [];
  const imports: { format: string; content: string; folder_id: string | null }[] = [];

  await page.route("**/api/v1/api-secrets", (route) => route.fulfill({ json: { secrets: [] } }));
  await page.route("**/api/v1/http/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    if (path === "/api/v1/http/workspaces" && method === "GET") return route.fulfill({ json: { workspaces: [workspace] } });
    if (path === "/api/v1/http/workspaces/ws-1" && method === "GET") {
      return route.fulfill({ json: { workspace, environments: [], folders: [folder], requests: [request] } });
    }
    if (path === "/api/v1/http/workspaces/ws-1/requests" && method === "POST") {
      const body = route.request().postDataJSON();
      created.push({ folder_id: body.folder_id });
      return route.fulfill({ json: { ...request, ...body, id: "req-new" } });
    }
    if (path === "/api/v1/http/workspaces/ws-1/import" && method === "POST") {
      imports.push(route.request().postDataJSON());
      return route.fulfill({ json: { folders_created: 0, requests_created: 1, environments_created: 0 } });
    }
    if (path.endsWith("/executions")) return route.fulfill({ json: { executions: [] } });
    return route.fulfill({ status: 404, json: { code: "not_found", message: "unhandled" } });
  });

  await page.goto("/http");
  const tree = page.locator("aside").filter({ hasText: "Users" });
  await expect(tree.getByText("Users")).toBeVisible();

  // Right-click a folder: New request lands in that folder.
  await tree.getByText("Users").click({ button: "right" });
  await page.getByRole("menuitem", { name: "New request" }).click();
  await expect.poll(() => created).toEqual([{ folder_id: "folder-users" }]);

  // Right-click a folder: Import cURL… opens on the cURL tab and imports into that folder.
  await tree.getByText("Users").click({ button: "right" });
  await page.getByRole("menuitem", { name: "Import cURL…" }).click();
  const dialog = page.getByRole("dialog", { name: "Import HTTP collection" });
  await expect(dialog.getByText("Import into “Users”")).toBeVisible();
  const curl = `curl -X POST "https://api.example.com/v1/items" -H "X-A: 1" -d '{"a":1}'`;
  await dialog.getByPlaceholder(/curl -X POST/).fill(curl);
  await dialog.getByRole("button", { name: "Import" }).click();
  await expect.poll(() => imports).toEqual([{ format: "curl", content: curl, folder_id: "folder-users" }]);
  await expect(dialog).toBeHidden();

  // Right-click a request opens the request menu, not the tree's.
  await tree.getByText("Health").click({ button: "right" });
  await expect(page.getByRole("menuitem", { name: "Delete request" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Import cURL…" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  // Right-click empty space in the tree: the workspace-root menu.
  await tree.locator("div.flex-1.overflow-y-auto").click({ button: "right", position: { x: 100, y: 400 } });
  await page.getByRole("menuitem", { name: "Import cURL…" }).click();
  await expect(dialog.getByText("Import into Workspace")).toBeVisible();
});
