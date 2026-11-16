import assert from "node:assert/strict";
import test from "node:test";
import {
  collectNewNotifications,
  countNeedsYou,
  formatDockBadge,
  InboxMonitor,
  shouldRefreshInboxForSseEvent,
} from "../dist/notifications.js";

test("countNeedsYou and formatDockBadge handle open, read, resolved, and 99+ overflow", () => {
  const items = [
    { id: "1", kind: "approval", title: "Approve push", href: "/inbox", created_at: "2026-11-16T00:00:00Z", resolved: false, read: false, needs_you: true },
    { id: "2", kind: "question", title: "Question", href: "/runs/1", created_at: "2026-11-16T00:00:00Z", resolved: true, read: false, needs_you: true },
    { id: "3", kind: "merged", title: "PR merged", href: "/tickets/1", created_at: "2026-11-16T00:00:00Z", resolved: false, read: false, needs_you: false },
    { id: "4", kind: "review", title: "Review", href: "/tickets/2", created_at: "2026-11-16T00:00:00Z", resolved: false, read: true, needs_you: true },
  ];

  assert.equal(countNeedsYou(items), 1);
  assert.equal(formatDockBadge(0), "");
  assert.equal(formatDockBadge(-2), "");
  assert.equal(formatDockBadge(5), "5");
  assert.equal(formatDockBadge(99), "99");
  assert.equal(formatDockBadge(140), "99+");
});

test("collectNewNotifications suppresses startup flood on baseline and fires on new or updated items", () => {
  const seen = new Set();
  const initial = [
    {
      id: "item-1",
      kind: "approval",
      title: "Push feat/desktop",
      summary: "Needs approval",
      href: "/chat/1",
      created_at: "2026-11-16T01:00:00Z",
      resolved: false,
      read: false,
      needs_you: true,
      agent: { name: "Meow" },
    },
  ];

  const first = collectNewNotifications(seen, initial, false);
  assert.equal(first.badgeCount, 1);
  assert.equal(first.alerts.length, 0);

  const second = collectNewNotifications(
    seen,
    [
      ...initial,
      {
        id: "item-2",
        kind: "question",
        title: "Which target arch?",
        summary: "arm64 or universal?",
        href: "/tickets/LAZYAGENTS-232",
        ticket_key: "LAZYAGENTS-232",
        created_at: "2026-11-16T01:05:00Z",
        resolved: false,
        read: false,
        needs_you: true,
        agent: { name: "Tech Lead" },
      },
    ],
    true,
  );
  assert.equal(second.badgeCount, 2);
  assert.equal(second.alerts.length, 1);
  assert.equal(second.alerts[0].title, "Question: Which target arch?");
  assert.equal(second.alerts[0].body, "Tech Lead · LAZYAGENTS-232 · arm64 or universal?");
  assert.equal(second.alerts[0].href, "/tickets/LAZYAGENTS-232");
});

test("shouldRefreshInboxForSseEvent matches relevant server event prefixes", () => {
  assert.equal(shouldRefreshInboxForSseEvent("reset"), true);
  assert.equal(shouldRefreshInboxForSseEvent("inbox.updated"), true);
  assert.equal(shouldRefreshInboxForSseEvent("run.completed"), true);
  assert.equal(shouldRefreshInboxForSseEvent("approval.requested"), true);
  assert.equal(shouldRefreshInboxForSseEvent("video.updated"), false);
});

test("InboxMonitor updates badge and fires alerts from polled inbox", async () => {
  let callCount = 0;
  const badges = [];
  const alerts = [];

  const monitor = new InboxMonitor({
    pollIntervalMs: 60_000,
    fetch: async (url) => {
      if (url.endsWith("/events")) {
        return new Response(null, { status: 404 });
      }
      callCount += 1;
      const items =
        callCount === 1
          ? [
              {
                id: "a",
                kind: "approval",
                title: "Initial",
                href: "/inbox",
                created_at: "2026-11-16T00:00:00Z",
                resolved: false,
                read: false,
                needs_you: true,
              },
            ]
          : [
              {
                id: "a",
                kind: "approval",
                title: "Initial",
                href: "/inbox",
                created_at: "2026-11-16T00:00:00Z",
                resolved: false,
                read: false,
                needs_you: true,
              },
              {
                id: "b",
                kind: "blocked",
                title: "Build failed",
                summary: "Exit 1",
                href: "/runs/99",
                created_at: "2026-11-16T00:02:00Z",
                resolved: false,
                read: false,
                needs_you: true,
              },
            ];
      return new Response(JSON.stringify({ items }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
    onBadgeChange: (badge, count) => badges.push({ badge, count }),
    onAlert: (alert) => alerts.push(alert),
  });

  monitor.start("http://localhost:8080");
  await new Promise((r) => setTimeout(r, 20));
  await monitor.refreshNow();
  monitor.stop();

  assert.deepEqual(badges, [
    { badge: "1", count: 1 },
    { badge: "2", count: 2 },
  ]);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].href, "/runs/99");
});
