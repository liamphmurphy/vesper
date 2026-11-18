"use client";

import Link from "next/link";
import { useContext, useMemo, useState } from "react";
import { usePulse } from "@/components/ui/motion";
import { workflowImageUrl, type Schemas } from "@/lib/api/client";
import { useChatWorkflowRuns, useDecideGate, useStartWorkflow, useStopWorkflowRun, useWorkflows, type WorkflowRun } from "@/lib/api/workflow-hooks";
import { cx } from "@/lib/cx";
import { RUN_STATE_LABEL, canRequestChanges, failedGateCheck, gateSources, parseWorkflowRun, runActive, type Graph } from "@/lib/workflows";
import { Button } from "@/components/ui/button";
import { CodeFence } from "./code-fence";
import { Markdown } from "./markdown";
import { RecommendActions } from "./recommend-fence";
import { SvgFenceMessage } from "./svg-fence";

const CARD = "flex w-full max-w-[680px] flex-col gap-3 rounded-xl border border-border bg-surface p-3.5";
const INPUT = "w-full resize-y rounded-md border border-border-strong bg-surface p-2 text-13 text-fg focus:border-accent focus:outline-none";

const STATE_PILL: Record<string, string> = {
  running: "bg-pill-neutral-bg text-pill-neutral-fg",
  waiting: "bg-pill-human-bg text-pill-human-fg",
  done: "bg-pill-done-bg text-pill-done-fg",
  failed: "bg-pill-blocked-bg text-pill-blocked-fg",
  stopped: "bg-pill-neutral-bg text-pill-neutral-fg",
};

export function RunStatePill({ state }: { state: string }) {
  const ref = usePulse<HTMLSpanElement>(state);
  return <span ref={ref} className={cx("flex-none rounded-full px-2 py-0.5 text-12 font-medium transition-colors duration-(--motion-base)", STATE_PILL[state])}>{RUN_STATE_LABEL[state] ?? state}</span>;
}

/** Confirms a run: a persona's suggestion or a /workflow pick. Nothing starts until Run. */
export function WorkflowStartCard({ workflow, chatId, input: initial = "", messageId, onDone, onDismiss }: {
  workflow: Schemas["Workflow"];
  chatId: string;
  input?: string;
  messageId?: string;
  onDone?: () => void;
  onDismiss: () => void;
}) {
  const [input, setInput] = useState(initial);
  const start = useStartWorkflow(chatId);
  return (
    <div data-testid="workflow-start" className={CARD}>
      <div className="flex items-baseline justify-between gap-3">
        <h4 className="text-14 font-semibold text-fg">Run {workflow.name}?</h4>
        <span className="flex-none font-mono text-12 text-fg-tertiary">v{workflow.published_version} · {workflow.draft.nodes.length} steps</span>
      </div>
      {workflow.description && <p className="text-13 text-fg-secondary">{workflow.description}</p>}
      <textarea aria-label="What to run it on" autoFocus={!initial} rows={3} placeholder="What should it work on?" value={input} onChange={(e) => setInput(e.target.value)} className={INPUT} />
      {start.error && <p role="alert" className="text-13 text-pill-blocked-fg">{start.error.message}</p>}
      <div className="flex items-center gap-2">
        <Button variant="primary" disabled={!input.trim() || start.isPending} onClick={() => start.mutate({ workflow_id: workflow.id, input, ...(messageId ? { message_id: messageId } : {}) }, { onSuccess: onDone })}>
          {start.isPending ? "Starting…" : "Run workflow"}
        </Button>
        <Button onClick={onDismiss}>Not now</Button>
      </div>
    </div>
  );
}

/** Images a workflow step generated, each opening at full size. */
export function WorkflowImages({ runId, images }: { runId: string; images: Schemas["WorkflowImage"][] }) {
  if (images.length === 0) return null;
  return (
    <div className="flex flex-wrap gap-2" data-testid="workflow-images">
      {images.map((im) => (
        <a key={im.id} href={workflowImageUrl(runId, im.id)} target="_blank" rel="noreferrer" className="block overflow-hidden rounded-lg border border-border-subtle">
          {/* same-origin, authorized API image */}
          <img src={workflowImageUrl(runId, im.id)} alt={im.filename} className="max-h-72 max-w-full object-contain" />
        </a>
      ))}
    </div>
  );
}

/** A gate's review: the outputs it's set to show, and the three decisions. */
export function WorkflowGatePanel({ run }: { run: WorkflowRun }) {
  const graph = run.graph as Graph;
  const waiting = run.steps.find((s) => s.state === "waiting");
  const gate = graph.nodes.find((n) => n.id === waiting?.node_id);
  const [note, setNote] = useState("");
  const decide = useDecideGate(run.id);
  if (!waiting || !gate) return null;
  const send = (decision: string) => decide.mutate({ node_id: gate.id, decision, ...(note.trim() ? { note } : {}) }, { onSuccess: () => setNote("") });
  const changes = canRequestChanges(gate, waiting.attempt);
  const failedCheck = failedGateCheck(graph, gate, run.steps);
  const sources = gateSources(graph, gate).map((id) => ({ node: graph.nodes.find((n) => n.id === id), step: run.steps.find((s) => s.node_id === id) }));
  return (
    <div data-testid="workflow-gate" className="flex flex-col gap-3 rounded-xl border border-state-human bg-surface p-3.5">
      <div>
        <h4 className="text-14 font-semibold text-fg">{gate.title}</h4>
        {gate.config.prompt && <p className="text-13 text-fg-secondary">{gate.config.prompt}</p>}
      </div>
      {sources.map(({ node, step }) => (step?.output || step?.images?.length) && (
        <details key={node?.id} open className="rounded-lg border border-border-subtle bg-surface-sunken p-2.5">
          <summary className="cursor-pointer text-12 font-medium text-fg-secondary">{node?.title}</summary>
          <div className="mt-2 flex max-h-96 flex-col gap-2 overflow-y-auto text-13">
            <WorkflowImages runId={run.id} images={step.images ?? []} />
            {step.output && <Markdown>{step.output}</Markdown>}
          </div>
        </details>
      ))}
      {failedCheck && <p role="status" data-testid="workflow-gate-check-failed" className="text-13 text-pill-blocked-fg">{failedCheck.title} didn&apos;t pass, so this can&apos;t be approved. Request changes or reject it.</p>}
      {changes && <textarea aria-label="Note for the re-run" rows={2} placeholder="Note for the re-run (required when requesting changes)" value={note} onChange={(e) => setNote(e.target.value)} className={INPUT} />}
      {decide.error && <p role="alert" className="text-13 text-pill-blocked-fg">{decide.error.message}</p>}
      <div className="flex items-center gap-2">
        <Button variant="primary" disabled={decide.isPending || !!failedCheck} onClick={() => send("approve")}>Approve</Button>
        {changes && <Button disabled={decide.isPending || !note.trim()} onClick={() => send("changes")}>Request changes</Button>}
        <span className="flex-1" />
        <Button disabled={decide.isPending} onClick={() => send("reject")}>Reject and stop</Button>
      </div>
    </div>
  );
}

export function WorkflowRunSummary({ run }: { run: WorkflowRun }) {
  const stop = useStopWorkflowRun(run.id);
  const total = run.graph.nodes.length;
  const done = run.steps.filter((s) => s.state === "done").length;
  return (
    <div data-testid="workflow-run" className={CARD}>
      <div className="flex items-center gap-2">
        <Link href={`/workflows/runs/${run.id}`} className="min-w-0 truncate text-14 font-semibold text-fg hover:underline">{run.name}</Link>
        <span className="flex-none font-mono text-12 text-fg-tertiary">v{run.version} · {done}/{total}</span>
        <span className="flex-1" />
        <RunStatePill state={run.state} />
      </div>
      {run.error && <p className="text-13 text-fg-secondary">{run.error}</p>}
      {run.state === "waiting" && <WorkflowGatePanel run={run} />}
      {runActive(run.state) && (
        <div><Button disabled={stop.isPending} onClick={() => stop.mutate()}>Stop</Button></div>
      )}
    </div>
  );
}

/** Runs still going in this chat, above the composer so a gate is never scrolled away. */
export function ChatWorkflowTray({ chatId }: { chatId: string }) {
  const runs = useChatWorkflowRuns(chatId);
  const live = (runs.data?.runs ?? []).filter((r) => runActive(r.state));
  if (live.length === 0) return null;
  return <div className="flex flex-col gap-2">{live.map((r) => <WorkflowRunSummary key={r.id} run={r} />)}</div>;
}

/** ```workflow-run: a persona's suggestion, confirmed here. Once started it points at the run. */
export function WorkflowRunFence({ code, info }: { code: string; info?: string }) {
  const parsed = useMemo(() => parseWorkflowRun(code), [code]);
  const messageId = useContext(SvgFenceMessage);
  const chatId = useContext(RecommendActions)?.chatId;
  const workflows = useWorkflows(!!parsed && !!chatId);
  const runs = useChatWorkflowRuns(parsed ? chatId : undefined);
  const [dismissed, setDismissed] = useState(false);
  if (!parsed || !chatId) return <CodeFence code={code} info={info} />;
  if (workflows.isPending || runs.isPending) return <div aria-label="Loading workflow" className={cx(CARD, "h-32 animate-pulse")} />;
  const run = runs.data?.runs.find((r) => r.message_id === messageId);
  if (run) {
    return runActive(run.state) ? (
      <p className="text-13 text-fg-tertiary">Started <Link className="text-accent hover:underline" href={`/workflows/runs/${run.id}`}>{run.name}</Link>. Follow it above the message box.</p>
    ) : <WorkflowRunSummary run={run} />;
  }
  const workflow = workflows.data?.workflows.find((w) => w.id === parsed.workflowId && w.published_version > 0);
  if (!workflow) return <p className="text-13 text-fg-tertiary">That workflow isn&apos;t available any more.</p>;
  if (dismissed) return <p data-testid="workflow-dismissed" className="text-12 text-fg-tertiary">Workflow not run.</p>;
  return <WorkflowStartCard workflow={workflow} chatId={chatId} input={parsed.input} messageId={messageId} onDismiss={() => setDismissed(true)} />;
}
