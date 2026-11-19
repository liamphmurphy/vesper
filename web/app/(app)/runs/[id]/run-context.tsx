"use client";

// The run page's companion (LAZYAGENTS-163, DESIGN.md §3): its Context tab owns
// the run's structured metadata — ticket & epic progress, acceptance criteria,
// plan steps, code (branch, diff, PR), delegated runs, run facts, token/cache
// breakdown, and links to raw logs — keeping the main canvas calm and editorial.

import type { Schemas } from "@/lib/api/client";
import { useEpicOverviews, useTicket } from "@/lib/api/hooks";
import { ago, compact, duration, runCost } from "@/lib/format";
import { runnerSlot, runTitle } from "@/lib/run-list";
import { cacheShare, PURPOSE_LABEL, usageByModel, type RunViewMode } from "@/lib/run-view";
import { CompanionDock } from "@/components/shell/companion";
import { runStateTone } from "@/lib/native-shell/models/common";
import { buildRunInspectorSections } from "@/lib/native-shell/models/run-inspector";

type Run = Schemas["Run"];
type RunDetail = Schemas["RunDetail"];
type P = Record<string, unknown>;

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
  const ticketKey = run.purpose === "ticket" && run.ticket_key ? run.ticket_key : "";
  const ticketQuery = useTicket(ticketKey);
  const ticket = ticketQuery.data;
  const epics = useEpicOverviews(!!ticket?.epic);
  const epic = ticket?.epic ? epics.data?.find((e) => e.epic.id === ticket.epic!.id) : undefined;
  const slot = runnerSlot(d.events);
  const lastLog = [...d.turns].reverse().find((t) => t.has_log);
  const seen = new Set<string>();
  const allUsageRuns = [run, ...d.child_runs, ...grandchildren.flatMap((g) => g ?? [])].filter(
    (r) => !seen.has(r.id) && !!seen.add(r.id),
  );
  const usageModels = usageByModel(allUsageRuns);
  const share = cacheShare(run.input_tokens, run.cached_input_tokens);
  const subCost = d.child_runs.reduce((n, c) => n + c.cost_usd, 0);
  const subPriced = d.child_runs.every((c) => c.cost_source && c.cost_source !== "unknown");
  const costText =
    d.child_runs.length > 0
      ? `${runCost(run.cost_usd, run.cost_source)} (${subPriced ? "+" : "≥ +"}$${subCost.toFixed(2)} sub)`
      : runCost(run.cost_usd, run.cost_source);

  const pr = ticket?.pr;
  const prNumber = pr?.number ?? run.pr_number;
  const prUrl = pr?.url ?? run.pr_url;
  const nativeSections = buildRunInspectorSections({
    plan: run.plan.map((s) => ({ position: s.position, text: s.text, state: s.state })),
    ticket: ticket
      ? {
          key: ticket.key,
          title: ticket.title,
          statusLabel: ticket.status.replace("_", " "),
          priorityLabel: ticket.priority,
          ...(ticket.epic
            ? {
                epic: {
                  id: ticket.epic.id,
                  name: ticket.epic.name,
                  done: epic?.counts.done,
                  total: epic?.counts.total,
                },
              }
            : {}),
          criteria: ticket.criteria.map((c) => ({ id: c.id, position: c.position, text: c.text, done: c.done })),
        }
      : undefined,
    code:
      (ticket?.branch || run.branch || prNumber)
        ? {
            branch: ticket?.branch || run.branch,
            additions: pr?.additions ?? undefined,
            deletions: pr?.deletions ?? undefined,
            prNumber,
            prState: pr?.state,
            prUrl,
          }
        : undefined,
    subAgents: d.child_runs.map((c) => ({
      id: c.id,
      agent: c.agent.name,
      subtitle: `${c.model} · ${duration(c.started_at, c.ended_at)} · ${runCost(c.cost_usd, c.cost_source)}`,
      stateTone: runStateTone(c.state),
    })),
    run: {
      id: run.id,
      purpose: PURPOSE_LABEL[run.purpose] ?? run.purpose,
      model: run.model,
      harness: run.harness,
      mode: run.mode,
      started: ago(run.started_at),
      elapsed: duration(run.started_at, run.ended_at),
      cost: costText,
      tokens: `${compact(run.input_tokens + run.output_tokens)} · ${run.tool_calls} tool calls`,
      subRuns: run.child_count ?? d.child_runs.length,
      slot: slot ? [slot.runner, slot.backend].filter(Boolean).join(" · ") : run.mode === "unmanaged" ? "none (unmanaged)" : "–",
      dispatchedBy: run.dispatched_by?.name,
      workspacePath: run.workspace_path,
    },
    usage: {
      tokensSummary: `${compact(run.input_tokens)} in · ${compact(run.output_tokens)} out`,
      costSummary: costText,
      cacheSharePct: share !== null ? Math.round(share * 100) : null,
      turns: d.turns.map((t) => {
        const u = (t.usage ?? {}) as P;
        return {
          seq: t.seq,
          summary: `${compact(Number(u.input_tokens ?? 0))} in · ${compact(Number(u.output_tokens ?? 0))} out · ${runCost(Number(u.cost_usd ?? 0), typeof u.cost_source === "string" ? u.cost_source : undefined)}`,
        };
      }),
      models: usageModels.map((m) => ({
        model: m.model,
        summary: `${m.runs} run${m.runs === 1 ? "" : "s"} · ${m.unpriced ? `≥ $${m.cost.toFixed(2)}` : `$${m.cost.toFixed(2)}`}`,
      })),
    },
    viewMode: mode,
    environmentHref: `/settings/runner?run_id=${run.id}`,
    rawLogUrl: lastLog ? `/api/v1/runs/${run.id}/turns/${lastLog.seq}/log` : undefined,
  });

  const subject = { kind: "run" as const, id: run.id, title: runTitle(run), agent: run.agent.name, ticketKey: run.ticket_key ?? undefined };
  return (
    <CompanionDock
      app="run"
      tabs={[
        {
          id: "context",
          label: "Context",
          icon: "sidebar",
          native: {
            kind: "native",
            sections: nativeSections,
            onAction: (actionId) => {
              if (actionId === "view:details" || actionId === "view:graph" || actionId === "view:files") {
                const next = actionId.slice("view:".length) as RunViewMode;
                setMode(mode === next ? "simple" : next);
              }
            },
          },
        },
        {
          id: "chat",
          label: "Chat",
          icon: "msg",
          native: { kind: "companion", subject },
        },
      ]}
    />
  );
}
