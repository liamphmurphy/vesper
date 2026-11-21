"use client";

import Link from "next/link";
import type { Ticket } from "@/lib/api/client";
import { hasLiveRun, useTicketRuns } from "@/lib/api/hooks";
import { absoluteTime, ago, duration, runCost, timelineTime } from "@/lib/format";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { SmallPill } from "@/components/domain/labels";
import { RUN_STATE } from "./run-parts";

/** Every run on the ticket, newest first: status, agent, cost, and a link to its run page. */
export function RunsHistory({ t }: { t: Ticket }) {
  const runs = useTicketRuns(t.key, hasLiveRun(t));
  const list = runs.data?.runs ?? [];
  const priced = list.filter((r) => r.cost_source && r.cost_source !== "unknown");
  const total = priced.reduce((sum, r) => sum + r.cost_usd, 0);
  const partial = !!runs.data?.has_more || priced.length < list.length || priced.some((r) => r.cost_source === "partial");

  return (
    <section aria-labelledby="runs-title" className="flex flex-col gap-1.5">
      <div className="flex items-baseline gap-1.5 px-2">
        <h2 id="runs-title" className="text-13 text-fg-tertiary">
          Runs
        </h2>
        {list.length > 0 && <span className="font-mono text-13 text-fg-tertiary">{list.length}{runs.data?.has_more && "+"}</span>}
        {priced.length > 0 && (
          <span className="ml-auto font-mono text-12 text-fg-secondary" title={partial ? "Some runs have no reported cost, or older runs aren't loaded" : undefined}>
            {partial ? "≥ " : ""}${total.toFixed(2)} total
          </span>
        )}
      </div>
      {runs.isPending ? (
        <Skeleton className="mx-2 h-8" />
      ) : runs.isError ? (
        <p role="alert" className="px-2 text-12 text-pill-blocked-fg">
          Couldn’t load runs: {runs.error.message}
        </p>
      ) : list.length === 0 ? (
        <p className="px-2 text-12 text-fg-tertiary">No runs yet. Dispatch the ticket to start one.</p>
      ) : (
        <ul className="flex flex-col">
          {list.map((r) => {
            const st = RUN_STATE[r.state];
            const ended = !!r.ended_at;
            const when = ended ? `${timelineTime(r.started_at)} · ${duration(r.started_at, r.ended_at)}` : `Started ${ago(r.started_at)}`;
            return (
              <li key={r.id}>
                <Link
                  href={`/runs/${r.id}`}
                  aria-label={`${r.agent.name} run, ${st.label}, ${runCost(r.cost_usd, r.cost_source)}, started ${absoluteTime(r.started_at)}`}
                  className="flex min-h-11 items-center gap-2.5 rounded-md px-2 py-1.5 hover:bg-hover"
                >
                  <WorkPersonaAvatar agent={r.agent} size="sm" />
                  <span className="flex min-w-0 flex-1 flex-col leading-tight">
                    <span className="flex items-center gap-1.5 text-13">
                      <span className="truncate">@{r.agent.handle}</span>
                      <SmallPill tone={st.tone}>{st.label}</SmallPill>
                    </span>
                    <span className="truncate text-12 text-fg-tertiary">
                      {when} · {r.model}
                      {r.parent_run_id && " · delegated"}
                    </span>
                  </span>
                  <span className="flex-none font-mono text-12 text-fg-secondary">{runCost(r.cost_usd, r.cost_source)}</span>
                  <Icon name="chevr" size={13} className="flex-none text-fg-tertiary" />
                </Link>
              </li>
            );
          })}
        </ul>
      )}
      {runs.data?.has_more && (
        <Link href={`/runs?state=all&project=${encodeURIComponent(t.project.key)}`} className="px-2 text-12 text-accent hover:underline">
          Showing the latest 50. All runs in {t.project.name} →
        </Link>
      )}
    </section>
  );
}
