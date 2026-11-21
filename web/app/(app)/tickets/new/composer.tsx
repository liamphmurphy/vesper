"use client";

import { DropdownMenu, Dialog } from "radix-ui";
import { workSettingsHref } from "@/lib/spaces";
import { useRouter, useSearchParams } from "next/navigation";
import { useState, type ComponentProps, type ReactNode } from "react";
import type { Priority, TicketStatus } from "@/lib/api/client";
import { useBootstrap, useCreateTicket } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { dueDate } from "@/lib/format";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { HumanAvatar } from "@/components/domain/avatars";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { PRIORITY_NAME, STATUS_NAME } from "@/components/domain/meta";
import { AgentPicker, EpicMenu, floatPanel, LabelPicker, PriorityMenu, StatusMenu, UserMenu } from "@/components/domain/pickers";

/** 26px property chip (DESIGN.md §4 v0.2), usable as a Radix trigger. */
function Chip({ children, className, ...rest }: { children: ReactNode } & ComponentProps<"button">) {
  return (
    <button
      type="button"
      className={cx("inline-flex h-[26px] items-center gap-[7px] whitespace-nowrap rounded-sm border border-border-strong px-[9px] text-12 text-fg-2 hover:bg-hover", className)}
      {...rest}
    >
      {children}
    </button>
  );
}

export function Composer() {
  const router = useRouter();
  const params = useSearchParams();
  const boot = useBootstrap();
  const create = useCreateTicket();

  const projects = boot.data?.projects.filter(p => !p.archived) ?? [];
  const [projectKey, setProjectKey] = useState<string | null>(params.get("project"));
  const project = projectKey ? projects.find((p) => p.key === projectKey) : projects[0];
  const [title, setTitle] = useState(params.get("title") ?? "");
  const [description, setDescription] = useState("");
  const [criteria, setCriteria] = useState<string[]>([]);
  const [status, setStatus] = useState<TicketStatus>((params.get("status") as TicketStatus) ?? "todo");
  const [priority, setPriority] = useState<Priority>("none");
  const [agentId, setAgentId] = useState<string | null>(null);
  const [reviewerId, setReviewerId] = useState<string | null>(null);
  const [epicId, setEpicId] = useState<string | null>(null);
  const [labelIds, setLabelIds] = useState<string[]>([]);
  const [estimate, setEstimate] = useState("");
  const [due, setDue] = useState("");
  const [createMore, setCreateMore] = useState(false);
  const [requiresMockup, setRequiresMockup] = useState(false);

  const close = () => router.push(`/tickets${project ? `?project=${project.key}` : ""}`);
  const agent = boot.data?.agents.find((a) => a.id === agentId);
  const reviewer = boot.data?.users.find((u) => u.id === reviewerId);
  const epics = boot.data?.epics.filter((e) => e.project_id === project?.id) ?? [];
  const epic = epics.find((e) => e.id === epicId);
  const labels = boot.data?.labels.filter((l) => labelIds.includes(l.id)) ?? [];

  function submit() {
    if (!project || !title.trim() || create.isPending) return;
    create.mutate(
      {
        project_key: project.key,
        title,
        description_md: description,
        status,
        priority,
        assignee_agent_id: agentId ?? undefined,
        reviewer_user_id: reviewerId ?? undefined,
        epic_id: epicId ?? undefined,
        label_ids: labelIds,
        estimate: estimate || undefined,
        due_date: due || undefined,
        criteria: criteria.filter((c) => c.trim()),
        requires_mockup: requiresMockup || undefined,
      },
      {
        onSuccess: (t) => {
          if (createMore) {
            setTitle("");
            setDescription("");
            setCriteria([]);
          } else {
            router.push(`/tickets/${t.key}`);
          }
        },
      },
    );
  }

  return (
    <Dialog.Root open onOpenChange={(o) => !o && close()}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              submit();
            }
          }}
          className="motion-dialog fixed left-1/2 top-[8vh] z-50 flex max-h-[84vh] w-[min(720px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-center gap-2 px-[18px] pt-3.5">
            <DropdownMenu.Root>
              <DropdownMenu.Trigger asChild>
                <Chip aria-label="Space">
                  {project && <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: project.color }} />}
                  {project?.name ?? "Space"}
                  <Icon name="chev" size={12} className="text-fg-tertiary" />
                </Chip>
              </DropdownMenu.Trigger>
              <DropdownMenu.Portal>
                <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "z-[60] w-56")}>
                  {projects.map((p) => (
                    <DropdownMenu.Item
                      key={p.id}
                      onSelect={() => {
                        setProjectKey(p.key);
                        setEpicId(null);
                      }}
                      className="flex h-8 items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover"
                    >
                      <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: p.color }} />
                      {p.name}
                    </DropdownMenu.Item>
                  ))}
                </DropdownMenu.Content>
              </DropdownMenu.Portal>
            </DropdownMenu.Root>
            <Icon name="chevr" size={12} className="text-fg-tertiary" />
            <Dialog.Title className="text-13 font-normal text-fg-secondary">New ticket</Dialog.Title>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close" className="ml-auto" />
            </Dialog.Close>
          </div>

          <div className="flex flex-col gap-4 overflow-y-auto px-[18px] pb-4 pt-3">
            {boot.data && !project && <div className="space-y-2 text-14 text-fg-secondary"><p>Choose a space that tracks work before creating a ticket.</p><ButtonLink href={workSettingsHref()} variant="outline">New space</ButtonLink></div>}
            <label htmlFor="nt-title" className="sr-only">
              Title
            </label>
            <input
              id="nt-title"
              autoFocus
              value={title}
              maxLength={300}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Ticket title"
              className="bg-transparent text-20 font-semibold tracking-[-0.015em] text-fg outline-none placeholder:text-fg-tertiary"
            />
            <label htmlFor="nt-desc" className="sr-only">
              Description
            </label>
            <textarea
              id="nt-desc"
              rows={4}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Add a description. Agents read this first, so say what done looks like and what's out of scope. Markdown works."
              className="resize-y bg-transparent type-reading text-fg-2 outline-none placeholder:text-fg-tertiary"
            />

            <section className="flex flex-col gap-1.5">
              <div className="flex items-baseline justify-between gap-3">
                <h2 className="text-13 font-semibold">Acceptance criteria</h2>
                <span className="text-12 text-fg-tertiary">Agents tick these off as they verify them</span>
              </div>
              {criteria.map((c, i) => (
                <div key={i} className="flex items-center gap-3">
                  <span aria-hidden className="size-3.5 flex-none rounded-[3px] border border-border-strong bg-selected" />
                  <label htmlFor={`nt-crit-${i}`} className="sr-only">
                    Criterion {i + 1}
                  </label>
                  <input
                    id={`nt-crit-${i}`}
                    value={c}
                    autoFocus={i === criteria.length - 1 && c === ""}
                    onChange={(e) => setCriteria(criteria.map((x, j) => (j === i ? e.target.value : x)))}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) {
                        e.preventDefault();
                        setCriteria([...criteria, ""]);
                      }
                    }}
                    className="h-8 flex-1 bg-transparent text-14 text-fg outline-none"
                  />
                  <IconButton icon="x" label={`Remove criterion ${i + 1}`} size={24} onClick={() => setCriteria(criteria.filter((_, j) => j !== i))} />
                </div>
              ))}
              <Button variant="ghost" icon="plus" onClick={() => setCriteria([...criteria, ""])} className="w-fit px-2 text-13 text-fg-secondary">
                Add criterion
              </Button>
            </section>

            {boot.data && (
              <div className="flex flex-wrap gap-1.5">
                <StatusMenu value={status} onChange={setStatus}>
                  <Chip>
                    <StatusGlyph state={status} size={12} surface="var(--surface-raised)" label={false} />
                    {STATUS_NAME[status]}
                  </Chip>
                </StatusMenu>
                <PriorityMenu value={priority} onChange={setPriority}>
                  <Chip>
                    <PriorityGlyph priority={priority} label={false} />
                    {PRIORITY_NAME[priority]}
                  </Chip>
                </PriorityMenu>
                <EpicMenu epics={epics} value={epicId} onChange={setEpicId}>
                  <Chip>
                    <Icon name="epics" size={13} className="text-fg-tertiary" />
                    {epic?.name ?? <span className="text-fg-tertiary">Epic</span>}
                  </Chip>
                </EpicMenu>
                <AgentPicker agents={boot.data.agents.filter((a) => a.kind === "main")} value={agentId} onChange={setAgentId}>
                  <Chip>
                    {agent ? <WorkPersonaAvatar agent={agent} size="sm" /> : <Icon name="agents" size={13} className="text-fg-tertiary" />}
                    {agent?.name ?? <span className="text-fg-tertiary">Persona</span>}
                  </Chip>
                </AgentPicker>
                <UserMenu users={boot.data.users} value={reviewerId} onChange={setReviewerId}>
                  <Chip>
                    {reviewer ? <HumanAvatar name={reviewer.name} initials={reviewer.initials} color={reviewer.avatar_color} src={reviewer.avatar_url} size={16} label={false} /> : <Icon name="users" size={13} className="text-fg-tertiary" />}
                    {reviewer?.name ?? <span className="text-fg-tertiary">Reviewer</span>}
                  </Chip>
                </UserMenu>
                <LabelPicker labels={boot.data.labels} value={labelIds} onChange={setLabelIds}>
                  <Chip>
                    {labels.length ? (
                      labels.map((l) => (
                        <span key={l.id} className="inline-flex items-center gap-1.5">
                          <span aria-hidden className="size-1.5 rounded-full" style={{ background: l.color }} />
                          {l.name}
                        </span>
                      ))
                    ) : (
                      <span className="text-fg-tertiary">Labels</span>
                    )}
                  </Chip>
                </LabelPicker>
                <label className="inline-flex h-[26px] items-center gap-[7px] rounded-sm border border-border-strong px-[9px] text-12 focus-within:border-accent">
                  <span className="font-mono text-fg-tertiary">M</span>
                  <span className="sr-only">Estimate</span>
                  <input value={estimate} onChange={(e) => setEstimate(e.target.value)} placeholder="estimate" className="w-24 bg-transparent text-fg-2 outline-none placeholder:text-fg-tertiary" />
                </label>
                <label className="inline-flex h-[26px] items-center gap-[7px] rounded-sm border border-border-strong px-[9px] text-12 text-fg-2 focus-within:border-accent">
                  <Icon name="clock" size={13} className="text-fg-tertiary" />
                  <span className={due ? "" : "text-fg-tertiary"}>{due ? `Due ${dueDate(due)}` : "Due"}</span>
                  <input type="date" aria-label="Due date" value={due} onChange={(e) => setDue(e.target.value)} className="w-[18px] bg-transparent text-transparent outline-none [color-scheme:inherit]" />
                </label>
              </div>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-3 border-t border-track bg-surface-sunken px-[18px] py-3">
            {epic?.requires_mockup ? (
              <span className="text-12 text-fg-secondary">Mockup required by epic {epic.name}</span>
            ) : (
              <label className="inline-flex items-center gap-2 text-13 text-fg-secondary">
                <input type="checkbox" checked={requiresMockup} onChange={(e) => setRequiresMockup(e.target.checked)} className="size-3.5 accent-[var(--accent)]" />
                Requires mockup
              </label>
            )}
            <Toggle checked={createMore} onChange={setCreateMore} label="Create more" />
            <span className="flex min-w-[200px] flex-1 items-center gap-1.5 text-12 text-fg-tertiary">
              <Icon name="lock" size={12} />
              {agent ? `Assigning doesn't start ${agent.name}. You dispatch when it's ready.` : "Assigning an agent queues the ticket; a person dispatches it."}
            </span>
            {create.isError && (
              <span role="alert" className="w-full text-12 text-pill-blocked-fg">
                {create.error.message}
              </span>
            )}
            <Button variant="primary" onClick={submit} disabled={!title.trim() || !project || create.isPending} hint="⌘↵" className="ml-auto">
              {create.isPending ? "Creating…" : "Create ticket"}
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
