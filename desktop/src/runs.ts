import type { DesktopAlert } from "./notifications";

/** The fields of an API Run the desktop uses. */
export interface RunSummary {
  id: string;
  state: string;
  purpose: string;
  ticket_key?: string;
  work_title?: string;
  wait_reason?: string;
  outcome?: string;
  agent?: { name?: string; handle?: string };
}

/** States in GET /runs?state=live. */
export const LIVE_STATES = new Set(["queued", "starting", "running", "waiting", "waiting_for_quota", "paused"]);
/** States a run that was live can end in. */
export const TERMINAL_STATES = new Set(["completed", "failed", "blocked", "cancelled"]);
/** Purposes whose end deserves an alert. A chat run ends after every reply, so it would be noise. */
const ALERT_PURPOSES = new Set(["ticket", "planning", "research", "workflow"]);

/** Runs doing work right now: they keep the Mac awake and show under "Running" in the tray. */
export function isActive(run: RunSummary): boolean {
  return run.state === "starting" || run.state === "running" || (run.state === "waiting" && run.wait_reason === "checks");
}

/**
 * Finds runs that were live at the previous poll and have now ended, and
 * returns one alert per run, never twice for the same run (`notified` is
 * updated in place). Runs the person cancelled get no alert.
 */
export function detectFinishedRuns(
  previousLive: ReadonlyMap<string, RunSummary>,
  currentLive: readonly RunSummary[],
  recent: readonly RunSummary[],
  notified: Set<string>,
): DesktopAlert[] {
  const liveIds = new Set(currentLive.map((r) => r.id));
  const recentById = new Map(recent.map((r) => [r.id, r]));
  const alerts: DesktopAlert[] = [];
  for (const [id, before] of previousLive) {
    if (liveIds.has(id) || notified.has(id)) continue;
    const after = recentById.get(id);
    if (!after || !TERMINAL_STATES.has(after.state)) continue;
    notified.add(id);
    if (after.state === "cancelled" || !ALERT_PURPOSES.has(after.purpose || before.purpose)) continue;
    const what = after.work_title || before.work_title || after.ticket_key || "Run";
    const verb = after.state === "completed" ? "Run finished" : after.state === "blocked" ? "Run blocked" : "Run failed";
    const body = [after.agent?.name, after.ticket_key, after.outcome?.trim()].filter((p): p is string => Boolean(p)).join(" · ");
    alerts.push({
      title: `${verb}: ${what}`,
      body: body || "Open in Vesper",
      href: `/runs/${id}`,
      signature: `run_finished:${id}`,
      kind: "run_finished",
      itemId: "",
      runId: id,
      ...(after.ticket_key ? { ticketKey: after.ticket_key } : {}),
    });
  }
  return alerts;
}

/** Live runs the tray's "Pause runs" can pause: chat runs only cancel, and a run in its server checks can't pause. */
export function pausableRuns(runs: readonly RunSummary[]): RunSummary[] {
  return runs.filter(
    (r) => r.purpose !== "chat" && (r.state === "running" || (r.state === "waiting" && r.wait_reason !== "checks")),
  );
}

export function shouldRefreshRunsForSseEvent(eventType: string): boolean {
  return eventType === "reset" || eventType.split(".")[0] === "run";
}

export interface RunMonitorDeps {
  fetch: (url: string, init?: RequestInit) => Promise<Response>;
  onSnapshot: (live: readonly RunSummary[]) => void;
  onFinished: (alert: DesktopAlert) => void;
  pollIntervalMs?: number;
}

/**
 * Polls GET /api/v1/runs?state=live (and, when a run leaves that list, the
 * newest page of all runs to learn how it ended). Refreshes early on run.*
 * SSE events forwarded by the InboxMonitor.
 */
export class RunMonitor {
  private readonly deps: RunMonitorDeps;
  private serverUrl = "";
  private stopped = true;
  private timer: NodeJS.Timeout | undefined;
  private refreshing = false;
  private pending = false;
  private previousLive = new Map<string, RunSummary>();
  /** Runs that left the live list before their end state showed up, with how many polls they've waited. */
  private unresolved = new Map<string, number>();
  private readonly notified = new Set<string>();
  private latest: RunSummary[] = [];

  constructor(deps: RunMonitorDeps) {
    this.deps = deps;
  }

  start(serverUrl: string): void {
    this.stop();
    this.stopped = false;
    this.serverUrl = serverUrl.replace(/\/+$/, "");
    this.previousLive = new Map();
    this.unresolved = new Map();
    this.latest = [];
    void this.refreshNow();
    this.timer = setInterval(() => void this.refreshNow(), this.deps.pollIntervalMs ?? 20_000);
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  live(): readonly RunSummary[] {
    return this.latest;
  }

  async refreshNow(): Promise<void> {
    if (this.stopped || !this.serverUrl) return;
    if (this.refreshing) {
      this.pending = true;
      return;
    }
    this.refreshing = true;
    try {
      const live = await this.list("live");
      if (!live) return;
      const gone = [...this.previousLive.keys()].some((id) => !live.some((r) => r.id === id));
      const recent = gone ? ((await this.list("all")) ?? []) : [];
      const alerts = detectFinishedRuns(this.previousLive, live, recent, this.notified);
      const next = new Map(live.map((r) => [r.id, r]));
      // A run that left the live list but isn't on the newest page yet (or not
      // yet terminal) is checked again on the next few polls.
      for (const [id, before] of this.previousLive) {
        if (next.has(id) || this.notified.has(id)) {
          this.unresolved.delete(id);
          continue;
        }
        const tries = (this.unresolved.get(id) ?? 0) + 1;
        if (tries <= 3) {
          this.unresolved.set(id, tries);
          next.set(id, before);
        } else {
          this.unresolved.delete(id);
        }
      }
      this.previousLive = next;
      this.latest = live;
      this.deps.onSnapshot(live);
      for (const alert of alerts) this.deps.onFinished(alert);
    } catch {
      // Unreachable server: keep the last snapshot.
    } finally {
      this.refreshing = false;
      if (this.pending && !this.stopped) {
        this.pending = false;
        void this.refreshNow();
      }
    }
  }

  private async list(state: "live" | "all"): Promise<RunSummary[] | null> {
    const res = await this.deps.fetch(`${this.serverUrl}/api/v1/runs?state=${state}`, {
      method: "GET",
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) {
      void res.body?.cancel();
      return null;
    }
    const data = (await res.json()) as { runs?: RunSummary[] };
    return Array.isArray(data?.runs) ? data.runs : [];
  }
}
