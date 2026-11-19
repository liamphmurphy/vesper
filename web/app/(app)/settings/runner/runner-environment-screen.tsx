"use client";

import { useState } from "react";
import { useSearchParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { api, unwrap } from "@/lib/api/client";
import { absoluteTime } from "@/lib/format";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { SmallPill } from "@/components/domain/labels";
import { Content, TopBar } from "@/components/shell/topbar";
import { TestEnvironmentsCard } from "./test-environments-card";
import { PageHeader } from "@/components/ui/page-header";

const resultLabel = { ready: "Ready", failed: "Setup failed", unconfigured: "No manifest" } as const;
const selectClass = "h-9 w-full rounded-md border border-border-strong bg-surface px-3 text-14 text-fg";
const cell = "border-t border-border-subtle px-3 py-2.5 text-left";

export function RunnerEnvironmentScreen() {
  const runId = useSearchParams().get("run_id") ?? undefined;
  const [selectedRun, setSelectedRun] = useState("");
  const query = useQuery({
    queryKey: ["runner", "environment", runId ?? "latest"],
    queryFn: () => unwrap(api.GET("/runner/environment", { params: { query: { run_id: runId } } })),
    refetchInterval: 15_000,
    retry: 1,
  });
  const data = query.data;
  const snapshot = data?.snapshots.find((s) => s.run_id === selectedRun) ?? data?.snapshots[0];
  const report = snapshot?.report;
  const liveRunner = data?.runner.runners.find((r) => r.id === snapshot?.runner_id);
  const missingTools = report?.tools.filter((t) => !t.available).length ?? 0;
  const folderLabels = report ? [
    ...report.go_modules.map((p) => `Go · ${p}`),
    ...report.npm_projects.map((p) => `npm · ${p}`),
    ...report.playwright.map((p) => `Chromium · ${p}`),
  ] : [];

  return <>
    <TopBar crumbs={[{ label: "Settings", href: "/settings" }, { label: "Runner environment" }]} nativeActions={[
      { id: "runner.refresh", label: query.isFetching ? "Refreshing…" : "Refresh", kind: "button", icon: "refresh", showsLabel: true, disabled: query.isFetching, run: () => void query.refetch() },
    ]} />
    <Content>
      <div className="space-y-6">
        <PageHeader title="Runner environment" description="Shared tools, project dependencies, and caches reported during workspace setup." />
        {query.isError && <Banner tone="blocked" title="Couldn’t load the runner environment" actions={<Button variant="outline" onClick={() => void query.refetch()}>Try again</Button>}>
          {query.error instanceof Error ? query.error.message : "The API is unavailable."}
        </Banner>}
        {query.isPending && <div aria-label="Loading runner environment" className="space-y-4"><Skeleton className="h-24" /><Skeleton className="h-64" /></div>}
        {data && <>
          <div className="grid gap-4 sm:grid-cols-3">
            <Card title="Runners online"><div className="type-display">{data.runner.runners.length}</div><p className="mt-1 text-12 text-fg-tertiary">{data.runner.online ? `${data.runner.busy} of ${data.runner.slots} slots in use` : "Start a runner to execute dispatched work."}</p></Card>
            <Card title="Shared tools"><div className="type-display">{report?.tools.length ?? "—"}</div><p className="mt-1 text-12 text-fg-tertiary">{report ? missingTools ? `${missingTools} missing from this environment` : "Available in the selected setup" : "Waiting for an environment report"}</p></Card>
            <Card title="Last setup"><div className="type-title">{report ? resultLabel[report.status] : "Not reported"}</div><p className="mt-1 text-12 text-fg-tertiary">{snapshot ? absoluteTime(snapshot.recorded_at) : "New runs report their setup automatically."}</p></Card>
          </div>
          {runId && <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface px-4 py-3 text-14">
            <span>Showing the environment recorded for this run.</span>
            <ButtonLink href="/settings/runner" variant="outline">View latest environments</ButtonLink>
          </div>}
          {!snapshot && <Card><EmptyState icon="agents" title={runId ? "No environment recorded for this run" : "No environment snapshots yet"}>
            {runId ? "Older runs and runs that stopped before dependency setup do not have an environment report." : "Restart with the updated runner and start a ticket run. Its setup will report installed tools, project dependencies, and cache availability here."}
          </EmptyState></Card>}
          {snapshot && report && <>
            <Card title="Recorded environment" action={<SmallPill tone={liveRunner ? "done" : "neutral"}>{liveRunner ? "Runner online" : "Runner offline"}</SmallPill>}>
              {!runId && <div className="mb-4"><label htmlFor="environment-snapshot" className="mb-1.5 block text-12 font-medium text-fg-secondary">Space and runner</label>
                <select id="environment-snapshot" className={selectClass} value={snapshot.run_id} onChange={(e) => setSelectedRun(e.target.value)}>
                  {data.snapshots.map((s) => <option key={s.run_id} value={s.run_id}>{s.project_name} · {s.runner_id || "Unknown runner"} · {resultLabel[s.report.status]}</option>)}
                </select>
              </div>}
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="space-y-1"><p className="font-medium">{snapshot.project_name} <span className="text-12 text-fg-tertiary">{snapshot.project_key}</span></p>
                  <p className="break-all font-mono text-12 text-fg-secondary">{snapshot.runner_id || "Unknown runner"} · {snapshot.backend}</p>
                  <p className="text-12 text-fg-tertiary">Observed {absoluteTime(snapshot.recorded_at)}. Tool versions and cache state reflect that setup.</p>
                </div>
                <ButtonLink href={`/runs/${snapshot.run_id}`} variant="outline">{snapshot.ticket_key} run log</ButtonLink>
              </div>
            </Card>
            {report.status === "failed" && <Banner tone="blocked" title="Dependency setup failed">{report.error ?? "Open the run log for the setup error."}</Banner>}
            {report.status === "unconfigured" && <Banner title="No project dependency manifest">Add <code>{report.manifest}</code> to the repository to prepare project libraries automatically. Shared tools are listed below.</Banner>}
            <div className="grid items-start gap-5 lg:grid-cols-2">
              <Card title="Shared tools" bodyClassName="overflow-x-auto px-1 py-1">
                {report.tools.length ? <table className="w-full text-14"><caption className="sr-only">Tools available to agents in this runner environment</caption>
                  <thead><tr className="text-12 text-fg-tertiary"><th scope="col" className="px-3 py-2 text-left">Tool</th><th scope="col" className="px-3 py-2 text-left">Version</th><th scope="col" className="px-3 py-2 text-left">Status</th></tr></thead>
                  <tbody>{report.tools.map((tool) => <tr key={tool.name}><th scope="row" className={`${cell} font-mono text-12 font-medium`}>{tool.name}</th><td className={`${cell} break-all text-12 text-fg-secondary`}>{tool.version ?? "Not reported"}</td><td className={cell}><SmallPill tone={tool.available ? "done" : "blocked"}>{tool.available ? "Available" : "Missing"}</SmallPill></td></tr>)}</tbody>
                </table> : <p className="p-4 text-14 text-fg-tertiary">Tool inventory was not available.</p>}
              </Card>
              <Card title="Dependency caches">
                <p className="mb-4 text-12 text-fg-tertiary">Download and browser caches are shared by agents. Installed npm packages and Go build caches belong to each workspace.</p>
                <div className="space-y-4">{report.caches.map((cache) => <div key={cache.name} className="border-t border-border-subtle pt-3 first:border-0 first:pt-0">
                  <div className="flex flex-wrap justify-between gap-2 text-14"><span className="font-medium">{cache.name}</span><SmallPill tone={cache.exists && !cache.writable ? "human" : "neutral"}>{!cache.exists ? "Not created yet" : cache.writable ? "Writable at setup" : "Read only at setup"}</SmallPill></div>
                  <p className="mt-1 text-12 text-fg-tertiary">{cache.shared ? "Shared across runs" : "Per workspace"}</p><code className="mt-1 block break-all text-12 text-fg-secondary">{cache.path}</code>
                </div>)}{!report.caches.length && <p className="text-14 text-fg-tertiary">Cache state was not reported.</p>}</div>
              </Card>
            </div>
            <Card title="Project dependencies" action={<span className="text-12 text-fg-tertiary">{report.packages.length >= 200 ? "First 200" : report.packages.length} direct {report.packages.length === 1 ? "dependency" : "dependencies"}</span>}>
              <div className="mb-4 space-y-2 text-14 text-fg-secondary"><p>Configured in <code>{report.manifest}</code>. Versions come from the project’s module and package lockfiles.</p>
                {folderLabels.length > 0 && <div className="flex flex-wrap gap-2">{folderLabels.map((label) => <SmallPill key={label} tone="neutral">{label}</SmallPill>)}</div>}
              </div>
              {report.packages.length ? <div className="overflow-x-auto"><table className="w-full text-14"><caption className="sr-only">Direct project dependencies</caption><thead><tr className="text-12 text-fg-tertiary"><th scope="col" className="px-3 py-2 text-left">Package</th><th scope="col" className="px-3 py-2 text-left">Version</th><th scope="col" className="px-3 py-2 text-left">Project folder</th></tr></thead><tbody>
                {report.packages.map((p) => <tr key={`${p.ecosystem}:${p.project}:${p.name}`}><th scope="row" className={`${cell} break-all font-mono text-12 font-medium`}>{p.name}</th><td className={`${cell} font-mono text-12 text-fg-secondary`}>{p.version}</td><td className={`${cell} text-12 text-fg-secondary`}>{p.ecosystem} · {p.project}</td></tr>)}
              </tbody></table></div> : <p className="text-14 text-fg-tertiary">No direct package versions were reported for this setup.</p>}
            </Card>
            <p className="text-12 text-fg-tertiary">Update shared tools in the runner image or local installation, and project libraries in their lockfiles. A space’s repository is set in the Work section of its page.</p>
          </>}
          <TestEnvironmentsCard />
        </>}
      </div>
    </Content>
  </>;
}
