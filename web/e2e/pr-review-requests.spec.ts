import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";

type S = components["schemas"];

function sampleRequests(): S["GitHubReviewRequest"][] {
  return [
    {
      id: "acme/web#11",
      number: 11,
      title: "Fix sidebar scroll",
      url: "https://github.com/acme/web/pull/11",
      repository: "acme/web",
      author_login: "alex-kim",
      draft: false,
      direct: true,
      team: false,
      additions: 14,
      deletions: 3,
      created_at: "2026-11-18T09:00:00Z",
      updated_at: "2026-11-18T10:00:00Z",
    },
    {
      id: "acme/api#22",
      number: 22,
      title: "Add rate limiter",
      url: "https://github.com/acme/api/pull/22",
      repository: "acme/api",
      author_login: "maya",
      draft: false,
      direct: true,
      team: true,
      teams: ["@backend"],
      additions: 48,
      deletions: 12,
      created_at: "2026-11-18T09:30:00Z",
      updated_at: "2026-11-18T11:00:00Z",
    },
    {
      id: "acme/docs#33",
      number: 33,
      title: "Update CLI guide",
      url: "https://github.com/acme/docs/pull/33",
      repository: "acme/docs",
      author_login: "sam",
      draft: false,
      direct: false,
      team: true,
      teams: ["@docs"],
      additions: 9,
      deletions: 2,
      created_at: "2026-11-18T09:45:00Z",
      updated_at: "2026-11-18T11:30:00Z",
    },
  ];
}

async function installReviewApi(page: Page) {
  const board = await installBoardApi(page);
  let items = sampleRequests();
  const reads: string[] = [];
  board.inbox.push({
    id: "pr_approved:1",
    kind: "pr_approved",
    title: "PR #9 approved",
    summary: "acme/web · Ready to merge",
    href: "https://github.com/acme/web/pull/9",
    project: "WEB",
    ticket_key: "",
    needs_you: false,
    resolved: false,
    read: false,
    created_at: "2026-11-18T11:45:00Z",
  });

  await page.route(/\/api\/v1\/(github\/review-requests|inbox\/read|dev-workspace)/, async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    if (path === "/dev-workspace") {
      return route.fulfill({ json: { enabled: false, nix_mode: "default", repos: [], extra_packages: [] } });
    }
    if (path === "/github/review-requests") {
      return route.fulfill({
        json: {
          configured: true,
          viewer_login: "liam",
          synced_at: "2026-11-18T12:00:00Z",
          items,
        } satisfies S["GitHubReviewRequestsResponse"],
      });
    }
    if (path === "/inbox/read" && req.method() === "POST") {
      const { id } = req.postDataJSON() as { id: string };
      reads.push(id);
      const item = board.inbox.find((i) => i.id === id);
      if (item) item.read = true;
      return route.fulfill({ status: 204 });
    }
    return route.fallback();
  });

  return {
    board,
    reads,
    setUpdatedAt(id: string, updatedAt: string) {
      items = items.map((item) => (item.id === id ? { ...item, updated_at: updatedAt } : item));
    },
  };
}

test("NativeRail supports per-PR dismiss, Clear all, Restore, and updated_at reappearance", async ({ page }) => {
  await page.addInitScript(() => {
    const messages: unknown[] = [];
    Object.assign(window, {
      __VESPER_NATIVE__: { v: 1, platform: "macos" },
      __nativeMessages: messages,
      webkit: {
        messageHandlers: {
          vesper: {
            postMessage: (msg: unknown) => messages.push(msg),
          },
        },
      },
    });
  });

  const api = await installReviewApi(page);
  await page.goto("/tickets?project=WEB");

  const lastPrRail = async () =>
    page.evaluate(() => {
      const msgs = (window as unknown as { __nativeMessages: Array<{ type: string; model?: { middle?: Array<{ id: string; badge?: { text?: string; tone?: string }; menu?: Array<{ id: string; label?: string; children?: Array<{ id: string }> }> }> } }> }).__nativeMessages;
      const rails = msgs.filter((m) => m.type === "rail" && m.model);
      return rails.at(-1)?.model?.middle?.find((item) => item.id === "pr");
    });

  await expect.poll(async () => (await lastPrRail())?.badge).toEqual({ text: "3", tone: "accent" });
  const initial = await lastPrRail();
  expect(initial?.menu?.some((m) => m.id === "pr.clear")).toBe(true);
  expect(initial?.menu?.find((m) => m.id === "pr.dismiss")?.children?.map((c) => c.id)).toEqual([
    "pr.dismiss:acme/web#11",
    "pr.dismiss:acme/api#22",
    "pr.dismiss:acme/docs#33",
  ]);

  const sendRailAction = (menuItemId: string) =>
    page.evaluate((id) => {
      window.dispatchEvent(new CustomEvent("vesper-native", { detail: { v: 1, type: "rail.action", itemId: "pr", menuItemId: id } }));
    }, menuItemId);

  // Per-PR dismiss in NativeRail updates badge and menu.
  await sendRailAction("pr.dismiss:acme/web#11");
  await expect.poll(async () => (await lastPrRail())?.badge).toEqual({ text: "2", tone: "accent" });
  expect((await lastPrRail())?.menu?.some((m) => m.id === "pr:acme/web#11")).toBe(false);

  // Changing updated_at + refreshing brings it back.
  api.setUpdatedAt("acme/web#11", "2026-11-18T12:10:00Z");
  await sendRailAction("pr.refresh");
  await expect.poll(async () => (await lastPrRail())?.badge).toEqual({ text: "3", tone: "accent" });

  // Clear all leaves approved green badge and offers Restore dismissed.
  await sendRailAction("pr.clear");
  await expect.poll(async () => (await lastPrRail())?.badge).toEqual({ text: "1", tone: "done" });
  await expect.poll(async () => (await lastPrRail())?.menu?.find((m) => m.id === "pr.restore")?.label).toBe("Restore dismissed (3)");

  // Restore brings all 3 back.
  await sendRailAction("pr.restore");
  await expect.poll(async () => (await lastPrRail())?.badge).toEqual({ text: "3", tone: "accent" });
  expect(api.board.unhandled).toEqual([]);
});
