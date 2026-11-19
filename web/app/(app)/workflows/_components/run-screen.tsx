"use client";

import "@xyflow/react/dist/style.css";

import { Background, ReactFlow, ReactFlowProvider } from "@xyflow/react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useState } from "react";
import { useStopWorkflowRun, useWorkflowRun, type WorkflowRun } from "@/lib/api/workflow-hooks";
import { Content, TopBar } from "@/components/shell/topbar";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { Markdown } from "@/components/domain/markdown";
import { WorkflowGatePanel, WorkflowImages } from "@/components/domain/workflow-cards";
import { RUN_STATE_LABEL, imagesByAttempt, runActive, type Graph } from "@/lib/workflows";
import { FLOW_STYLE, NODE_TYPES, toFlowEdges, toFlowNodes, type StepStatus } from "./flow";

function RunView({ run }: { run: WorkflowRun }) {
  const stop = useStopWorkflowRun(run.id);
  const router = useRouter();
  const [selected, setSelected] = useState<string | null>(null);
  const graph = run.graph as Graph;
  const status = (id: string) => run.steps.find((s) => s.node_id === id)?.state as StepStatus;
  const step = run.steps.find((s) => s.node_id === selected);
  const node = graph.nodes.find((n) => n.id === selected);
  const checks = run.check_attempts.filter((c) => c.node_id === selected);
  const attempts = imagesByAttempt((run.images ?? []).filter((im) => im.node_id === selected));
  // A step that made no images of its own shows what it passed along.
  const carried = attempts.length === 0 ? step?.images ?? [] : [];
  return (
    <>
      <TopBar
        crumbs={[{ label: "Workflows", href: "/workflows" }, { label: run.name }]}
        nativeTitle={{ title: run.name, subtitle: `v${run.version} · ${RUN_STATE_LABEL[run.state] ?? run.state}` }}
        nativeActions={[
          ...(runActive(run.state) ? [{ id: "wfrun.stop", label: "Stop", kind: "button" as const, icon: "pause", showsLabel: true, disabled: stop.isPending, run: () => stop.mutate() }] : []),
          { id: "wfrun.chat", label: "Open chat", kind: "button" as const, icon: "msg", showsLabel: true, run: () => router.push(`/chat/${run.chat_id}`) },
        ]}
      />
      <Content wide>
        <div className="flex flex-col gap-4">
          <p className="whitespace-pre-wrap text-13 text-fg-2">{run.input}</p>
          {run.error && <Banner tone="blocked" title={run.error} />}
          <div className="h-[320px] rounded-xl border border-border">
            <ReactFlow
              nodes={toFlowNodes(graph, (n) => ({ status: status(n.id) }), selected)}
              edges={toFlowEdges(graph)}
              nodeTypes={NODE_TYPES}
              nodesDraggable={false}
              nodesConnectable={false}
              onNodeClick={(_, n) => setSelected(n.id)}
              onPaneClick={() => setSelected(null)}
              style={FLOW_STYLE}
              fitView
              proOptions={{ hideAttribution: true }}
            >
              <Background gap={20} size={1} />
            </ReactFlow>
          </div>
          <WorkflowGatePanel run={run} />
          {node && (
            <section className="rounded-xl border border-border bg-surface p-3.5" data-testid="workflow-step-detail">
              <div className="mb-2 flex items-baseline gap-2">
                <h2 className="type-heading">{node.title}</h2>
                {step && <span className="font-mono text-12 text-fg-tertiary">attempt {step.attempt} · {step.check_result || step.state}</span>}
                {step?.agent_run_id && <Link className="text-13 text-accent hover:underline" href={`/runs/${step.agent_run_id}`}>Open run</Link>}
              </div>
              {step?.note && <p className="mb-2 text-13 text-fg-secondary">{step.note}</p>}
              {checks.length > 0 && (
                <div className="mb-3 flex flex-col gap-1" data-testid="workflow-check-attempts">
                  {checks.map((c) => (
                    <details key={c.attempt} className="rounded-lg border border-border-subtle bg-surface-sunken p-2">
                      <summary className="cursor-pointer font-mono text-11 text-fg-secondary">Attempt {c.attempt} · {c.result}</summary>
                      {c.note && <p className="mt-1 text-13 text-fg-secondary">{c.note}</p>}
                      {c.output && <div className="mt-2 text-13"><Markdown>{c.output}</Markdown></div>}
                    </details>
                  ))}
                </div>
              )}
              {attempts.map((a) => (
                <div key={a.attempt} className="mb-3" data-testid={`workflow-attempt-${a.attempt}`}>
                  <p className="mb-1 font-mono text-11 text-fg-tertiary">Attempt {a.attempt}</p>
                  <WorkflowImages runId={run.id} images={a.images} />
                </div>
              ))}
              {carried.length > 0 && <div className="mb-3"><WorkflowImages runId={run.id} images={carried} /></div>}
              {step?.output ? <div className="text-13"><Markdown>{step.output}</Markdown></div> : <p className="text-13 text-fg-tertiary">No output yet.</p>}
            </section>
          )}
        </div>
      </Content>
    </>
  );
}

export function WorkflowRunScreen() {
  const { id } = useParams<{ id: string }>();
  const run = useWorkflowRun(id);
  if (run.error) return <div className="p-6"><Banner tone="blocked" title={run.error.message} /></div>;
  if (!run.data) return <Skeleton className="m-6 h-96" />;
  return <ReactFlowProvider><RunView run={run.data} /></ReactFlowProvider>;
}
