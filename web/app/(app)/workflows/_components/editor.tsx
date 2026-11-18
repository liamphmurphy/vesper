"use client";

import "@xyflow/react/dist/style.css";

import { Background, Controls, ReactFlow, ReactFlowProvider, applyNodeChanges, useReactFlow, type Connection, type EdgeChange, type NodeChange } from "@xyflow/react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useRef, useState, type DragEvent } from "react";
import { useChat, useChatMessages, useCreateChat, useSendChatMessage } from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { usePublishWorkflow, useResolveProposal, useSaveWorkflow, useWorkflow, type Workflow } from "@/lib/api/workflow-hooks";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { TopBar } from "@/components/shell/topbar";
import { WorkChat } from "@/components/domain/work-chat";
import { useCompact } from "@/lib/viewport";
import { buildWorkflowPaletteNavModel } from "@/lib/native-shell/models/workflows";
import { Button } from "@/components/ui/button";
import { Banner, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { Markdown } from "@/components/domain/markdown";
import { PersonaAvatar } from "@/components/domain/persona-avatar";
import { PALETTE, ancestors, canConnect, diffGraphs, newNodeId, parentChecks, removeNode, type Graph, type GraphNode, type NodeType } from "@/lib/workflows";
import { FLOW_STYLE, NODE_TYPES, toFlowEdges, toFlowNodes, type FlowNode } from "./flow";

const SAVE_DELAY = 700;
const LABEL = "text-12 text-fg-secondary";

function Labeled({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="flex flex-col gap-1"><span className={LABEL}>{label}</span>{children}</label>;
}

const SELECT = "h-[30px] rounded-md border border-border-strong bg-surface px-2 text-13 text-fg";

function Inspector({ graph, node, onChange, onRemove }: { graph: Graph; node: GraphNode; onChange: (patch: Partial<GraphNode>) => void; onRemove: () => void }) {
  const personas = usePersonas();
  const c = node.config;
  const config = (patch: Partial<GraphNode["config"]>) => onChange({ config: { ...c, ...patch } });
  const before = ancestors(graph, node.id);
  const rerunnable = before.filter((n) => n.type === "enrich" || n.type === "agent");
  const promptLabel: Partial<Record<NodeType, string>> = { enrich: "Extra instructions (optional)", agent: "What this step should do", gate: "Message to the reviewer" };
  return (
    <div className="flex flex-col gap-3" data-testid="workflow-inspector">
      <Labeled label="Title"><TextInput aria-label="Title" value={node.title} onChange={(e) => onChange({ title: e.target.value })} /></Labeled>
      <p className="font-mono text-11 text-fg-tertiary">{`{{${node.id}.output}}`}</p>
      {node.type !== "trigger" && (
        <Labeled label={promptLabel[node.type] ?? "Body (empty uses the previous step's output)"}>
          <TextArea aria-label="Prompt" rows={5} value={c.prompt ?? ""} onChange={(e) => config({ prompt: e.target.value })} />
        </Labeled>
      )}
      {node.type === "agent" && (
        <>
          <Labeled label="Run as persona">
            <select aria-label="Persona" className={SELECT} value={c.persona_id ?? ""} onChange={(e) => config({ persona_id: e.target.value || undefined, agent_handle: undefined })}>
              <option value="">The chat&apos;s persona</option>
              {personas.data?.personas.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </Labeled>
          <label className="flex items-center gap-2 text-13 text-fg-2">
            <input type="checkbox" checked={!!c.web} onChange={(e) => config({ web: e.target.checked || undefined })} /> Read the web (this step can&apos;t read the workspace)
          </label>
          <label className="flex items-center gap-2 text-13 text-fg-2">
            <input type="checkbox" checked={!!c.images} onChange={(e) => config({ images: e.target.checked || undefined })} /> Generate images
          </label>
          {c.images && (
            <>
              <Labeled label="Image engine">
                <select aria-label="Image engine" className={SELECT} value={c.image_engine ?? ""} onChange={(e) => config({ image_engine: e.target.value || undefined })}>
                  <option value="">The persona&apos;s, else the workspace&apos;s</option>
                  <option value="auto">Auto (first connected)</option>
                  <option value="codex">Codex</option>
                  <option value="antigravity">Antigravity</option>
                </select>
              </Labeled>
              <p className="text-12 text-fg-tertiary">Runs as a persona allowed to generate images. Later steps can see the images.</p>
            </>
          )}
          <label className="flex items-center gap-2 text-13 text-fg-2">
            <input type="checkbox" aria-label="Check" checked={!!c.check} onChange={(e) => config({ check: e.target.checked || undefined, retry_from: undefined, max_attempts: undefined })} /> This step is a check (pass or fail)
          </label>
          {c.check && (
            <>
              <p className="text-12 text-fg-tertiary">Nothing after this step runs unless it passes. A missing or unreadable result counts as a failure.</p>
              <Labeled label="If the check fails">
                <select aria-label="Re-run on failure" className={SELECT} value={c.retry_from ?? ""} onChange={(e) => config({ retry_from: e.target.value || undefined })}>
                  <option value="">Don&apos;t retry</option>
                  {rerunnable.map((n) => <option key={n.id} value={n.id}>Re-run from {n.title}</option>)}
                </select>
              </Labeled>
              {c.retry_from && (
                <Labeled label="Failures allowed before giving up">
                  <TextInput aria-label="Failures allowed" type="number" min={1} max={5} value={c.max_attempts ?? 3} onChange={(e) => config({ max_attempts: Number(e.target.value) || undefined })} />
                </Labeled>
              )}
            </>
          )}
        </>
      )}
      {node.type === "gate" && (
        <>
          <Labeled label="If changes are requested">
            <select aria-label="Re-run from" className={SELECT} value={c.retry_from ?? ""} onChange={(e) => config({ retry_from: e.target.value || undefined })}>
              <option value="">Only approve or reject</option>
              {rerunnable.map((n) => <option key={n.id} value={n.id}>Re-run from {n.title}</option>)}
            </select>
          </Labeled>
          {c.retry_from && (
            <Labeled label="Reviews allowed">
              <TextInput aria-label="Reviews allowed" type="number" min={1} max={5} value={c.max_attempts ?? 3} onChange={(e) => config({ max_attempts: Number(e.target.value) || undefined })} />
            </Labeled>
          )}
          <Labeled label="Approve needs this check to pass">
            <select aria-label="Tied check" className={SELECT} value={c.requires_check ?? ""} onChange={(e) => config({ requires_check: e.target.value || undefined })}>
              <option value="">No check</option>
              {parentChecks(graph, node.id).map((n) => <option key={n.id} value={n.id}>{n.title}</option>)}
            </select>
          </Labeled>
          <fieldset className="flex flex-col gap-1">
            <legend className={LABEL}>Show for review (none selected shows the previous steps)</legend>
            {before.filter((n) => n.type !== "trigger").map((n) => (
              <label key={n.id} className="flex items-center gap-2 text-13 text-fg-2">
                <input type="checkbox" checked={c.show?.includes(n.id) ?? false} onChange={(e) => config({ show: e.target.checked ? [...(c.show ?? []), n.id] : c.show?.filter((s) => s !== n.id) })} /> {n.title}
              </label>
            ))}
          </fieldset>
        </>
      )}
      {node.type === "wiki" && (
        <>
          <Labeled label="Page path"><TextInput mono aria-label="Page path" placeholder="Research/Findings" value={c.path ?? ""} onChange={(e) => config({ path: e.target.value })} /></Labeled>
          <Labeled label="If the page exists">
            <select aria-label="Wiki mode" className={SELECT} value={c.mode ?? "replace"} onChange={(e) => config({ mode: e.target.value })}>
              <option value="replace">Replace it (history is kept)</option>
              <option value="append">Add to the end</option>
            </select>
          </Labeled>
        </>
      )}
      {(node.type === "wiki" || node.type === "ticket") && <p className="text-12 text-fg-tertiary">Images from earlier steps are left out: this output is text only.</p>}
      {(node.type === "library" || node.type === "ticket") && (
        <Labeled label={node.type === "ticket" ? "Ticket title" : "Item title"}><TextInput aria-label="Item title" value={c.title ?? ""} onChange={(e) => config({ title: e.target.value })} /></Labeled>
      )}
      {node.type !== "trigger" && <div><Button onClick={onRemove}>Delete node</Button></div>}
    </div>
  );
}

/** A chat with a persona about this workflow, floating over the canvas. Its edits arrive as suggestions there. */
function BuildChat({ workflow, chatId, onChatId, personaId, onPersonaId, onChatting }: { workflow: Workflow; chatId?: string; onChatId: (id?: string) => void; personaId?: string; onPersonaId: (id: string) => void; onChatting: () => void }) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(true);
  const personas = usePersonas();
  // Listed default first, so that's who a new build chat starts with.
  const builders = personas.data?.personas.filter((p) => p.capabilities.workflows) ?? [];
  const persona = builders.find((p) => p.id === personaId) ?? builders[0];
  const create = useCreateChat();
  const send = useSendChatMessage(chatId ?? "");
  const messages = useChatMessages(chatId);
  const chat = useChat(chatId);
  const working = create.isPending || send.isPending || chat.data?.state === "running";
  const transcript = useRef<HTMLDivElement>(null);
  const list = (messages.data?.messages ?? []).filter((m) => m.role !== "system");
  const canSend = !!text.trim() && !!persona && !create.isPending && !send.isPending;

  useEffect(() => {
    transcript.current?.scrollTo({ top: transcript.current.scrollHeight });
  }, [list.length, open]);

  const submit = () => {
    const body = text.trim();
    if (!canSend) return;
    setText("");
    setOpen(true);
    onChatting();
    if (chatId) return send.mutate({ body });
    create.mutate(
      { title: `Workflow: ${workflow.name}`.slice(0, 200), persona_id: persona!.id, hidden: true, message: { body: `I'm editing my workflow "${workflow.name}" (id ${workflow.id}). ${body}` } },
      { onSuccess: (c) => onChatId(c.id) },
    );
  };
  const error = create.error ?? send.error;
  return (
    <div className="absolute bottom-3 left-1/2 z-10 flex w-[min(560px,calc(100%-104px))] -translate-x-1/2 flex-col gap-2 rounded-[10px] border border-border-strong bg-surface-raised p-2 shadow-lg" data-testid="workflow-build-chat">
      {(working || list.length > 0) && (
        <div className="flex items-center justify-between gap-2">
          {working && persona ? (
            <div role="status" data-testid="workflow-build-working" className="flex items-center gap-2 px-1">
              <span className="relative grid flex-none place-items-center">
                <span aria-hidden className="absolute inset-0 rounded-full opacity-60 motion-safe:animate-ping" style={{ background: persona.color }} />
                <PersonaAvatar name={persona.name} color={persona.color} src={persona.avatar_url} size={24} className="relative" />
              </span>
              <span className="animate-skeleton text-12 text-fg-secondary">{persona.name} is working…</span>
            </div>
          ) : <span />}
          {list.length > 0 && (
            <button type="button" className="text-12 text-fg-tertiary hover:text-fg-secondary" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Hide conversation" : "Show conversation"}</button>
          )}
        </div>
      )}
      {open && list.length > 0 && (
        <div ref={transcript} className="flex max-h-[min(280px,40vh)] flex-col gap-2 overflow-y-auto px-1">
          {list.map((m) => (
            <div key={m.id} className={m.role === "user" ? "self-end rounded-lg bg-selected px-2.5 py-1.5 text-13 text-fg" : "text-13"}>
              {m.role === "user" ? m.body_md.replace(/^I'm editing my workflow "[^"]*" \(id [^)]*\)\. /, "") : <Markdown>{m.body_md}</Markdown>}
            </div>
          ))}
        </div>
      )}
      {error && <Banner tone="blocked" title={error.message} />}
      {personas.data && !builders.length && (
        <p className="px-1 text-12 text-fg-secondary">No persona can create workflows yet. Turn on Create workflows for one in <Link href="/customization" className="underline">Customization</Link>.</p>
      )}
      {builders.length > 0 && (
        <div role="radiogroup" aria-label="Build as persona" className="flex flex-wrap gap-1">
          {builders.map((p) => (
            <button
              key={p.id}
              type="button"
              role="radio"
              aria-checked={p.id === persona?.id}
              // A chat keeps its persona for life, so switching starts a new one.
              onClick={() => { if (p.id !== persona?.id) { onPersonaId(p.id); onChatId(undefined); } }}
              className={`inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-12 ${p.id === persona?.id ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover"}`}
            >
              <span aria-hidden className="size-2 rounded-full" style={{ background: p.color }} />
              {p.name}
            </button>
          ))}
        </div>
      )}
      <form onSubmit={(e) => { e.preventDefault(); submit(); }} className="flex items-end gap-2">
        <TextArea
          aria-label="Describe a change"
          className="min-w-0 flex-1 resize-none"
          rows={1}
          placeholder='Describe a change, like "Add a fact check before the gate"'
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key !== "Enter" || e.shiftKey || e.nativeEvent.isComposing) return;
            e.preventDefault();
            submit();
          }}
        />
        <Button variant="primary" type="submit" disabled={!canSend}>Send</Button>
      </form>
    </div>
  );
}

function Canvas({ workflow, chatId, onChatId, personaId, onPersonaId, onApplied, onChatting }: { workflow: Workflow; chatId?: string; onChatId: (id?: string) => void; personaId?: string; onPersonaId: (id: string) => void; onApplied: () => void; onChatting: () => void }) {
  const compact = useCompact();
  const [graph, setGraph] = useState(workflow.draft as Graph);
  const [selected, setSelected] = useState<string | null>(null);
  const [inspectN, setInspectN] = useState(0);
  const inspectNode = (id: string) => {
    setSelected(id);
    setInspectN((n) => n + 1);
  };
  const flow = useReactFlow();
  const save = useSaveWorkflow(workflow.id);
  const publish = usePublishWorkflow(workflow.id);
  const resolve = useResolveProposal(workflow.id);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const canvas = useRef<HTMLDivElement>(null);
  const pending = useRef<Graph | null>(null);
  const mutate = save.mutate;

  useEffect(() => () => {
    // Leaving the editor mid-edit still saves it.
    clearTimeout(timer.current);
    if (pending.current) mutate({ graph: pending.current as never });
  }, [mutate]);

  const update = (next: Graph) => {
    setGraph(next);
    pending.current = next;
    clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      const graph = pending.current;
      pending.current = null;
      if (graph) mutate({ graph: graph as never });
    }, SAVE_DELAY);
  };

  const proposal = workflow.proposals[0];
  const preview = proposal?.graph as Graph | undefined;
  const diff = preview ? diffGraphs(graph, preview) : null;
  const shown: Graph = preview ? { nodes: [...preview.nodes, ...(diff?.removedNodes ?? [])], edges: [...preview.edges, ...(diff?.removedEdges ?? [])] } : graph;
  const added = new Set(diff?.addedEdges.map((e) => `${e.from}->${e.to}`));
  const removed = new Set(diff?.removedEdges.map((e) => `${e.from}->${e.to}`));
  const nodes = toFlowNodes(shown, (n) => ({ diff: diff?.nodes.get(n.id) }), selected);
  const edges = toFlowEdges(shown, (e) => {
    const k = `${e.from}->${e.to}`;
    return added.has(k) ? { stroke: "var(--accent)", strokeDasharray: "5 4" } : removed.has(k) ? { stroke: "var(--state-blocked)", strokeDasharray: "2 4" } : undefined;
  });
  const node = graph.nodes.find((n) => n.id === selected);

  const addNode = (type: NodeType, label: string, x?: number, y?: number) => {
    const id = newNodeId(graph, type);
    // A click drops it in view, staggered so repeated clicks don't stack.
    const box = canvas.current?.getBoundingClientRect();
    const middle = flow.screenToFlowPosition({ x: (box?.left ?? 0) + (box?.width ?? 0) / 2, y: (box?.top ?? 0) + (box?.height ?? 0) / 3 });
    const shift = (graph.nodes.length % 6) * 28;
    update({ ...graph, nodes: [...graph.nodes, { id, type, title: label, x: x ?? middle.x + shift, y: y ?? middle.y + shift, config: {} }] });
    inspectNode(id);
  };
  const onNodesChange = (changes: NodeChange<FlowNode>[]) => {
    if (preview) return;
    const moved = applyNodeChanges(changes.filter((c) => c.type === "position"), nodes);
    if (changes.some((c) => c.type === "position")) {
      update({ ...graph, nodes: graph.nodes.map((n) => { const f = moved.find((m) => m.id === n.id); return f ? { ...n, x: f.position.x, y: f.position.y } : n; }) });
    }
    for (const c of changes) {
      if (c.type === "select" && c.selected) inspectNode(c.id);
      if (c.type === "remove" && graph.nodes.find((n) => n.id === c.id)?.type !== "trigger") update(removeNode(graph, c.id));
    }
  };
  const onEdgesChange = (changes: EdgeChange[]) => {
    if (preview) return;
    const gone = new Set(changes.filter((c) => c.type === "remove").map((c) => c.id));
    if (gone.size) update({ ...graph, edges: graph.edges.filter((e) => !gone.has(`${e.from}->${e.to}`)) });
  };
  const onConnect = (c: Connection) => {
    if (!preview && canConnect(graph, c.source, c.target)) update({ ...graph, edges: [...graph.edges, { from: c.source, to: c.target }] });
  };
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    const [type, label] = e.dataTransfer.getData("application/vesper-node").split("|");
    if (!type || preview) return;
    const p = flow.screenToFlowPosition({ x: e.clientX, y: e.clientY });
    addNode(type as NodeType, label, p.x, p.y);
  };
  const flushAndPublish = () => {
    clearTimeout(timer.current);
    const next = pending.current;
    pending.current = null;
    if (next) mutate({ graph: next as never }, { onSuccess: () => publish.mutate() });
    else publish.mutate();
  };

  const issues = workflow.issues;
  const error = save.error ?? publish.error ?? resolve.error;
  const nodePalette = (
    <aside aria-label="Node types" className="min-h-0 flex-1 overflow-y-auto px-2.5 pt-4 pb-3">
      {PALETTE.map((g) => (
        <div key={g.group} className="mb-4">
          <p className="mb-1.5 px-1 text-10 font-semibold uppercase tracking-wide text-fg-tertiary">{g.group}</p>
          {g.items.map((i) => (
            <button
              key={i.type}
              type="button"
              draggable
              disabled={!!preview}
              onDragStart={(e) => e.dataTransfer.setData("application/vesper-node", `${i.type}|${i.label}`)}
              onClick={() => addNode(i.type, i.label)}
              className="mb-1.5 block w-full rounded-md border border-border-strong bg-surface px-2.5 py-1.5 text-left text-13 text-fg-2 hover:bg-hover disabled:opacity-50"
            >
              {i.label}
            </button>
          ))}
        </div>
      ))}
    </aside>
  );
  const detailsContent = (
    <>
      {error && <Banner tone="blocked" title={error.message} />}
      {node ? (
        <Inspector graph={graph} node={node} onChange={(patch) => update({ ...graph, nodes: graph.nodes.map((n) => (n.id === node.id ? { ...n, ...patch } : n)) })} onRemove={() => { update(removeNode(graph, node.id)); setSelected(null); }} />
      ) : (
        <WorkflowSettings workflow={workflow} />
      )}
      {issues.length > 0 && (
        <div data-testid="workflow-issues" className="flex flex-col gap-1 border-t border-border-subtle pt-3">
          <p className={LABEL}>Before you can publish</p>
          {issues.map((i, n) => (
            <button key={n} type="button" className="text-left text-13 text-pill-human-fg" onClick={() => i.node && inspectNode(i.node)}>{i.message}</button>
          ))}
        </div>
      )}
    </>
  );
  const detailsAside = (
    <aside aria-label="Workflow details" className="flex w-full flex-none flex-col gap-3 overflow-y-auto border-t border-border-subtle bg-panel p-4">
      {detailsContent}
    </aside>
  );
  return (
    <>
      {!compact && (
        <NavigatorPortal
          native={{
            model: buildWorkflowPaletteNavModel({ palette: PALETTE, disabled: !!preview }),
            onCommand: (cmd) => {
              if (cmd.type !== "nav.activate" || preview) return;
              const item = PALETTE.flatMap((g) => g.items).find((i) => i.type === cmd.itemId);
              if (item) addNode(item.type, item.label);
            },
          }}
        >
          {nodePalette}
        </NavigatorPortal>
      )}
      {!compact && (
        <CompanionDock
          app="workflows"
          show={{ tab: "details", n: inspectN }}
          tabs={[
            {
              id: "details",
              label: "Details",
              icon: "sliders",
              content: (
                <div aria-label="Workflow details" className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto bg-panel p-4">
                  {detailsContent}
                </div>
              ),
            },
            { id: "chat", label: "Chat", icon: "msg", content: <WorkChat /> },
          ]}
        />
      )}
      <TopBar
        crumbs={[{ label: "Workflows", href: "/workflows" }, { label: workflow.name }]}
        actions={
          <>
            <span className="font-mono text-12 text-fg-tertiary">{workflow.published_version > 0 ? `v${workflow.published_version}${workflow.unpublished_changes ? " · edited" : ""}` : "Draft"}</span>
            <span className="text-12 text-fg-tertiary">{save.isPending ? "Saving…" : "Saved"}</span>
            <Button variant="primary" onClick={flushAndPublish} disabled={issues.length > 0 || publish.isPending || !!preview || !workflow.unpublished_changes} hint={issues[0]?.message}>Publish</Button>
          </>
        }
      />
      <div className="flex min-h-0 flex-1 max-md:flex-col">
        <div ref={canvas} className="relative min-h-[320px] min-w-0 flex-1" onDrop={onDrop} onDragOver={(e) => e.preventDefault()}>
          {proposal && (
            <div data-testid="workflow-proposal" className="absolute left-1/2 top-3 z-10 flex max-w-[90%] -translate-x-1/2 items-center gap-3 rounded-[10px] border border-accent bg-surface-raised px-3 py-2 shadow-lg">
              <span className="text-13 text-fg">{proposal.summary}</span>
              <Button variant="primary" disabled={resolve.isPending} onClick={() => resolve.mutate({ proposalId: proposal.id, action: "apply" }, { onSuccess: onApplied })}>Apply</Button>
              <Button disabled={resolve.isPending} onClick={() => resolve.mutate({ proposalId: proposal.id, action: "discard" })}>Discard</Button>
            </div>
          )}
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={NODE_TYPES}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            onPaneClick={() => setSelected(null)}
            nodesDraggable={!preview}
            nodesConnectable={!preview}
            deleteKeyCode={preview ? null : ["Backspace", "Delete"]}
            style={FLOW_STYLE}
            fitView
            proOptions={{ hideAttribution: true }}
          >
            <Background gap={20} size={1} />
            <Controls showInteractive={false} />
          </ReactFlow>
          <BuildChat workflow={workflow} chatId={chatId} onChatId={onChatId} personaId={personaId} onPersonaId={onPersonaId} onChatting={onChatting} />
        </div>
        {compact && detailsAside}
      </div>
    </>
  );
}

function WorkflowSettings({ workflow }: { workflow: Workflow }) {
  const save = useSaveWorkflow(workflow.id);
  const [name, setName] = useState(workflow.name);
  const [description, setDescription] = useState(workflow.description);
  return (
    <div className="flex flex-col gap-3">
      <Labeled label="Name"><TextInput aria-label="Workflow name" value={name} onChange={(e) => setName(e.target.value)} onBlur={() => name.trim() && name !== workflow.name && save.mutate({ name })} /></Labeled>
      <Labeled label="When to use it (personas read this to recognize a request)">
        <TextArea aria-label="Description" rows={4} value={description} onChange={(e) => setDescription(e.target.value)} onBlur={() => description !== workflow.description && save.mutate({ description })} />
      </Labeled>
      <p className="text-13 text-fg-tertiary">Select a node to edit it. Drag from a node&apos;s right edge to connect it.</p>
    </div>
  );
}

export function WorkflowEditorScreen() {
  const { id } = useParams<{ id: string }>();
  const [poll, setPoll] = useState(false);
  const [revision, setRevision] = useState(0);
  const [chatId, setChatId] = useState<string>();
  const [personaId, setPersonaId] = useState<string>();
  const workflow = useWorkflow(id, poll);
  return (
    // The shell only sets a minimum height, so hold the editor to the viewport to keep the floating chat on screen.
    <div className="flex min-h-0 flex-1 flex-col md:sticky md:top-0 md:h-dvh md:flex-none">
      {workflow.error ? (
        <div className="p-6"><Banner tone="blocked" title={workflow.error.message} /></div>
      ) : !workflow.data ? (
        <Skeleton className="m-6 h-96" />
      ) : (
        <ReactFlowProvider>
          {/* Applying a suggestion replaces the draft, so the canvas starts over from it. */}
          <Canvas key={revision} workflow={workflow.data} chatId={chatId} onChatId={setChatId} personaId={personaId} onPersonaId={setPersonaId} onApplied={() => setRevision((r) => r + 1)} onChatting={() => setPoll(true)} />
        </ReactFlowProvider>
      )}
    </div>
  );
}
