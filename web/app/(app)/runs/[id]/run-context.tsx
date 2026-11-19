"use client";

// The run page's companion (LAZYAGENTS-163, DESIGN.md §3): its Context tab owns
// the run's structured metadata — ticket & epic progress, acceptance criteria,
// plan steps, code (branch, diff, PR), delegated runs, run facts, token/cache
// breakdown, and links to raw logs — keeping the main canvas calm and editorial.

import Link from "next/link";
import type { ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useEpicOverviews, useTicket } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, ago, compact, duration, runCost } from "@/lib/format";
import { runnerSlot, runTitle } from "@/lib/run-list";
import { cacheShare, PURPOSE_LABEL, subAgentTotals, usageByModel, type RunViewMode } from "@/lib/run-view";
import { AgentAvatar } from "@/components/domain/avatars";
import { StatusPill } from "@/components/domain/run-status";
import { TokenUsage } from "@/components/domain/token-usage";
import { Button } from "@/components/ui/button";
import { ContextSection as Section } from "@/components/shell/context-panel";
import { CompanionDock } from "@/components/shell/companion";
import { Icon } from "@/components/ui/icon";
import { WorkChat } from "@/components/domain/work-chat";
import { WorkspaceFolderChip } from "@/components/domain/workspace-folder";
import { CostValue } from "./run-thread";
import { LoadingLines } from "@/components/ui/loading";

type Run = Schemas["Run"];
type RunDetail = Schemas["RunDetail"];
type P = Record<string, unknown>;

function Fact({ k, children }: { k: string; children: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3 text-13">
      <dt className="flex-none text-fg-tertiary">{k}</dt>
      <dd className="min-w-0 truncate text-right text-fg-2">{children}</dd>
    </div>
  );
}

const STEP_MARK: Record<string, string> = { done: "✓", current: "●", needs_human: "!", failed: "✕", pending: "○" };

function PlanSection({ run }: { run: Run }) {
  if (!run.plan.length) return null;
  const done = run.plan.filter((s) => s.state === "done").length;
  return (
    <Section title="Plan" aside={`${done}/${run.plan.length}`}>
      <ol className="flex flex-col gap-1.5">
        {run.plan.map((s) => (
          <li key={s.position} className="flex items-start gap-2 text-12 leading-snug">
            <span
              aria-hidden
              className={cx(
                "w-3 flex-none text-center",
                s.state === "done" && "text-state-done",
                s.state === "failed" && "text-pill-blocked-fg",
                s.state === "needs_human" && "text-state-human",
                s.state === "current" && "text-accent",
                s.state === "pending" && "text-fg-tertiary",
              )}
            >
              {STEP_MARK[s.state] ?? "○"}
            </span>
            <span className={cx("min-w-0 flex-1", s.state === "done" ? "text-fg-secondary" : "text-fg-2")}>
              {s.text}
            </span>
          </li>
        ))}
      </ol>
    </Section>
  );
}

function DelegatedNode({ run, depth, kids }: { run: Run; depth: number; kids?: Run[] }) {
  return (
    <li>
      <div className={cx("flex items-start gap-2 py-1", depth > 0 && "ml-3.5 border-l border-border-subtle pl-2.5")}>
        <AgentAvatar name={run.agent.name} colorIndex={run.agent.color_index} label={false} size="sm" />
        <div className="flex min-w-0 flex-1 flex-col leading-tight">
          <span className="flex flex-wrap items-center gap-1.5 text-12">
            <Link href={`/runs/${run.id}`} className="font-medium text-accent hover:underline">
              {run.agent.name} ↗
            </Link>
            <StatusPill run={run} />
          </span>
          <span className="font-mono text-11 text-fg-tertiary">
            {run.model} · {duration(run.started_at, run.ended_at)} · {runCost(run.cost_usd, run.cost_source)}
          </span>
        </div>
      </div>
      {kids && kids.length > 0 && (
        <ul>
          {kids.map((k) => (
            <DelegatedNode key={k.id} run={k} depth={depth + 1} />
          ))}
        </ul>
      )}
    </li>
  );
}

function DelegatedSection({ d, grandchildren }: { d: RunDetail; grandchildren: (Run[] | undefined)[] }) {
  if (!d.child_runs.length) return null;
  return (
    <Section title="Sub-agents" aside={`${d.child_runs.length}`}>
      <ul>
        {d.child_runs.map((c, i) => (
          <DelegatedNode key={c.id} run={c} depth={0} kids={grandchildren[i]} />
        ))}
      </ul>
    </Section>
  );
}

function UsageSection({ d, grandchildren }: { d: RunDetail; grandchildren: (Run[] | undefined)[] }) {
  const run = d.run;
  const sub = subAgentTotals(d.child_runs);
  const seen = new Set<string>();
  const all = [run, ...d.child_runs, ...grandchildren.flatMap((g) => g ?? [])].filter((r) => !seen.has(r.id) && !!seen.add(r.id));
  const models = usageByModel(all);
  const share = cacheShare(run.input_tokens, run.cached_input_tokens);

  return (
    <Section title="Usage">
      <TokenUsage usage={run} compact />
      {share !== null && (
        <div className="flex flex-col gap-1.5 rounded-lg border border-border-subtle bg-surface-sunken px-2.5 py-2">
          <div className="flex items-baseline justify-between gap-2 text-11">
            <span className="text-fg-secondary">Cache share</span>
            <span className="font-mono font-medium text-fg">{Math.round(share * 100)}%</span>
          </div>
          <div
            role="img"
            aria-label={`${Math.round(share * 100)}% of input served from cache`}
            className="h-1.5 w-full overflow-hidden rounded-full bg-track"
          >
            <div className="h-full rounded-full bg-accent" style={{ width: `${share * 100}%` }} />
          </div>
        </div>
      )}
      {(d.turns.length > 0 || d.child_runs.length > 0) && (
        <div className="flex flex-col gap-1">
          <h3 className="text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">By turn</h3>
          <ul className="flex flex-col gap-1">
            {d.turns.map((t) => {
              const u = (t.usage ?? {}) as P;
              return (
                <li key={t.seq} className="flex items-baseline justify-between gap-2 text-12">
                  <span className="text-fg-secondary">Turn {t.seq}</span>
                  <span className="font-mono text-11 text-fg-tertiary">
                    {compact(Number(u.input_tokens ?? 0))} in · {compact(Number(u.output_tokens ?? 0))} out{" "}
                    <span className="text-fg-2">
                      {runCost(Number(u.cost_usd ?? 0), typeof u.cost_source === "string" ? u.cost_source : undefined)}
                    </span>
                  </span>
                </li>
              );
            })}
            {d.child_runs.length > 0 && (
              <li className="flex items-baseline justify-between gap-2 text-12">
                <span className="text-fg-secondary">Sub agents ({d.child_runs.length})</span>
                <span className="font-mono text-11 text-fg-tertiary">
                  {compact(sub.input)} in · {compact(sub.output)} out{" "}
                  <span className="text-fg-2">{sub.unpriced ? `≥ $${sub.cost.toFixed(2)}` : `$${sub.cost.toFixed(2)}`}</span>
                </span>
              </li>
            )}
          </ul>
        </div>
      )}
      {models.length > 1 && (
        <div className="flex flex-col gap-1">
          <h3 className="text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">By model</h3>
          <ul className="flex flex-col gap-1">
            {models.map((m) => (
              <li key={m.model} className="flex items-baseline justify-between gap-2 text-12">
                <span className="truncate font-mono text-11 text-fg-secondary">{m.model}</span>
                <span className="flex-none font-mono text-11 text-fg-tertiary">
                  {m.runs} run{m.runs === 1 ? "" : "s"}{" "}
                  <span className="text-fg-2">{m.unpriced ? `≥ $${m.cost.toFixed(2)}` : `$${m.cost.toFixed(2)}`}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </Section>
  );
}

function TicketSection({ ticketKey, run }: { ticketKey: string; run: RunDetail["run"] }) {
  const ticket = useTicket(ticketKey);
  const t = ticket.data;
  const epics = useEpicOverviews(!!t?.epic);
  const epic = t?.epic ? epics.data?.find((e) => e.epic.id === t.epic!.id) : undefined;
  const done = t?.criteria.filter((c) => c.done).length ?? 0;
  return (
    <>
      <Section title="Ticket">
        {!t ? (
          ticket.isError ? <p className="text-12 text-fg-tertiary">Couldn’t load the ticket.</p> : <LoadingLines />
        ) : (
          <>
            <Link href={`/tickets/${encodeURIComponent(t.key)}`} className="text-13 text-fg hover:underline">
              <span className="font-mono text-12 text-fg-secondary">{t.key}</span> {t.title}
            </Link>
            <p className="text-12 text-fg-tertiary">{t.status.replace("_", " ")} · {t.priority}</p>
            {t.epic && (
              <div className="flex flex-col gap-1">
                <p className="flex items-baseline justify-between gap-2 text-12">
                  <Link href={`/epics/${t.epic.id}`} className="truncate text-fg-2 hover:underline">{t.epic.name}</Link>
                  {epic && <span className="flex-none font-mono text-fg-tertiary">{epic.counts.done}/{epic.counts.total} done</span>}
                </p>
                {epic && epic.counts.total > 0 && (
                  <div role="progressbar" aria-label="Epic progress" aria-valuemin={0} aria-valuemax={epic.counts.total} aria-valuenow={epic.counts.done} className="h-1 overflow-hidden rounded-full bg-surface-sunken">
                    <div className="h-full bg-state-done" style={{ width: `${(epic.counts.done / epic.counts.total) * 100}%` }} />
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </Section>
      {t && t.criteria.length > 0 && (
        <Section title="Acceptance criteria" aside={`${done}/${t.criteria.length}`}>
          <ol className="flex flex-col gap-1.5">
            {[...t.criteria].sort((a, b) => a.position - b.position).map((c) => (
              <li key={c.id} className="flex gap-2 text-13">
                <span aria-hidden className={cx("mt-px grid size-3.5 flex-none place-items-center rounded-[4px] border", c.done ? "border-state-done bg-state-done text-on-accent" : "border-border-strong")}>
                  {c.done && <Icon name="check" size={10} strokeWidth={2.4} />}
                </span>
                <span className={cx("min-w-0", c.done ? "text-fg-secondary" : "text-fg-2")}>
                  <span className="sr-only">{c.done ? "Done: " : "Not done: "}</span>
                  {c.text}
                </span>
              </li>
            ))}
          </ol>
        </Section>
      )}
      <CodeSection branch={t?.branch || run.branch} pr={t?.pr} runPr={{ number: run.pr_number, url: run.pr_url }} />
    </>
  );
}

function CodeSection({ branch, pr, runPr }: { branch?: string; pr?: Schemas["PullRequest"]; runPr?: { number?: number; url?: string } }) {
  const number = pr?.number ?? runPr?.number;
  const url = pr?.url ?? runPr?.url;
  if (!branch && !number) return null;
  return (
    <Section title="Code">
      <dl className="flex flex-col gap-1">
        {branch && <Fact k="Branch"><span className="font-mono text-12" title={branch}>{branch}</span></Fact>}
        {pr && (pr.additions != null || pr.deletions != null) && (
          <Fact k="Diff">
            <span className="font-mono text-12"><span className="text-state-done">+{pr.additions ?? 0}</span> <span className="text-pill-blocked-fg">−{pr.deletions ?? 0}</span></span>
          </Fact>
        )}
        {number && (
          <Fact k="Pull request">
            {url ? <a href={url} target="_blank" rel="noreferrer" className="text-accent hover:underline">#{number}{pr ? ` · ${pr.state}` : ""} ↗</a> : `#${number}`}
          </Fact>
        )}
      </dl>
    </Section>
  );
}

export function RunContext({
  d,
  mode,
  setMode,
  grandchildren = [],
}: {
  d: RunDetail;
  mode: RunViewMode;
  setMode: (m: RunViewMode) => void;
  grandchildren?: (Run[] | undefined)[];
}) {
  const run = d.run;
  const slot = runnerSlot(d.events);
  const lastLog = [...d.turns].reverse().find((t) => t.has_log);
  const view = (m: RunViewMode, label: string, icon: "terminal" | "graph" | "folder") => (
    <Button variant={mode === m ? "secondary" : "outline"} icon={icon} aria-pressed={mode === m} onClick={() => setMode(mode === m ? "simple" : m)}>
      {label}
    </Button>
  );
  const facts = (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <PlanSection run={run} />
      {run.purpose === "ticket" && run.ticket_key ? <TicketSection ticketKey={run.ticket_key} run={run} /> : <CodeSection branch={run.branch} runPr={{ number: run.pr_number, url: run.pr_url }} />}
      <DelegatedSection d={d} grandchildren={grandchildren} />
      <Section title="Run">
        <dl className="flex flex-col gap-1">
          <Fact k="Purpose">{PURPOSE_LABEL[run.purpose] ?? run.purpose}</Fact>
          <Fact k="Model"><span className="font-mono text-12">{run.model}</span></Fact>
          <Fact k="Harness"><span className="font-mono text-12">{run.harness}</span> · {run.mode}</Fact>
          <Fact k="Started"><span title={absoluteTime(run.started_at)}>{ago(run.started_at)}</span></Fact>
          <Fact k="Elapsed"><span className="font-mono text-12">{duration(run.started_at, run.ended_at)}</span></Fact>
          <Fact k="Cost"><span className="font-mono text-12"><CostValue d={d} /></span></Fact>
          <Fact k="Tokens"><span className="font-mono text-12">{compact(run.input_tokens + run.output_tokens)} · {run.tool_calls} tool calls</span></Fact>
          <Fact k="Sub runs"><span className="font-mono text-12">{run.child_count ?? d.child_runs.length}</span></Fact>
          <Fact k="Runner slot"><span className="font-mono text-12">{slot ? [slot.runner, slot.backend].filter(Boolean).join(" · ") : run.mode === "unmanaged" ? "none (unmanaged)" : "–"}</span></Fact>
          {run.dispatched_by && <Fact k="Dispatched by">{run.dispatched_by.name}</Fact>}
        </dl>
        {run.workspace_path && <WorkspaceFolderChip path={run.workspace_path} />}
      </Section>
      <UsageSection d={d} grandchildren={grandchildren} />
      <Section title="Open">
        <div className="flex flex-wrap gap-1.5">
          {view("details", "Raw log", "terminal")}
          {view("graph", "Graph", "graph")}
          {view("files", "Files", "folder")}
        </div>
        <div className="flex flex-wrap gap-x-3 gap-y-1 text-12">
          <Link href={`/settings/runner?run_id=${run.id}`} className="text-accent hover:underline">Environment</Link>
          {lastLog && <a href={`/api/v1/runs/${run.id}/turns/${lastLog.seq}/log`} className="text-accent hover:underline">Download raw log</a>}
        </div>
      </Section>
    </div>
  );
  return (
    <CompanionDock
      app="run"
      tabs={[
        { id: "context", label: "Context", icon: "sidebar", content: facts },
        { id: "chat", label: "Chat", icon: "msg", content: <WorkChat subject={{ kind: "run", id: run.id, title: runTitle(run), agent: run.agent.name, ticketKey: run.ticket_key ?? undefined }} /> },
      ]}
    />
  );
}
