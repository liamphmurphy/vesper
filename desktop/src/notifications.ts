export interface InboxItemSummary {
  id: string;
  kind: string;
  title: string;
  summary?: string;
  href: string;
  ticket_key?: string;
  created_at: string;
  resolved: boolean;
  read: boolean;
  needs_you: boolean;
  agent?: { name?: string };
}

export interface DesktopAlert {
  title: string;
  body: string;
  href: string;
  signature: string;
}

const KIND_LABELS: Record<string, string> = {
  approval: "Approval needed",
  question: "Question",
  blocked: "Run failed",
  stalled: "Run stalled",
  mockup: "Mockup review",
  planning: "Proposal",
  review: "Review ready",
  dispatch: "Ready to start",
  mention: "Mention",
  suggestion: "Wiki edit",
  workflow_gate: "Workflow gate",
  scheduled: "Scheduled task",
  connector_approval: "Connector approval",
  secret_approval: "Secret approval",
  secret_expiring: "Secret expiring",
  merged: "PR merged",
  pr_approved: "PR approved",
  drive_backup: "Backup failed",
};

const NOTIFIABLE_KINDS = new Set([
  "approval",
  "question",
  "blocked",
  "stalled",
  "mockup",
  "planning",
  "review",
  "workflow_gate",
  "connector_approval",
  "secret_approval",
  "merged",
  "pr_approved",
  "drive_backup",
]);

export function countNeedsYou(items: readonly InboxItemSummary[]): number {
  let count = 0;
  for (const item of items) {
    if (!item.resolved && !item.read && item.needs_you) {
      count += 1;
    }
  }
  return count;
}

export function formatDockBadge(count: number): string {
  if (!Number.isFinite(count) || count <= 0) return "";
  return count > 99 ? "99+" : String(Math.floor(count));
}

export function itemSignature(item: InboxItemSummary): string {
  return `${item.id}:${item.created_at}`;
}

/**
 * Computes the current Needs-you badge count and any new OS notifications to fire.
 * When baselineInitialized is false, existing open items are recorded without firing alerts
 * so app startup doesn't flood Notification Center with stale items.
 */
export function collectNewNotifications(
  seenSignatures: Set<string>,
  items: readonly InboxItemSummary[],
  baselineInitialized: boolean,
): { badgeCount: number; alerts: DesktopAlert[] } {
  const badgeCount = countNeedsYou(items);
  const alerts: DesktopAlert[] = [];

  for (const item of items) {
    if (item.resolved || item.read) continue;
    const signature = itemSignature(item);
    const alreadySeen = seenSignatures.has(signature);
    seenSignatures.add(signature);

    if (!baselineInitialized || alreadySeen) continue;
    if (!item.needs_you && !NOTIFIABLE_KINDS.has(item.kind)) continue;

    const kindLabel = KIND_LABELS[item.kind] ?? "Vesper";
    const title = `${kindLabel}: ${item.title}`;
    const bodyParts = [item.agent?.name, item.ticket_key, item.summary?.trim()].filter(
      (part): part is string => Boolean(part && part.length > 0),
    );
    alerts.push({
      title,
      body: bodyParts.join(" · ") || "Open in Vesper",
      href: item.href || "/inbox",
      signature,
    });
  }

  return { badgeCount, alerts };
}

export function shouldRefreshInboxForSseEvent(eventType: string): boolean {
  if (eventType === "reset") return true;
  const entity = eventType.split(".")[0];
  return entity === "inbox" || entity === "run" || entity === "approval" || entity === "ticket" || entity === "workflow";
}

export interface InboxMonitorDeps {
  fetch: (url: string, init?: RequestInit) => Promise<Response>;
  onBadgeChange: (badge: string, count: number) => void;
  onAlert: (alert: DesktopAlert) => void;
  shouldNotify?: (href: string) => boolean;
  pollIntervalMs?: number;
}

/**
 * Watches Vesper's /api/v1/inbox and /events stream using the persistent Electron session
 * so Dock badges and macOS notifications stay accurate even when tabs are backgrounded.
 */
export class InboxMonitor {
  private readonly deps: InboxMonitorDeps;
  private readonly seenSignatures = new Set<string>();
  private baselineInitialized = false;
  private serverUrl = "";
  private stopped = false;
  private pollTimer: NodeJS.Timeout | undefined;
  private sseAbort: AbortController | undefined;
  private sseReconnectTimer: NodeJS.Timeout | undefined;
  private refreshing = false;
  private refreshPending = false;

  constructor(deps: InboxMonitorDeps) {
    this.deps = deps;
  }

  start(serverUrl: string): void {
    this.stop();
    this.stopped = false;
    this.serverUrl = serverUrl.replace(/\/+$/, "");
    this.seenSignatures.clear();
    this.baselineInitialized = false;

    void this.refreshNow();
    this.connectSse();
    const intervalMs = this.deps.pollIntervalMs ?? 30_000;
    this.pollTimer = setInterval(() => {
      void this.refreshNow();
    }, intervalMs);
  }

  stop(): void {
    this.stopped = true;
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
    if (this.sseReconnectTimer) {
      clearTimeout(this.sseReconnectTimer);
      this.sseReconnectTimer = undefined;
    }
    this.sseAbort?.abort();
    this.sseAbort = undefined;
  }

  async refreshNow(): Promise<void> {
    if (this.stopped || !this.serverUrl) return;
    if (this.refreshing) {
      this.refreshPending = true;
      return;
    }
    this.refreshing = true;
    try {
      const response = await this.deps.fetch(`${this.serverUrl}/api/v1/inbox`, {
        method: "GET",
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) {
        if (response.status === 401 || response.status === 403) {
          this.deps.onBadgeChange("", 0);
        }
        return;
      }
      const data = (await response.json()) as { items?: InboxItemSummary[] };
      const items = Array.isArray(data?.items) ? data.items : [];
      const { badgeCount, alerts } = collectNewNotifications(this.seenSignatures, items, this.baselineInitialized);
      this.baselineInitialized = true;
      this.deps.onBadgeChange(formatDockBadge(badgeCount), badgeCount);

      for (const alert of alerts) {
        if (!this.deps.shouldNotify || this.deps.shouldNotify(alert.href)) {
          this.deps.onAlert(alert);
        }
      }
    } catch {
      // Server unreachable or offline: degrade silently without noisy errors.
    } finally {
      this.refreshing = false;
      if (this.refreshPending && !this.stopped) {
        this.refreshPending = false;
        void this.refreshNow();
      }
    }
  }

  private connectSse(): void {
    if (this.stopped || !this.serverUrl) return;
    this.sseAbort?.abort();
    const controller = new AbortController();
    this.sseAbort = controller;

    void (async () => {
      try {
        const res = await this.deps.fetch(`${this.serverUrl}/events`, {
          method: "GET",
          headers: { Accept: "text/event-stream" },
          signal: controller.signal,
        });
        if (!res.ok || !res.body) {
          this.scheduleSseReconnect();
          return;
        }
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!this.stopped && !controller.signal.aborted) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const frames = buffer.split(/\r?\n\r?\n/);
          buffer = frames.pop() ?? "";
          for (const frame of frames) {
            for (const line of frame.split(/\r?\n/)) {
              if (!line.startsWith("data:")) continue;
              const raw = line.slice(5).trim();
              if (!raw) continue;
              try {
                const payload = JSON.parse(raw) as { type?: unknown };
                if (typeof payload.type === "string" && shouldRefreshInboxForSseEvent(payload.type)) {
                  void this.refreshNow();
                }
              } catch {
                // Ignore malformed SSE frames.
              }
            }
          }
        }
      } catch {
        // Ignore aborts and transient network drops.
      }
      if (!this.stopped) {
        this.scheduleSseReconnect();
      }
    })();
  }

  private scheduleSseReconnect(): void {
    if (this.stopped || this.sseReconnectTimer) return;
    this.sseReconnectTimer = setTimeout(() => {
      this.sseReconnectTimer = undefined;
      this.connectSse();
    }, 5000);
  }
}
