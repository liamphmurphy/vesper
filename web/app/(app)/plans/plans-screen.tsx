"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useMemo, useRef, useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, contentUrl, type LinkTarget, type Schemas } from "@/lib/api/client";
import { useBootstrap, useChatRunEvents, useResolved } from "@/lib/api/hooks";
import { Button, ButtonLink } from "@/components/ui/button";
import {
  Banner,
  Card,
  EmptyState,
  Field,
  Skeleton,
  TextInput,
} from "@/components/ui/primitives";
import { Content, TopBar } from "@/components/shell/topbar";
import { ProjectScopeState, projectCrumbs, useProjectScope } from "@/components/shell/project-scope";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { LinkEditor } from "@/components/domain/link-editor";
import { Pill, SmallPill } from "@/components/domain/labels";
import { Icon } from "@/components/ui/icon";
import { AddContext, ChipList, SentChips, acceptTarget } from "@/app/(app)/chat/_components/context-chips";
import { ActivityRef } from "@/app/(app)/chat/_components/activity";
import {
  MAX_CONTEXT_REFS,
  addChip,
  chipFromRef,
  chipFromTarget,
  parseAttach,
  removeChip,
  toContextRefs,
  type Chip,
  type ContextRef,
} from "@/lib/chat-context";
import { firstLine, planCount, planLive, planStatus, readSources } from "@/lib/plans";
import { dependencyProblems } from "@/lib/proposals";
import { ago } from "@/lib/format";
import { cx } from "@/lib/cx";
import { Spinner } from "@/components/ui/loading";

type Plan = Schemas["PlanningSession"];
type Proposal = Schemas["TicketProposal"];
type Bootstrap = Schemas["Bootstrap"];
type Project = Schemas["Project"];
const control =
  "w-full rounded-md border border-border-strong bg-surface px-2.5 py-2 text-14 text-fg";
const message = (e: unknown) =>
  e instanceof Error ? e.message : "Something went wrong. Please try again.";

function Runtime({ handle, project }: { handle: string; project: string }) {
  const q = useResolved(handle, project);
  if (q.isLoading) return <Skeleton className="h-10" />;
  if (q.isError) return <p role="alert">Couldn’t load the agent runtime.</p>;
  return (
    <p className="font-mono text-12 text-fg-secondary">
      {q.data?.harness} · {q.data?.model}
    </p>
  );
}

/** project comes from the sidebar switcher (?project=, then the remembered one). */
function NewPlan({ data, project: scoped }: { data: Bootstrap; project: Project }) {
  const search = useSearchParams(),
    router = useRouter(),
    qc = useQueryClient();
  const project = scoped.key;
  // Planner agents are main agents: sub agents only run when delegated to.
  const planners = data.agents.filter((a) => a.kind === "main");
  const [agent, setAgent] = useState(planners[0]?.id || "");
  // ?goal= prefills from the command palette ("Start planning: …").
  const [goal, setGoal] = useState(search.get("goal") ?? "");
  // "Plan with agent" links arrive with ?attach=, ?epic= or ?artifact= (a PRD/SPEC whose version is pinned).
  const [chips, setChips] = useState<Chip[]>(() => parseAttach(search.getAll("attach"), search.get("attach_title")));
  const epics = data.epics.filter((e) => e.project_id === scoped.id && e.status === "open");
  const [epic, setEpic] = useState(() => {
    const id = search.get("epic");
    return id && data.epics.some((e) => e.id === id && e.project_id === scoped.id) ? id : "";
  });
  const [artifact, setArtifact] = useState(search.get("artifact") || undefined);
  const area = useRef<HTMLTextAreaElement | null>(null);
  const selected = planners.find((a) => a.id === agent);
  const attach = (t: LinkTarget) => {
    const chip = chipFromTarget(t);
    if (chip) setChips((cs) => addChip(cs, chip));
  };
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.POST("/planning-sessions", {
          body: {
            project,
            agent_id: agent,
            goal,
            epic_id: epic || undefined,
            artifact_id: artifact,
            context_refs: toContextRefs(chips),
          },
        }),
      ),
    onSuccess: (p) => {
      void qc.invalidateQueries({ queryKey: ["planning"] });
      router.push(`/plans?id=${p.id}`);
    },
  });
  const needsGoal = !artifact && !epic;
  const ready = !!agent && (!needsGoal || !!goal.trim()) && !create.isPending;
  function submit(e?: FormEvent) {
    e?.preventDefault();
    if (ready) create.mutate();
  }
  return (
    <Card
      title="New plan"
      action={
        <span className="flex h-6 items-center gap-2 rounded-md border border-border-strong bg-surface-sunken px-2 text-12" title="Switch spaces in the sidebar">
          <span aria-hidden className="size-2 flex-none rounded-[2px]" style={{ background: scoped.color }} />
          <span className="max-w-[140px] truncate">{scoped.name}</span>
          <span className="font-mono text-11 text-fg-tertiary">{scoped.key}</span>
        </span>
      }
    >
      <form onSubmit={submit} className="space-y-5" aria-label="New plan">
        <p className="text-14 text-fg-secondary">
          Describe the goal and attach what the planner should read. You review
          proposals before any tickets exist.
        </p>
        <div className="flex flex-col gap-1.5">
          <label htmlFor="plan-goal" className="text-13 font-medium text-fg-2">
            {needsGoal ? "Goal" : "Additional goal (optional)"}
          </label>
          <div className="flex flex-col gap-2 rounded-lg border border-border-strong bg-surface-sunken p-2 focus-within:border-accent">
            <LinkEditor
              id="plan-goal"
              inputRef={(el) => {
                area.current = el;
              }}
              mono={false}
              aria-label="Goal"
              rows={8}
              maxLength={20000}
              value={goal}
              onChange={setGoal}
              onPick={attach}
              accept={acceptTarget}
              disabled={create.isPending}
              placeholder="What should this plan accomplish? Type [[ to attach wiki pages, artifacts and tickets."
              className="!border-0 !bg-transparent !p-1 focus-visible:!outline-none"
              onKeyDown={(e) => {
                if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  submit();
                }
              }}
            />
            {(artifact || chips.length > 0) && (
              <div className="flex flex-wrap items-center gap-1.5 px-1">
                {artifact && (
                  <span className="inline-flex h-6 items-center gap-1.5 rounded-md border border-border bg-surface px-2 text-12 text-fg-secondary" data-testid="plan-source">
                    <Link href={`/artifacts/${artifact}`} className="hover:text-fg">Source document (pinned version)</Link>
                    <button
                      type="button"
                      aria-label="Remove source document"
                      onClick={() => setArtifact(undefined)}
                      className="grid size-4 cursor-pointer place-items-center rounded-xs text-fg-tertiary hover:bg-hover hover:text-fg"
                    >
                      ×
                    </button>
                  </span>
                )}
                <ChipList chips={chips} onRemove={(k) => setChips((cs) => removeChip(cs, k))} disabled={create.isPending} />
              </div>
            )}
            <div className="flex flex-wrap items-center gap-2 border-t border-border px-1 pt-2">
              <AddContext onPick={attach} onClosed={() => area.current?.focus()} disabled={create.isPending || chips.length >= MAX_CONTEXT_REFS} />
              <span className="text-12 text-fg-tertiary">
                or type [[ to attach wiki pages, artifacts and tickets · {chips.length} of {MAX_CONTEXT_REFS}
              </span>
              <span className="flex-1" />
              <span className="text-12 text-fg-tertiary">⌘↵ to start</span>
            </div>
          </div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Planner agent">
            <select
              className={control}
              aria-label="Planner agent"
              value={agent}
              onChange={(e) => setAgent(e.target.value)}
            >
              {planners.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name} · @{a.handle}
                </option>
              ))}
            </select>
            {selected && <Runtime handle={selected.handle} project={project} />}
          </Field>
          <Field
            label="Epic (optional)"
            hint={epic ? "Accepted tickets join this epic." : "Accepting creates a new epic. Pick one to extend it instead."}
          >
            <select className={control} aria-label="Epic" value={epic} onChange={(e) => setEpic(e.target.value)}>
              <option value="">No epic</option>
              {epics.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.name}
                </option>
              ))}
            </select>
          </Field>
        </div>
        <Banner tone="human" title="Approve a restricted planning run">
          The planner can read context and submit proposals. Repository writes,
          setup, credentials and extra MCP servers are excluded. Starting a plan
          may incur model costs; it waits in the queue if no runner is online.
        </Banner>
        {create.error && (
          <p role="alert" className="text-14 text-pill-blocked-fg">
            {message(create.error)}
          </p>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <Button type="submit" variant="approve" disabled={!ready}>
            {create.isPending ? "Starting…" : "Approve & start planning"}
          </Button>
          <span className="text-12 text-fg-tertiary">The planner gets the attached documents when its run starts.</span>
        </div>
      </form>
    </Card>
  );
}

function ExistingBlockers({
  initial,
  onChange,
}: {
  initial: string[];
  onChange: (keys: string[]) => void;
}) {
  const [text, setText] = useState(initial.join(", "));
  return (
    <Field
      label="Existing blocker tickets"
      hint="Optional ticket keys, separated by commas. These tickets must also be Done."
    >
      <TextInput
        aria-label="Existing blocker tickets"
        value={text}
        placeholder="PAY-214, PAY-224"
        onChange={(e) => {
          setText(e.target.value);
          onChange(
            e.target.value
              .split(/[,\s]+/)
              .filter(Boolean)
              .map((key) => key.toUpperCase()),
          );
        }}
      />
    </Field>
  );
}

function Review({ plan, data }: { plan: Plan; data: Bootstrap }) {
  const qc = useQueryClient();
  const [items, setItems] = useState<Proposal[]>(() =>
    plan.proposals.map((p, i) => ({ ...p, ref: p.ref || `ticket-${i + 1}` })),
  );
  const [selected, setSelected] = useState(
    () => new Set(items.map((p) => p.ref!)),
  );
  const [active, setActive] = useState(items[0]?.ref);
  const baseline = (p: Proposal) =>
    p.planner_estimate ??
    plan.proposals.find((original) => original.ref === p.ref)
      ?.planner_estimate ?? {
      points: plan.proposals.find((original) => original.ref === p.ref)
        ?.estimate_points,
      rationale: plan.proposals.find((original) => original.ref === p.ref)
        ?.estimate_rationale,
    };
  const changed = (p: Proposal) => p.estimate_points !== baseline(p).points;
  const problems = dependencyProblems(items, selected);
  const allProblems = dependencyProblems(
    items,
    new Set(items.map((p) => p.ref!)),
  );
  const chosen = items.filter((p) => selected.has(p.ref!));
  const archived = !!data.projects.find((p) => p.key === plan.project)
    ?.archived;
  const [revision, setRevision] = useState(plan.revision);
  const [dispatch, setDispatch] = useState(false);
  const review = useMutation({
    mutationFn: ({
      action,
      proposals = items,
    }: {
      action: "save" | "accept" | "dismiss";
      proposals?: Proposal[];
    }) =>
      unwrap(
        api.PATCH("/planning-sessions/{id}", {
          params: { path: { id: plan.id } },
          body: { revision, action, proposals },
        }),
      ),
    onSuccess: (p) => {
      setRevision(p.revision);
      setItems(p.proposals);
      qc.setQueryData(["planning", plan.id], p);
      void qc.invalidateQueries({ queryKey: ["planning"] });
      void qc.invalidateQueries({ queryKey: ["tickets"] });
      void qc.invalidateQueries({ queryKey: ["bootstrap"] });
    },
  });
  const edit = (index: number, patch: Partial<Proposal>) =>
    setItems(items.map((p, i) => (i === index ? { ...p, ...patch } : p)));
  if (plan.state === "accepted") {
    const assigned = plan.ready_keys;
    return (
      <Card title={`Tickets created · ${planCount(plan)}`}>
        <div className="space-y-4">
          <p className="text-14 text-fg-secondary">
            Assigned tickets whose blockers are Done are ready now. Dependent
            tickets can be dispatched too: they queue and start once their
            blockers are Done.
          </p>
          {plan.epic_id && (
            <ButtonLink variant="outline" href={`/epics/${plan.epic_id}`}>
              View epic
            </ButtonLink>
          )}
          {plan.ticket_keys.map((key, i) => (
            <Link
              key={key}
              className="block text-14 text-accent"
              href={`/tickets/${key}`}
            >
              {key} · {plan.proposals[i]?.title}
            </Link>
          ))}
          <ButtonLink
            variant="outline"
            href={`/tickets?project=${plan.project}&view=all&ready=true`}
          >
            View ready tickets
          </ButtonLink>
          {assigned.length > 0 && (
            <Button variant="secondary" onClick={() => setDispatch(true)}>
              Review & dispatch {assigned.length} ready tickets…
            </Button>
          )}
          <DispatchDialog
            keys={assigned}
            open={dispatch}
            onOpenChange={setDispatch}
          />
        </div>
      </Card>
    );
  }
  if (plan.state === "dismissed")
    return (
      <EmptyState icon="epics" title="Plan dismissed">
        No tickets were created.
      </EmptyState>
    );
  return (
    <div className="space-y-4">
      {plan.revision !== revision && (
        <Banner tone="human" title="This draft has changed">
          Your edits are preserved. Reload the page to review the latest draft
          before saving.
        </Banner>
      )}
      {data.projects.find((p) => p.key === plan.project)?.archived && (
        <Banner tone="human" title="This space’s work is archived">
          Restore the project in Settings before accepting these proposals.
        </Banner>
      )}
      <div className="grid gap-4 lg:grid-cols-[minmax(240px,1fr)_2fr]">
        <aside className="space-y-4">
          <Card title={`Drafts · ${items.length}`}>
            <div className="space-y-2">
              {items.map((p, i) => (
                <div
                  key={p.ref}
                  className={cx(
                    "flex items-start gap-2 rounded-md p-2",
                    active === p.ref && "bg-surface-raised",
                  )}
                >
                  <input
                    type="checkbox"
                    aria-label={`Select draft ${i + 1}`}
                    checked={selected.has(p.ref!)}
                    disabled={review.isPending}
                    onChange={(e) =>
                      setSelected((prev) => {
                        const next = new Set(prev);
                        if (e.target.checked) next.add(p.ref!);
                        else next.delete(p.ref!);
                        return next;
                      })
                    }
                  />
                  <button
                    className="flex-1 text-left text-14"
                    aria-pressed={active === p.ref}
                    onClick={() => setActive(p.ref)}
                  >
                    {i + 1} · {p.title || "Untitled"}
                    <span className="block text-12 text-fg-secondary">
                      {p.estimate_points ?? "—"} pts{" "}
                      {changed(p) ? "● estimate changed" : ""} ·{" "}
                      {p.requires_mockup ? "needs mockup · " : ""}
                      {(p.depends_on?.length ?? 0) +
                        (p.blocked_by?.length ?? 0)}{" "}
                      dependencies
                    </span>
                  </button>
                </div>
              ))}
            </div>
          </Card>
          <Card title="Dependencies">
            <p className="mb-2 text-12 text-fg-secondary">
              Blocker → blocked draft
            </p>
            <ul className="space-y-2 text-14" aria-label="Dependency links">
              {items.map((p) => (
                <li key={p.ref}>
                  {[
                    ...(p.depends_on ?? []).map(
                      (ref) =>
                        items.find((other) => other.ref === ref)?.title || ref,
                    ),
                    ...(p.blocked_by ?? []),
                  ].join(", ") || "No blockers"}{" "}
                  → {p.title || p.ref}
                </li>
              ))}
            </ul>
            {problems.map((problem) => (
              <p
                key={problem}
                role="alert"
                className="mt-2 text-14 text-pill-blocked-fg"
              >
                {problem}
              </p>
            ))}
          </Card>
        </aside>
        <fieldset disabled={review.isPending} className="min-w-0 space-y-4">
          {items.map((item, index) =>
            active !== item.ref ? null : (
              <Card
                key={item.ref}
                title={`Ticket ${index + 1}`}
                action={
                  <div className="flex gap-1">
                    <Button
                      variant="ghost"
                      aria-label="Move draft up"
                      disabled={index === 0 || review.isPending}
                      onClick={() => {
                        const next = [...items];
                        [next[index - 1], next[index]] = [
                          next[index],
                          next[index - 1],
                        ];
                        setItems(next);
                      }}
                    >
                      ↑
                    </Button>
                    <Button
                      variant="ghost"
                      aria-label="Move draft down"
                      disabled={index === items.length - 1 || review.isPending}
                      onClick={() => {
                        const next = [...items];
                        [next[index + 1], next[index]] = [
                          next[index],
                          next[index + 1],
                        ];
                        setItems(next);
                      }}
                    >
                      ↓
                    </Button>
                    <Button
                      variant="ghost"
                      disabled={
                        review.isPending ||
                        items.some(
                          (p, i) =>
                            i !== index && p.depends_on?.includes(item.ref!),
                        )
                      }
                      title="Remove dependencies on this proposal before dropping it"
                      onClick={() => {
                        setItems(items.filter((_, i) => i !== index));
                        setActive(items.find((_, i) => i !== index)?.ref);
                        setSelected((prev) => {
                          const next = new Set(prev);
                          next.delete(item.ref!);
                          return next;
                        });
                      }}
                    >
                      Drop
                    </Button>
                  </div>
                }
              >
                <div className="space-y-3">
                  <Field label="Title">
                    <TextInput
                      aria-label={`Ticket ${index + 1} title`}
                      value={item.title}
                      maxLength={300}
                      onChange={(e) => edit(index, { title: e.target.value })}
                    />
                  </Field>
                  <Field label="Description">
                    <textarea
                      className={control}
                      aria-label={`Ticket ${index + 1} description`}
                      rows={5}
                      value={item.description}
                      onChange={(e) =>
                        edit(index, { description: e.target.value })
                      }
                    />
                  </Field>
                  <Field label="Acceptance criteria">
                    <div className="space-y-2">
                      {item.criteria.map((criterion, c) => (
                        <div key={c} className="flex gap-1">
                          <TextInput
                            aria-label={`Criterion ${c + 1}`}
                            value={criterion}
                            maxLength={2000}
                            onChange={(e) =>
                              edit(index, {
                                criteria: item.criteria.map((v, n) =>
                                  n === c ? e.target.value : v,
                                ),
                              })
                            }
                          />
                          <Button
                            variant="ghost"
                            aria-label={`Move criterion ${c + 1} up`}
                            disabled={c === 0}
                            onClick={() => {
                              const criteria = [...item.criteria];
                              [criteria[c - 1], criteria[c]] = [
                                criteria[c],
                                criteria[c - 1],
                              ];
                              edit(index, { criteria });
                            }}
                          >
                            ↑
                          </Button>
                          <Button
                            variant="ghost"
                            aria-label={`Move criterion ${c + 1} down`}
                            disabled={c === item.criteria.length - 1}
                            onClick={() => {
                              const criteria = [...item.criteria];
                              [criteria[c + 1], criteria[c]] = [
                                criteria[c],
                                criteria[c + 1],
                              ];
                              edit(index, { criteria });
                            }}
                          >
                            ↓
                          </Button>
                          <Button
                            variant="ghost"
                            aria-label={`Remove criterion ${c + 1}`}
                            onClick={() =>
                              edit(index, {
                                criteria: item.criteria.filter(
                                  (_, n) => n !== c,
                                ),
                              })
                            }
                          >
                            ×
                          </Button>
                        </div>
                      ))}
                      <Button
                        variant="outline"
                        disabled={item.criteria.length >= 30}
                        onClick={() =>
                          edit(index, { criteria: [...item.criteria, ""] })
                        }
                      >
                        Add criterion
                      </Button>
                    </div>
                  </Field>
                  <Field label="Estimate">
                    <div
                      className="flex flex-wrap gap-2"
                      role="group"
                      aria-label="Points"
                    >
                      {([1, 2, 3, 5, 8, 13, undefined] as const).map(
                        (points) => (
                          <Button
                            key={points ?? "none"}
                            variant={
                              item.estimate_points === points
                                ? "primary"
                                : "outline"
                            }
                            aria-pressed={item.estimate_points === points}
                            onClick={() =>
                              edit(index, { estimate_points: points })
                            }
                          >
                            {points ?? "Unestimated"}
                          </Button>
                        ),
                      )}
                    </div>
                    {changed(item) && (
                      <p className="mt-2 text-14 text-pill-human-fg">
                        Changed from {baseline(item).points ?? "unestimated"}.{" "}
                        <button
                          className="text-accent"
                          onClick={() =>
                            edit(index, {
                              estimate_points: baseline(item).points,
                            })
                          }
                        >
                          Reset estimate
                        </button>
                      </p>
                    )}
                    <p className="mt-2 text-14 text-fg-secondary">
                      Planner’s rationale ({baseline(item).points ?? "—"} pts):{" "}
                      {baseline(item).rationale || "No rationale supplied."}
                    </p>
                  </Field>
                  <Field label="Estimate rationale">
                    <TextInput
                      aria-label="Estimate rationale"
                      value={item.estimate_rationale ?? ""}
                      maxLength={2000}
                      onChange={(e) =>
                        edit(index, { estimate_rationale: e.target.value })
                      }
                    />
                  </Field>
                  <p className="text-14 text-fg-secondary">
                    Epic:{" "}
                    {data.epics.find((e) => e.id === plan.epic_id)?.name ||
                      "New epic from this plan’s goal"}
                  </p>
                  <Field
                    label="Waits for these proposals"
                    hint="Blockers must be Done before this ticket can be dispatched."
                  >
                    {items.length < 2 && (
                      <p className="text-12 text-fg-tertiary">
                        No other proposals.
                      </p>
                    )}
                    {items.map((other, i) =>
                      i === index ? null : (
                        <label
                          key={other.ref}
                          className="flex items-start gap-2 text-14"
                        >
                          <input
                            type="checkbox"
                            className="mt-1 accent-[var(--accent)]"
                            checked={
                              item.depends_on?.includes(other.ref!) ?? false
                            }
                            onChange={(e) =>
                              edit(index, {
                                depends_on: e.target.checked
                                  ? [...(item.depends_on ?? []), other.ref!]
                                  : (item.depends_on ?? []).filter(
                                      (ref) => ref !== other.ref,
                                    ),
                              })
                            }
                          />
                          <span>
                            Ticket {i + 1} · {other.title || "Untitled"}
                          </span>
                        </label>
                      ),
                    )}
                  </Field>
                  <ExistingBlockers
                    initial={item.blocked_by ?? []}
                    onChange={(blocked_by) => edit(index, { blocked_by })}
                  />
                  <Field label="Assign to">
                    <select
                      className={control}
                      aria-label={`Ticket ${index + 1} agent`}
                      value={item.agent_id || ""}
                      onChange={(e) =>
                        edit(index, { agent_id: e.target.value || undefined })
                      }
                    >
                      <option value="">Unassigned</option>
                      {data.agents.filter((a) => a.kind === "main").map((a) => (
                        <option key={a.id} value={a.id}>
                          {a.name}
                        </option>
                      ))}
                    </select>
                  </Field>
                  <label className="flex items-center gap-2 text-14 text-fg-secondary">
                    <input
                      type="checkbox"
                      checked={!!item.requires_mockup}
                      onChange={(e) =>
                        edit(index, { requires_mockup: e.target.checked })
                      }
                    />
                    Requires mockup
                  </label>
                </div>
              </Card>
            ),
          )}
        </fieldset>
      </div>
      {review.error && (
        <p role="alert" className="text-14 text-pill-blocked-fg">
          {message(review.error)}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button
          variant="outline"
          disabled={review.isPending || items.length >= 50}
          onClick={() => {
            const ref = crypto.randomUUID();
            setItems([
              ...items,
              { ref, title: "", description: "", criteria: [], depends_on: [] },
            ]);
            setActive(ref);
            setSelected((prev) => new Set([...prev, ref]));
          }}
        >
          Add proposal
        </Button>
        <Button
          variant="ghost"
          disabled={review.isPending}
          onClick={() => review.mutate({ action: "dismiss" })}
        >
          Dismiss plan
        </Button>
        <Button
          variant="secondary"
          disabled={review.isPending || !items.length}
          onClick={() => review.mutate({ action: "save" })}
        >
          Save draft
        </Button>
        <p className="w-full text-14 text-fg-secondary">
          {chosen.length} of {items.length} selected ·{" "}
          {chosen.reduce((sum, p) => sum + (p.estimate_points ?? 0), 0)} points
          · {chosen.filter((p) => p.requires_mockup).length} need mockups ·{" "}
          {chosen.filter(changed).length} estimates changed
        </p>
        <p className="w-full text-12 text-fg-secondary">
          Acceptance finishes this review. Unselected drafts will not create
          tickets.
        </p>
        <Button
          variant="primary"
          disabled={
            review.isPending ||
            archived ||
            !chosen.length ||
            problems.length > 0
          }
          onClick={() => review.mutate({ action: "accept", proposals: chosen })}
        >
          Accept selected ({chosen.length})
        </Button>
        <Button
          variant="outline"
          disabled={
            review.isPending ||
            archived ||
            !items.length ||
            allProblems.length > 0
          }
          onClick={() => review.mutate({ action: "accept", proposals: items })}
        >
          Accept all ({items.length})
        </Button>
      </div>
    </div>
  );
}

/** What the planner has read, from its run's tool calls (polled while live). */
function SourcesRead({ plan, live }: { plan: Plan; live: boolean }) {
  const events = useChatRunEvents(plan.run_id, true, live);
  const sources = useMemo(() => readSources(events.data), [events.data]);
  if (!live && sources.length === 0) return null;
  const list = (
    <ul className="flex flex-col gap-1.5" data-testid="plan-sources">
      {sources.map((src) => (
        <li key={src.key} className="flex min-w-0 items-center gap-2 text-13 text-fg-secondary">
          {src.done ? (
            <Icon name="check" size={12} className="flex-none text-pill-done-fg" />
          ) : (
            <Spinner />
          )}
          <span className="min-w-0 truncate">
            {src.activity.verb}{" "}
            {src.activity.ref && src.activity.label ? (
              <ActivityRef refText={src.activity.ref} label={src.activity.label} />
            ) : (
              <span className="text-fg">{src.activity.text}</span>
            )}
          </span>
        </li>
      ))}
    </ul>
  );
  if (!live)
    return (
      <details className="rounded-lg border border-border bg-surface px-3 py-2">
        <summary className="cursor-pointer text-13 text-fg-secondary">Sources read ({sources.length})</summary>
        <div className="mt-2">{list}</div>
      </details>
    );
  return (
    <section aria-label="Sources read so far" className="space-y-2">
      <h3 className="type-micro text-fg-tertiary">SOURCES READ SO FAR</h3>
      {sources.length === 0 ? (
        <p role="status" className="text-13 text-fg-tertiary">
          {plan.run_state === "queued" ? "Waiting for a runner…" : "The planner hasn’t read anything yet."}
        </p>
      ) : (
        list
      )}
    </section>
  );
}

function PlanDetail({ plan, data }: { plan: Plan; data: Bootstrap }) {
  const live = planLive(plan);
  const status = planStatus(plan);
  const attached = plan.context_refs.map((r) => chipFromRef(r as ContextRef));
  const epicName = plan.epic_id && data.epics.find((e) => e.id === plan.epic_id)?.name;
  return (
    <div className="space-y-5">
      <Card
        title={live ? "Planning run" : "Plan"}
        action={
          <ButtonLink href={`/runs/${plan.run_id}`} variant="outline">
            View run log
          </ButtonLink>
        }
      >
        <div className="space-y-4">
          <div className="flex items-center gap-2">
            <Pill tone={status.tone}>{status.label}</Pill>
            <span className="font-mono text-12 text-fg-tertiary">
              {plan.project} · {plan.harness} · {plan.model}
            </span>
          </div>
          <h2 className="type-heading whitespace-pre-wrap break-words">
            {plan.goal}
          </h2>
          {epicName && <p className="text-14 text-fg-secondary">Epic: {epicName}</p>}
          {(plan.artifact_id || attached.length > 0) && (
            <div className="flex flex-wrap items-center gap-1.5">
              {plan.artifact_id && (
                <ButtonLink
                  href={plan.source_version_id ? contentUrl(plan.artifact_id, plan.source_version_id) : `/artifacts/${plan.artifact_id}`}
                  variant="ghost"
                >
                  Source document
                </ButtonLink>
              )}
              <SentChips chips={attached} />
            </div>
          )}
          {plan.state === "planning" && (
            <p role="status" className="text-14 text-fg-secondary">
              {live
                ? "The planner will submit draft tickets here. No tickets have been created."
                : plan.outcome || "Planning stopped. Start a new plan to retry."}
            </p>
          )}
          {plan.state === "review" && (
            <Banner tone="human" title={`${plan.proposals.length} proposals ready for review`}>
              <a href="#proposal-review" className="text-accent hover:underline">
                Review the proposals
              </a>{" "}
              below; no tickets exist until you accept them.
            </Banner>
          )}
          <SourcesRead plan={plan} live={live} />
        </div>
      </Card>
      {plan.state !== "planning" && (
        <section id="proposal-review" aria-label="Proposal review" className="scroll-mt-4">
          <Review key={plan.id} plan={plan} data={data} />
        </section>
      )}
    </div>
  );
}

function PlanRow({ plan, active }: { plan: Plan; active: boolean }) {
  const status = planStatus(plan);
  return (
    <Link
      href={`/plans?id=${plan.id}`}
      aria-current={active ? "page" : undefined}
      className={cx(
        "block rounded-md border border-border px-3 py-2.5 hover:bg-hover",
        active && "bg-selected",
      )}
      data-testid="plan-row"
    >
      <span className="flex items-center gap-2">
        <SmallPill tone={status.tone}>{status.label}</SmallPill>
        <span className="flex-1" />
        <span className="text-11 text-fg-tertiary">{planCount(plan)}</span>
      </span>
      <span className="mt-1.5 block truncate text-14">{firstLine(plan.goal)}</span>
      <span className="mt-0.5 block text-12 text-fg-tertiary">
        {plan.project} · {ago(plan.created_at)}
      </span>
    </Link>
  );
}

export function PlansScreen() {
  const router = useRouter();
  const search = useSearchParams();
  const id = search.get("id");
  const bootstrap = useBootstrap();
  // A new plan needs one project; an open plan (?id=) carries its own.
  const scope = useProjectScope("required", { skip: !!id });
  const scoped = scope.status === "ready" ? scope.project : undefined;
  const list = useQuery({
    queryKey: ["planning", "list"],
    queryFn: () => unwrap(api.GET("/planning-sessions")),
    refetchInterval: 15000,
  });
  const detail = useQuery({
    queryKey: ["planning", id],
    enabled: !!id,
    queryFn: () =>
      unwrap(
        api.GET("/planning-sessions/{id}", { params: { path: { id: id! } } }),
      ),
    refetchInterval: 5000,
  });
  return (
    <>
      <TopBar
        crumbs={projectCrumbs(
          id ? bootstrap.data?.projects.find((p) => p.key === detail.data?.project) : scoped,
          "Plans",
        )}
        nativeActions={[{ id: "plans.new", label: "New plan", kind: "button", icon: "plus", showsLabel: true, run: () => router.push("/plans") }]}
        actions={
          <ButtonLink href="/plans" variant="outline">
            New plan
          </ButtonLink>
        }
      />
      <Content>
        <div className="grid min-w-0 gap-6 lg:grid-cols-[240px_minmax(0,1fr)]">
          <aside className="space-y-2">
            <h2 className="type-micro mb-3 flex text-fg-tertiary">
              <span className="flex-1">PLANS</span>
              {list.data && <span>{list.data.length}</span>}
            </h2>
            {list.isLoading && <Skeleton className="h-24" />}
            {list.isError && (
              <p role="alert" className="text-14 text-pill-blocked-fg">
                Couldn’t load plans.
              </p>
            )}
            {list.data?.length === 0 && (
              <p className="text-14 text-fg-tertiary">
                Your plans will appear here.
              </p>
            )}
            {list.data?.map((p) => (
              <PlanRow key={p.id} plan={p} active={p.id === id} />
            ))}
            {!!list.data?.length && (
              <p className="pt-1 text-12 text-fg-tertiary">
                Status · first line of the goal · tickets accepted / proposals made
              </p>
            )}
          </aside>
          <main className="min-w-0 max-w-[900px]">
            {(bootstrap.isLoading || (id && detail.isLoading)) && (
              <Skeleton className="h-64" />
            )}
            {(bootstrap.isError || (id && detail.isError)) && (
              <Banner tone="blocked" title="Couldn’t load this plan">
                {message(detail.error || bootstrap.error)}
              </Banner>
            )}
            {bootstrap.data &&
              (id ? (
                detail.data && (
                  <PlanDetail
                    key={id}
                    plan={detail.data}
                    data={bootstrap.data}
                  />
                )
              ) : !scoped ? (
                <ProjectScopeState base="/plans" scope={scope} />
              ) : bootstrap.data.agents.some((a) => a.kind === "main") ? (
                <NewPlan key={search.toString()} data={bootstrap.data} project={scoped} />
              ) : (
                <EmptyState
                  icon="epics"
                  title="Create an agent first"
                  actions={
                    <ButtonLink href="/agents" variant="outline">
                      Go to agents
                    </ButtonLink>
                  }
                >
                  Planning needs an active project and at least one persona that takes tickets.
                </EmptyState>
              ))}
          </main>
        </div>
      </Content>
    </>
  );
}
