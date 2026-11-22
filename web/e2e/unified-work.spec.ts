import { test, expect, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import type { Schemas } from "../lib/api/client";

async function installWork(page: Page) {
  const api = await installBoardApi(page);
  await page.addInitScript(() =>
    sessionStorage.setItem("la:banner:harness:dismissed", "1"),
  );
  const run: Schemas["Run"] = {
    id: "work-run",
    ticket_key: "WEB-1",
    work_title: "Build ticket modal",
    purpose: "ticket",
    project_key: "WEB",
    agent: {
      id: "agent-builder",
      name: "Builder",
      handle: "builder",
      color_index: 0,
    },
    mode: "managed",
    state: "running",
    harness: "codex",
    model: "gpt-5-codex",
    started_at: "2026-11-14T10:00:00Z",
    tool_calls: 1,
    input_tokens: 100,
    output_tokens: 20,
    cost_usd: 0.42,
    cost_source: "harness",
    scopes: [],
    approval_scopes: [],
    plan: [
      { position: 1, state: "done", text: "Read Work views" },
      { position: 2, state: "current", text: "Checking navigation" },
    ],
  };
  const previous = {
    ...run,
    id: "previous-run",
    state: "cancelled",
    ended_at: "2026-11-14T09:00:00Z",
  };
  const replies: string[] = [];
  await page.route("**/api/v1/runs**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/runs"))
      return route.fulfill({
        json: {
          runs: url.searchParams.has("ticket") ? [run, previous] : [run],
          has_more: false,
        },
      });
    return route.fulfill({
      json: {
        run: url.pathname.includes("previous-run") ? previous : run,
        child_runs: [],
        turns: [],
        approvals: [],
        events: Array.from({ length: 16 }, (_, i) => ({
          seq: i + 1,
          type: "message",
          at: "2026-11-14T10:00:00Z",
          payload: {
            text: `Navigation check ${i + 1}. Keep the run and draft in place.`,
          },
        })).filter((e) => e.seq > Number(url.searchParams.get("after") ?? 0)),
      },
    });
  });
  await page.route("**/api/v1/tickets/WEB-1/comments", async (route) => {
    replies.push(route.request().postDataJSON().body_md);
    return route.fulfill({ status: 201, json: { id: "comment-1" } });
  });
  await page.addInitScript(() => {
    localStorage.setItem("la-theme", "dark");
    localStorage.setItem(
      "la-appearance",
      JSON.stringify({
        version: 1,
        palette: "gruvbox",
        custom: { base: "gruvbox", dark: {}, light: {} },
      }),
    );
  });
  return { api, replies };
}

test("a run page renders RunLogScreen, hides Graph without child runs, sends follow-ups, and collapses live status when ended", async ({
  page,
}) => {
  const { replies } = await installWork(page);
  await page.goto("/runs/work-run?project=WEB");
  await expect(
    page
      .getByRole("navigation", { name: "Context path" })
      .getByRole("link", { name: "WEB-1 ↗" }),
  ).toHaveAttribute("href", "/tickets/WEB-1");

  const viewTabs = page.getByRole("tablist", { name: "Run views" });
  await expect(viewTabs.getByRole("tab", { name: "Thread" })).toBeVisible();
  await expect(viewTabs.getByRole("tab", { name: /^Trace/ })).toBeVisible();
  await expect(viewTabs.getByRole("tab", { name: /^Files/ })).toBeVisible();
  await expect(viewTabs.getByRole("tab", { name: /^Graph/ })).toHaveCount(0);

  await expect(
    page.getByRole("progressbar", { name: "Plan progress" }),
  ).toBeVisible();
  await expect(page.locator("main [role='status']")).toBeVisible();

  const input = page.getByRole("textbox", { name: "Follow up with Builder" });
  await input.fill("Keep checking the nav.");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect
    .poll(() => replies)
    .toEqual(["@builder Keep checking the nav."]);

  await page.goto("/runs/previous-run?project=WEB");
  await expect(
    page.getByRole("progressbar", { name: "Plan progress" }),
  ).toBeVisible();
  await expect(page.locator("main [role='status']")).toHaveCount(0);
});

test("Work chat context chips stay inside the right-rail dock for long titles", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1240, height: 880 });
  await installWork(page);

  const meow = {
    id: "persona-meow",
    name: "Meow",
    tone: "neutral",
    color: "#5b8af5",
    custom_instructions: "",
    capabilities: { code: true, images: false },
    repos: [],
    is_default: true,
    chat_count: 1,
    revision: 1,
    created_at: "2026-11-18T10:00:00Z",
    updated_at: "2026-11-18T10:00:00Z",
  };
  const longRun = {
    id: "work-run",
    ticket_key: "LAZYAGENTS-226",
    work_title: "Drive backup: Settings → Backup & restore schedule and archive status",
    purpose: "ticket",
    project_key: "WEB",
    agent: {
      id: "agent-builder",
      name: "Builder",
      handle: "builder",
      color_index: 0,
    },
    mode: "managed",
    state: "running",
    harness: "claude-code",
    model: "opus-5.5",
    started_at: "2026-11-18T10:00:00Z",
    tool_calls: 1,
    input_tokens: 100,
    output_tokens: 20,
    cost_usd: 0.42,
    cost_source: "harness",
    scopes: [],
    approval_scopes: [],
    plan: [],
  };
  const chatBase = {
    title: "Work",
    hidden: true,
    state: "idle",
    archived: false,
    revision: 1,
    message_count: 0,
    harness: "claude-code",
    model: "opus-5.5",
    created_at: "2026-11-18T10:00:00Z",
    updated_at: "2026-11-18T10:00:00Z",
    agent: { id: "agent-assistant", name: "Assistant", handle: "assistant", color_index: 0 },
    persona: { id: meow.id, name: meow.name, color: meow.color, capabilities: meow.capabilities },
    participants: [{ id: meow.id, name: meow.name, color: meow.color }],
  };
  const existingChat = { ...chatBase, id: "work-chat-existing", title: "New chat" };
  const createdChat = { ...chatBase, id: "work-chat-1" };
  const dockChatList = [existingChat];

  await page.route("**/api/v1/runs**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/runs")) {
      return route.fulfill({ json: { runs: [longRun], has_more: false } });
    }
    return route.fulfill({
      json: { run: longRun, child_runs: [], turns: [], approvals: [], events: [] },
    });
  });
  await page.route("**/api/v1/personas", (route) =>
    route.fulfill({ json: { personas: [meow], default_persona_id: meow.id } }),
  );
  await page.route("**/api/v1/dock-chats**", (route) => {
    if (route.request().method() === "POST") {
      if (!dockChatList.some((c) => c.id === createdChat.id)) dockChatList.unshift(createdChat);
      return route.fulfill({ status: 204 });
    }
    return route.fulfill({ json: { chats: dockChatList } });
  });
  await page.route("**/api/v1/chat-models", (route) =>
    route.fulfill({
      json: [
        {
          harness: "claude-code",
          label: "Claude Code",
          available: true,
          models: [{ id: "opus-5.5", label: "Opus 5.5", default: true, efforts: ["low", "medium", "high"] }],
        },
      ],
    }),
  );
  await page.route("**/api/v1/workflows", (route) => route.fulfill({ json: { runs: [], workflows: [] } }));
  await page.route("**/api/v1/repositories", (route) => route.fulfill({ json: [] }));
  await page.route("**/api/v1/chat-suggestions", (route) => route.fulfill({ json: { suggestions: [] } }));
  await page.route("**/api/v1/chats**", async (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname.replace(/^\/api\/v1/, "");
    if (path === "/chats" && req.method() === "POST") {
      return route.fulfill({ status: 201, json: createdChat });
    }
    if (path === "/chats" && req.method() === "GET") {
      return route.fulfill({ json: { chats: [], has_more: false } });
    }
    if (path === `/chats/${createdChat.id}` && req.method() === "GET") {
      return route.fulfill({ json: createdChat });
    }
    if (path.endsWith("/messages")) return route.fulfill({ json: { messages: [], has_more: false } });
    if (path.endsWith("/asides")) return route.fulfill({ json: { asides: [] } });
    if (path.endsWith("/followups")) return route.fulfill({ json: { followups: [] } });
    if (path.endsWith("/videos")) return route.fulfill({ json: { videos: [] } });
    if (path.endsWith("/audio")) return route.fulfill({ json: { audio: [] } });
    if (path.endsWith("/push-requests")) return route.fulfill({ json: { requests: [] } });
    if (path.endsWith("/runs")) return route.fulfill({ json: { runs: [] } });
    if (path.endsWith("/workflows")) return route.fulfill({ json: { runs: [] } });
    if (path.endsWith("/research")) return route.fulfill({ json: { jobs: [] } });
    if (path.endsWith("/canvases")) return route.fulfill({ json: { canvases: [] } });
    if (path.endsWith("/playground")) return route.fulfill({ json: { playground: null } });
    if (path.endsWith("/code-review")) return route.fulfill({ json: { repositories: [] } });
    if (path.endsWith("/persona-proposals")) return route.fulfill({ json: { proposals: [] } });
    if (path.endsWith("/connector-approvals")) return route.fulfill({ json: { approvals: [] } });
    if (path.endsWith("/connector-proposals")) return route.fulfill({ json: { proposals: [] } });
    if (path.endsWith("/api-secrets")) return route.fulfill({ json: { secrets: [] } });
    if (path.endsWith("/api-secret-approvals")) return route.fulfill({ json: { approvals: [] } });
    if (path.endsWith("/api-secret-proposals")) return route.fulfill({ json: { proposals: [] } });
    if (path.endsWith("/ticket-changes")) return route.fulfill({ json: { requests: [] } });
    return route.fallback();
  });

  await page.goto("/runs/work-run?project=WEB");
  await page.getByRole("navigation", { name: "Panel rail" }).getByRole("button", { name: "Open Chat" }).click();

  const panel = page.getByRole("complementary", { name: "Panel", exact: true });
  await expect(panel.getByTestId("work-chat-subject")).toContainText("LAZYAGENTS-226");

  const expectInsidePanel = async (name: string, locator: ReturnType<Page["locator"]>) => {
    const panelBox = await panel.boundingBox();
    const box = await locator.boundingBox();
    expect(panelBox, "panel bounding box").not.toBeNull();
    expect(box, `${name} bounding box`).not.toBeNull();
    expect(
      box!.x,
      `${name} left edge (${box!.x}) should stay inside panel (${panelBox!.x}..${panelBox!.x + panelBox!.width})`,
    ).toBeGreaterThanOrEqual(panelBox!.x - 0.5);
    expect(
      box!.x + box!.width,
      `${name} right edge (${box!.x + box!.width}) should stay inside panel (${panelBox!.x}..${panelBox!.x + panelBox!.width})`,
    ).toBeLessThanOrEqual(panelBox!.x + panelBox!.width + 0.5);
  };

  // Empty state: To + Viewing chips must stay inside the 360px dock and truncate long titles.
  await expectInsidePanel("empty dock-context", panel.getByTestId("dock-context"));
  await expectInsidePanel("empty dock-chat-to", panel.getByTestId("dock-chat-to"));
  await expectInsidePanel("empty work-chat-subject", panel.getByTestId("work-chat-subject"));
  await expectInsidePanel("empty Pin button", panel.getByRole("button", { name: /^Pin / }));

  const truncated = await panel
    .getByTestId("work-chat-subject")
    .locator("span.truncate")
    .evaluate((el) => el.scrollWidth > el.clientWidth);
  expect(truncated, "Viewing chip label should truncate inside the narrow dock").toBe(true);

  // Pinning in the empty state keeps the Pinned chip inside the panel too.
  await panel.getByRole("button", { name: /^Pin / }).click();
  await expect(panel.getByTestId("work-chat-pinned")).toBeVisible();
  await expectInsidePanel("empty work-chat-pinned", panel.getByTestId("work-chat-pinned"));
  await expectInsidePanel("empty Unpin button", panel.getByRole("button", { name: /^Unpin / }));
  await panel.getByRole("button", { name: /^Unpin / }).click();
  await expect(panel.getByTestId("work-chat-subject")).toBeVisible();

  // Active conversation state: chips above the composer must also stay inside the panel.
  await panel.getByRole("button", { name: "Start a chat" }).click();
  await expect(panel.getByRole("combobox", { name: "Message" })).toBeVisible();
  await expectInsidePanel("active dock-context", panel.getByTestId("dock-context"));
  await expectInsidePanel("active dock-chat-to", panel.getByTestId("dock-chat-to"));
  await expectInsidePanel("active work-chat-subject", panel.getByTestId("work-chat-subject"));
  await expectInsidePanel("active Pin button", panel.getByRole("button", { name: /^Pin / }));
});
