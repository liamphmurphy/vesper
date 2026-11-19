"use client";

// The run's Files view (opened from the Context panel): the files its tool
// calls changed or read, its sub-runs' included, plus where the checkout is.

import type { Schemas } from "@/lib/api/client";
import { touchedFiles } from "@/lib/run-list";
import { EmptyState } from "@/components/ui/primitives";
import { WorkspaceFolderChip } from "@/components/domain/workspace-folder";
import { WORK_COLUMN } from "@/components/domain/work-detail-header";

type RunDetail = Schemas["RunDetail"];

export function RunFiles({ d, childDetails }: { d: RunDetail; childDetails: (RunDetail | undefined)[] }) {
  const files = touchedFiles([...d.events, ...childDetails.flatMap((c) => c?.events ?? [])]);
  const changed = files.filter((f) => f.writes > 0);
  const read = files.filter((f) => f.writes === 0);
  return (
    <section aria-label="Files" className="min-h-0 flex-1 overflow-y-auto py-4">
      <div className={`${WORK_COLUMN} flex flex-col gap-4`}>
        {d.run.workspace_path && <WorkspaceFolderChip path={d.run.workspace_path} className="self-start" />}
        {d.run.branch && <p className="text-13 text-fg-secondary">Branch <span className="font-mono text-12 text-fg">{d.run.branch}</span></p>}
        {files.length === 0 ? (
          <EmptyState icon="folder" title="No files yet">Files appear here as the agent reads and edits them.</EmptyState>
        ) : (
          [["Changed", changed], ["Read", read]].map(([title, list]) =>
            (list as typeof files).length ? (
              <div key={title as string} className="flex flex-col gap-1">
                <h2 className="text-12 font-medium text-fg-tertiary">{title as string} · {(list as typeof files).length}</h2>
                <ul className="overflow-hidden rounded-xl border border-border bg-surface">
                  {(list as typeof files).map((f) => (
                    <li key={f.path} className="flex items-center gap-3 border-b border-border-row px-3.5 py-2 last:border-b-0">
                      <span className="min-w-0 flex-1 truncate font-mono text-13" title={f.path}>{f.path}</span>
                      <span className="flex-none font-mono text-11 text-fg-tertiary">
                        {f.writes > 0 && `${f.writes} edit${f.writes === 1 ? "" : "s"}`}
                        {f.writes > 0 && f.reads > 0 && " · "}
                        {f.reads > 0 && `${f.reads} read${f.reads === 1 ? "" : "s"}`}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null,
          )
        )}
        <p className="text-12 text-fg-tertiary">From the run’s tool calls. The pull request has the full diff.</p>
      </div>
    </section>
  );
}
