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
  agent?: { name?: string; handle?: string };
  run_id?: string;
}

export interface DesktopAlert {
  title: string;
  body: string;
  href: string;
  signature: string;
  /** Inbox kind, or "run_finished" for run-finished alerts. */
  kind: string;
  /** Inbox item id (e.g. "approval:<uuid>"); empty for run-finished alerts. */
  itemId: string;
  runId?: string;
  ticketKey?: string;
  agentHandle?: string;
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
      kind: item.kind,
      itemId: item.id,
      ...(item.run_id ? { runId: item.run_id } : {}),
      ...(item.ticket_key ? { ticketKey: item.ticket_key } : {}),
      ...(item.agent?.handle ? { agentHandle: item.agent.handle } : {}),
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
  /** Every successful inbox read, for the tray's Needs-you list. */
  onItems?: (items: readonly InboxItemSummary[]) => void;
  /** Every SSE event type seen, so other monitors (runs) can refresh without their own stream. */
  onServerEvent?: (eventType: string) => void;
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
      this.deps.onItems?.(items);

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
                if (typeof payload.type === "string") {
                  this.deps.onServerEvent?.(payload.type);
                  if (shouldRefreshInboxForSseEvent(payload.type)) {
                    void this.refreshNow();
                  }
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

// ---------------------------------------------------------------- policy (LAZYAGENTS-241)

export interface NotificationPolicy {
  enabled: boolean;
  kinds: Record<string, boolean>;
  actions: boolean;
  groupByWork: boolean;
  runFinished: boolean;
  sound: boolean;
  quietHours: { enabled: boolean; start: string; end: string };
}

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}

/**
 * Whether `now` (local time) falls in the quiet window. The window may cross
 * midnight (22:00–08:00). Equal start and end means no quiet time at all.
 */
export function isWithinQuietHours(now: Date, quiet: { enabled: boolean; start: string; end: string }): boolean {
  if (!quiet.enabled) return false;
  const start = minutesOf(quiet.start);
  const end = minutesOf(quiet.end);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start === end) return false;
  const cur = now.getHours() * 60 + now.getMinutes();
  return start < end ? cur >= start && cur < end : cur >= start || cur < end;
}

/** Whether an alert should be shown at all. Suppressed alerts are still marked seen, so they never fire late. */
export function shouldShowAlert(alert: DesktopAlert, policy: NotificationPolicy, now: Date): boolean {
  if (!policy.enabled) return false;
  if (isWithinQuietHours(now, policy.quietHours)) return false;
  if (alert.kind === "run_finished") return policy.runFinished;
  return policy.kinds[alert.kind] !== false;
}

/**
 * Notification Center thread for an alert: everything about one run (or, when
 * there's no run, one ticket) stacks together. Null when grouping is off or
 * there's nothing to group by.
 */
export function alertGroupId(alert: DesktopAlert, policy: Pick<NotificationPolicy, "groupByWork">): string | null {
  if (!policy.groupByWork) return null;
  if (alert.ticketKey) return `ticket:${alert.ticketKey}`;
  if (alert.runId) return `run:${alert.runId}`;
  return null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type AlertAction = { type: "decide"; labels: [string, string] } | { type: "reply"; placeholder: string } | { type: "none" };

/**
 * Which inline controls a notification gets. Approvals of every kind get
 * Approve/Decline; a run's question gets an inline Reply (sent as a ticket
 * comment mentioning the agent, the same way the run page replies).
 */
export function alertActionFor(alert: DesktopAlert, policy: Pick<NotificationPolicy, "actions">): AlertAction {
  if (!policy.actions) return { type: "none" };
  if (decisionRequest(alert, "approve")) return { type: "decide", labels: ["Approve", "Decline"] };
  if (alert.kind === "question" && alert.ticketKey && alert.agentHandle) {
    return { type: "reply", placeholder: `Reply to ${alert.agentHandle}` };
  }
  return { type: "none" };
}

export interface ApiRequest {
  method: "POST";
  path: string;
  body: Record<string, unknown>;
}

/** The existing API call that approves or declines an inbox item, or null when it can't be decided from a notification. */
export function decisionRequest(alert: DesktopAlert, decision: "approve" | "deny"): ApiRequest | null {
  const [prefix, id, ...rest] = alert.itemId.split(":");
  if (rest.length > 0 || !id || !UUID_RE.test(id)) return null;
  switch (prefix) {
    case "approval":
      if (alert.kind !== "approval") return null;
      return { method: "POST", path: `/api/v1/approvals/${id}/${decision}`, body: {} };
    case "connector_approval":
      if (alert.kind !== "connector_approval") return null;
      return { method: "POST", path: `/api/v1/connector-approvals/${id}`, body: { decision: decision === "approve" ? "allow" : "deny" } };
    case "secret_approval":
      if (alert.kind !== "secret_approval") return null;
      return { method: "POST", path: `/api/v1/api-secret-approvals/${id}`, body: { decision: decision === "approve" ? "allow" : "deny" } };
    default:
      return null;
  }
}

const TICKET_KEY_RE = /^[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}$/;
const HANDLE_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

/** A reply to a run's question: a ticket comment mentioning the agent (as web/lib/run-question.ts withMention does). */
export function replyRequest(alert: DesktopAlert, reply: string): ApiRequest | null {
  const text = reply.trim();
  if (!text || text.length > 20_000) return null;
  if (alert.kind !== "question" || !alert.ticketKey || !alert.agentHandle) return null;
  if (!TICKET_KEY_RE.test(alert.ticketKey) || !HANDLE_RE.test(alert.agentHandle)) return null;
  const escaped = alert.agentHandle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const mentioned = new RegExp(`(^|[^\\w@])@${escaped}(?![\\w-])`, "i").test(text);
  return {
    method: "POST",
    path: `/api/v1/tickets/${alert.ticketKey}/comments`,
    body: { body_md: mentioned ? text : `@${alert.agentHandle} ${text}` },
  };
}

/** The Touch ID scope (LAZYAGENTS-248) an inbox approval kind falls under. */
export function touchIdScopeForKind(kind: string): "run_approvals" | "connector_approvals" | "secret_approvals" | null {
  switch (kind) {
    case "approval":
      return "run_approvals";
    case "connector_approval":
      return "connector_approvals";
    case "secret_approval":
      return "secret_approvals";
    default:
      return null;
  }
}
