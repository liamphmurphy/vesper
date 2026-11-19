"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { useCreateWorkflow, useDeleteWorkflow, useWorkflowRuns, useWorkflows } from "@/lib/api/workflow-hooks";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Content, TopBar } from "@/components/shell/topbar";
import { buildWorkflowsNavModel } from "@/lib/native-shell/models/workflows";
import { Button } from "@/components/ui/button";
import { Banner, Card, EmptyState, Skeleton, TextInput } from "@/components/ui/primitives";
import { RunStatePill } from "@/components/domain/workflow-cards";
import { confirmAction } from "@/components/ui/confirm";
import { PageHeader } from "@/components/ui/page-header";

export function WorkflowsScreen() {
  const router = useRouter();
  const workflows = useWorkflows();
  const runs = useWorkflowRuns();
  const create = useCreateWorkflow();
  const del = useDeleteWorkflow();
  const [name, setName] = useState("");
  const list = workflows.data?.workflows ?? [];
  const recentRuns = (runs.data?.runs ?? []).slice(0, 20);
  const add = () => create.mutate({ name }, { onSuccess: (w) => router.push(`/workflows/${w.id}`) });
  const createForm = (
    <form className="flex w-full max-w-[480px] gap-2" onSubmit={(e) => { e.preventDefault(); if (name.trim()) add(); }}>
      <TextInput aria-label="New workflow name" placeholder="New workflow name" value={name} onChange={(e) => setName(e.target.value)} />
      <Button variant="primary" type="submit" disabled={!name.trim() || create.isPending}>Create</Button>
    </form>
  );
  return (
    <>
      <NavigatorPortal native={{ model: buildWorkflowsNavModel({ workflows: list, runs: recentRuns }) }} />
      <TopBar crumbs={[{ label: "Workflows" }]} />
      <Content>
        <div className="flex flex-col gap-6">
          <PageHeader title="Workflows" description="Fixed sequences of steps Vesper runs for you. Start one from a chat with /workflow, or ask a persona and confirm its suggestion." />
          {list.length > 0 && createForm}
          {(create.error || workflows.error) && <Banner tone="blocked" title={(create.error ?? workflows.error)?.message} />}
          {workflows.isPending ? (
            <Skeleton className="h-24 w-full rounded-lg" />
          ) : list.length === 0 ? (
            <EmptyState icon="graph" title="No workflows yet" actions={createForm}>Name your first one below, or ask a persona in a chat to build one with you.</EmptyState>
          ) : (
            <ul className="flex flex-col gap-2">
              {list.map((w) => (
                <li key={w.id}>
                  <Card bodyClassName="flex items-center gap-3">
                    <div className="min-w-0 flex-1">
                      <Link href={`/workflows/${w.id}`} className="text-14 font-semibold text-fg hover:underline">{w.name}</Link>
                      {w.description && <p className="truncate text-13 text-fg-secondary">{w.description}</p>}
                    </div>
                    <span className="flex-none font-mono text-12 text-fg-tertiary">
                      {w.published_version > 0 ? `v${w.published_version}${w.unpublished_changes ? " · edited" : ""}` : "Draft"}
                    </span>
                    <Button disabled={del.isPending} onClick={async () => { if (await confirmAction({ title: `Delete ${w.name}?`, body: "Runs already started keep going.", confirmLabel: "Delete workflow" })) del.mutate(w.id); }}>Delete</Button>
                  </Card>
                </li>
              ))}
            </ul>
          )}
          {(runs.data?.runs.length ?? 0) > 0 && (
            <section className="flex flex-col gap-2">
              <h2 className="type-heading">Recent runs</h2>
              <ul className="flex flex-col gap-1">
                {runs.data!.runs.slice(0, 20).map((r) => (
                  <li key={r.id} className="flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-hover">
                    <Link href={`/workflows/runs/${r.id}`} className="min-w-0 flex-1 truncate text-13 text-fg hover:underline">{r.name}</Link>
                    <span className="min-w-0 max-w-[40%] truncate text-12 text-fg-tertiary">{r.input}</span>
                    <RunStatePill state={r.state} />
                  </li>
                ))}
              </ul>
            </section>
          )}
        </div>
      </Content>
    </>
  );
}
