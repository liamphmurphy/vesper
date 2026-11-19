"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import type { Ticket } from "@/lib/api/client";
import {
  hasLiveRun,
  useBootstrap,
  useCosts,
  useEpicOverviews,
  useRunLog,
  useRunPages,
  useTicket,
  useTicketRuns,
  useTickets,
} from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { duration, runCost } from "@/lib/format";
import { spendLabel } from "@/lib/costs";
import { startReady } from "@/lib/work-rows";
import { AgentAvatar } from "@/components/domain/avatars";
import { Markdown } from "@/components/domain/markdown";
import { STATUS_NAME } from "@/components/domain/meta";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { TicketEditorDialog } from "@/components/domain/ticket-editor-dialog";
import { Button } from "@/components/ui/button";
import { Banner } from "@/components/ui/primitives";
import { RunThread } from "../runs/[id]/run-thread";

type Patch = Record<string, string | null>;
export type Navigate = (patch: Patch) => void;

export function LoadState({
  query,
}: {
  query: {
    isPending: boolean;
    isError: boolean;
    error: Error | null;
    refetch: () => unknown;
  };
}) {
  return query.isError ? (
    <Banner
      tone="blocked"
      title="Couldn't load work"
      actions={<Button onClick={() => query.refetch()}>Retry</Button>}
    >
      {query.error?.message}
    </Banner>
  ) : query.isPending ? (
    <p role="status" className="p-5 text-13 text-fg-tertiary">
      Loading work…
    </p>
  ) : null;
}

function AttemptHistory({ t, navigate }: { t: Ticket; navigate: Navigate }) {
  const query = useTicketRuns(t.key, hasLiveRun(t));
  return (
    <section className="work-attempts">
      <h2>Run history</h2>
      <LoadState query={query} />
      {query.data?.runs.map((r, index, runs) => (
        <button
          key={r.id}
          onClick={() =>
            navigate({ run: r.id, view: "activity", context: null })
          }
          className="work-attempt"
        >
          <span>
            <strong>
              Attempt {runs.length - index}
              {query.data?.has_more ? "+" : ""} · {r.state}
            </strong>
            <small>
              {r.agent.name} · {r.harness} ·{" "}
              {duration(r.started_at, r.ended_at)} ·{" "}
              {runCost(r.cost_usd, r.cost_source)}
            </small>
          </span>
          <span>View run →</span>
        </button>
      ))}
      {query.data?.runs.length === 0 && (
        <p className="text-13 text-fg-tertiary">No runs yet.</p>
      )}
      {query.data?.has_more && (
        <Button
          onClick={() =>
            navigate({ view: "activity", context: null, ticket: null })
          }
        >
          All activity →
        </Button>
      )}
    </section>
  );
}

export function TicketBrief({
  ticketKey,
  navigate,
  focused,
}: {
  ticketKey: string;
  navigate: Navigate;
  focused: boolean;
}) {
  const query = useTicket(ticketKey);
  const boot = useBootstrap();
  const t = query.data;
  const [editing, setEditing] = useState(false);
  const [dispatching, setDispatching] = useState(false);
  return (
    <>
      <LoadState query={query} />
      {t && (
        <article className={cx("work-brief", focused && "work-focused")}>
          <p
            className={cx(
              "work-breadcrumb",
              !focused && "work-context-breadcrumb",
            )}
          >
            {t.epic && (
              <button
                onClick={() =>
                  navigate({
                    epic: t.epic!.id,
                    context: focused ? null : "epic",
                    ...(focused ? { view: "epics" } : {}),
                  })
                }
              >
                {t.epic.name} /{" "}
              </button>
            )}
            {t.key}
          </p>
          <h1>{t.title}</h1>
          <div className="work-meta">
            <span>{STATUS_NAME[t.status]}</span>
            {t.assignee && (
              <span className="flex items-center gap-2">
                <AgentAvatar
                  name={t.assignee.name}
                  colorIndex={t.assignee.color_index}
                  label={false}
                />
                {t.assignee.name}
              </span>
            )}
            <Button variant="ghost" onClick={() => setEditing(true)}>
              Edit
            </Button>
            {!hasLiveRun(t) &&
              t.status !== "done" &&
              t.status !== "canceled" && (
                <Button
                  variant="outline"
                  disabled={!t.assignee || t.project.archived}
                  onClick={() => setDispatching(true)}
                >
                  Start run
                </Button>
              )}
          </div>
          {!focused && t.epic && (
            <section>
              <h2>Epic</h2>
              <button
                className="text-accent"
                onClick={() => navigate({ epic: t.epic!.id, context: "epic" })}
              >
                {t.epic.name} →
              </button>
            </section>
          )}
          <div className="work-description">
            <Markdown>{t.description_md || "No description yet."}</Markdown>
          </div>
          <section>
            <h2>
              Acceptance criteria{" "}
              <span className="text-fg-tertiary">
                {t.criteria.filter((c) => c.done).length} / {t.criteria.length}
              </span>
            </h2>
            <ul className="work-criteria">
              {[...t.criteria]
                .sort((a, b) => a.position - b.position)
                .map((c) => (
                  <li key={c.id}>
                    <span
                      className={
                        c.done ? "text-state-done" : "text-fg-tertiary"
                      }
                    >
                      {c.done ? "✓" : "○"}
                    </span>
                    {c.text}
                  </li>
                ))}
            </ul>
          </section>
          <AttemptHistory t={t} navigate={navigate} />
          <p className="text-12 text-fg-tertiary">
            Blocked by:{" "}
            {t.blocked_by
              .filter((b) => b.status !== "done")
              .map((b) => b.key)
              .join(", ") || "none"}{" "}
            · Estimate: {t.estimate_points ?? "—"} points · Priority:{" "}
            {t.priority}
          </p>
          <Link
            className="text-12 text-fg-tertiary hover:text-fg"
            href={`/tickets/${t.key}?full=1`}
          >
            Activity &amp; more details →
          </Link>
          {t.pr && (
            <a className="text-accent" href={t.pr.url}>
              PR #{t.pr.number} ↗
            </a>
          )}
          {!focused && (
            <Button
              variant="outline"
              onClick={() => navigate({ view: "tickets", context: null })}
            >
              Focus ticket →
            </Button>
          )}
          {editing && boot.data && (
            <TicketEditorDialog
              ticketKey={t.key}
              detail={t}
              bootstrap={boot.data}
              onClose={() => setEditing(false)}
              onReload={async () => {
                const r = await query.refetch();
                return r.isError ? undefined : r.data;
              }}
            />
          )}
          {dispatching && (
            <DispatchDialog keys={[t.key]} open onOpenChange={setDispatching} />
          )}
        </article>
      )}
    </>
  );
}

export function EpicBrief({
  epicId,
  navigate,
  focused,
}: {
  epicId: string;
  navigate: Navigate;
  focused: boolean;
}) {
  const query = useEpicOverviews();
  const e = query.data?.find((e) => e.epic.id === epicId);
  const tickets = useTickets({ epic: epicId, view: "all" });
  const spend = useCosts({ epic: epicId });
  const [dispatching, setDispatching] = useState(false);
  const [live] = useRunPages({ state: "live", project: e?.project.key }, 1);
  const liveKeys = new Set((live.data?.runs ?? []).map((r) => r.ticket_key));
  const readiness = startReady(tickets.data ?? [], liveKeys);
  const ready = readiness.ready.filter((t) => t.assignee);
  return (
    <>
      <LoadState query={query} />
      {!query.isPending && !query.isError && !e && (
        <p className="p-5">Epic not found.</p>
      )}
      {e && (
        <article className={cx("work-brief", focused && "work-focused")}>
          <p
            className={cx(
              "work-breadcrumb",
              !focused && "work-context-breadcrumb",
            )}
          >
            Epic / {e.project.name}
          </p>
          <h1>{e.epic.name}</h1>
          <div className="work-description">
            <Markdown>{e.objective}</Markdown>
          </div>
          <section>
            <div
              role="progressbar"
              aria-label="Epic progress"
              aria-valuenow={e.counts.done}
              aria-valuemin={0}
              aria-valuemax={e.counts.total}
              className="work-progress"
            >
              <div
                style={{
                  width: `${e.counts.total ? (e.counts.done / e.counts.total) * 100 : 0}%`,
                }}
              />
            </div>
            <p className="mt-4 text-13 text-fg-secondary">
              {e.counts.done} done · {e.counts.in_progress} in progress ·{" "}
              {ready.length} ready · {readiness.blocked.length} blocked
            </p>
          </section>
          {focused && (
            <p className="text-12 text-fg-tertiary">
              Spend so far{" "}
              {spend.data
                ? spendLabel(
                    spend.data.total.cost_micros,
                    spend.data.unpriced_runs,
                  )
                : spend.isError
                  ? "unavailable"
                  : "…"}
            </p>
          )}
          <section>
            <h2>Tickets</h2>
            <LoadState query={tickets} />
            <LoadState query={live} />
            <ul className="work-epic-tickets">
              {tickets.data?.map((t) => (
                <li key={t.key}>
                  <button
                    onClick={() =>
                      navigate({
                        ticket: t.key,
                        context: focused ? null : "ticket",
                        ...(focused ? { view: "tickets" } : {}),
                      })
                    }
                  >
                    <span
                      className={
                        t.status === "done"
                          ? "text-state-done"
                          : "text-fg-tertiary"
                      }
                    >
                      {t.status === "done"
                        ? "✓"
                        : t.status === "in_progress"
                          ? "●"
                          : "○"}
                    </span>
                    <span>{t.title}</span>
                    <small>
                      {t.unmet_dependencies ? "Blocked" : STATUS_NAME[t.status]}
                    </small>
                  </button>
                </li>
              ))}
            </ul>
          </section>
          {focused ? (
            <div className="work-ready">
              <div>
                <strong>
                  {ready.length} ticket{ready.length === 1 ? " is" : "s are"}{" "}
                  ready to start
                </strong>
                <p className="text-12 text-fg-tertiary">
                  Tickets with unmet dependencies wait for their blockers.
                </p>
              </div>
              <Button
                variant="approve"
                disabled={
                  !ready.length ||
                  e.project.archived ||
                  !tickets.isSuccess ||
                  !live.isSuccess
                }
                onClick={() => setDispatching(true)}
              >
                Start ready
              </Button>
            </div>
          ) : (
            <Button
              variant="outline"
              onClick={() => navigate({ view: "epics", context: null })}
            >
              Focus epic →
            </Button>
          )}
          <Link
            className="text-12 text-fg-tertiary hover:text-fg"
            href={`/epics/${epicId}?full=1`}
          >
            Criteria &amp; more details →
          </Link>
          {dispatching && (
            <DispatchDialog
              keys={ready.map((t) => t.key)}
              open
              onOpenChange={setDispatching}
            />
          )}
        </article>
      )}
    </>
  );
}

function WorkRunLinks({
  id,
  ticketKey,
  epic,
  companion,
  context,
  navigate,
}: {
  id: string;
  ticketKey?: string | null;
  epic?: { id: string; name: string } | null;
  companion: boolean;
  context?: string | null;
  navigate: Navigate;
}) {
  return (
    <div className="work-run-links">
      {ticketKey && (
        <button
          type="button"
          onClick={() =>
            navigate({
              ticket: ticketKey,
              context: companion ? null : "ticket",
              ...(companion ? { view: "tickets" } : {}),
            })
          }
        >
          {ticketKey} ↗
        </button>
      )}
      {epic && (
        <button
          type="button"
          onClick={() =>
            navigate({
              epic: epic.id,
              context: companion ? null : "epic",
              ...(companion ? { view: "epics" } : {}),
            })
          }
        >
          {epic.name}
        </button>
      )}
      {!companion && ticketKey && (
        <button
          type="button"
          aria-pressed={context === "ticket"}
          className="ml-auto"
          onClick={() =>
            navigate({
              ticket: ticketKey,
              context: context === "ticket" ? null : "ticket",
            })
          }
        >
          Details ◧
        </button>
      )}
      <Link
        className="text-fg-tertiary hover:text-fg"
        href={`/runs/${id}?view=details`}
      >
        Run details →
      </Link>
    </div>
  );
}

export function LiveRun({
  id,
  companion,
  navigate,
}: {
  id: string;
  companion: boolean;
  navigate: Navigate;
}) {
  const router = useRouter();
  const query = useRunLog(id);
  const t = useTicket(query.data?.run.ticket_key ?? "");
  return (
    <>
      <LoadState query={query} />
      {query.data && (
        <>
          {companion && (
            <div className="work-pane-header">
              <span>Current run</span>
              <button
                type="button"
                aria-label="Close run companion"
                onClick={() => navigate({ companion: "hide" })}
              >
                ×
              </button>
            </div>
          )}
          <RunThread
            unified
            d={query.data}
            workLinks={
              companion ? (
                <WorkRunLinks
                  id={id}
                  ticketKey={query.data.run.ticket_key}
                  epic={t.data?.epic}
                  companion
                  navigate={navigate}
                />
              ) : undefined
            }
            onOpenTurn={(turn) => {
              router.push(`/runs/${id}?view=details#turn-${turn}`);
            }}
          />
        </>
      )}
    </>
  );
}
