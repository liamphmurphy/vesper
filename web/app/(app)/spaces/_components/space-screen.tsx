"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { Dialog, DropdownMenu } from "radix-ui";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { api, unwrap } from "@/lib/api/client";
import { useChatModels } from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useDeleteSpace, useSpace, useSpaceChats, useSpaceSources, useUpdateSpace, type Space } from "@/lib/api/space-hooks";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { chatTitle } from "@/lib/chat-ui";
import { cx } from "@/lib/cx";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";
import { shortAgo } from "@/lib/format";
import { formatTokens, sortSpaceChats, SOURCE_KIND_LABEL, sourceName, SPACE_PAGE_CHATS, spaceSubtitle, spaceUses, type ChatSort, type SourceKind, type SpaceColor } from "@/lib/spaces";
import { ticketsHref } from "@/lib/tickets-layout";
import { repoShortName } from "@/lib/persona-ui";
import { buildSpaceInspectorSections } from "@/lib/native-shell/models/space-inspector";
import { CompanionDock } from "@/components/shell/companion";
import { floatPanel } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { NoHarnessNote, useHarnessHealth } from "@/components/domain/setup";
import { AttachmentChips, DropOverlay, useAttachments, useFileDrop } from "@/app/(app)/chat/_components/attachments";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { modelLabel, type Selection } from "@/app/(app)/chat/_components/model-picker";
import { ResearchToggle } from "@/app/(app)/chat/_components/reply-tools";
import { ColorPicker, ConnectorSelect, SpaceTile, useConnectorNames, useProjectName } from "./space-parts";
import { SourcesDialog } from "./sources-dialog";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
const ACCEPT = ".pdf,.png,.jpg,.jpeg,.gif,.webp,.txt,.md,.markdown,.csv,.json";
const menuItem = "flex h-[32px] cursor-default select-none items-center gap-[10px] rounded-md px-[8px] text-13 outline-none data-[highlighted]:bg-hover";

/** The space's own views: its chats here; its tickets, epics and runs (when it tracks work) where they always are, filtered to it. */
function SpaceTabs({ space }: { space: Space }) {
  const w = space.work;
  if (!w) return null;
  const tab = "flex h-[32px] items-center border-b-2 px-[2px] text-13";
  const links = [
    { label: "Tickets", href: ticketsHref("list", { project: w.key }) },
    { label: "Epics", href: ticketsHref("epics", { project: w.key }) },
    { label: "Runs", href: `/runs?project=${encodeURIComponent(w.key)}` },
  ];
  return (
    <nav aria-label={`${space.name} views`} className="mt-[20px] flex gap-[24px] border-b border-border-subtle">
      <span aria-current="page" className={cx(tab, "border-accent font-medium text-fg")}>
        Chats <span className="ml-[6px] text-fg-tertiary">{space.chat_count}</span>
      </span>
      {links.map((l) => (
        <Link key={l.label} href={l.href} className={cx(tab, "border-transparent text-fg-secondary hover:text-fg")}>
          {l.label}
        </Link>
      ))}
    </nav>
  );
}

/** The persona chip in the space's composer: the space default until another is picked. */
function PersonaChip({ value, onChange, disabled }: { value?: string; onChange: (id: string) => void; disabled?: boolean }) {
  const q = usePersonas();
  const personas = q.data?.personas ?? [];
  const current = personaLook(personas.find((p) => p.id === value));
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled || personas.length === 0}
          aria-label={`Persona for the new chat: ${current.name}`}
          className="flex h-[26px] items-center gap-[6px] rounded-full border border-border-strong pl-[4px] pr-[10px] text-12 text-fg hover:bg-hover disabled:opacity-60"
        >
          <PersonaAvatar persona={current} size={16} />
          <span className="truncate">{current.name}</span>
          <Icon name="chev" size={11} className="text-fg-secondary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "w-[220px]")}>
          <DropdownMenu.RadioGroup value={value ?? ""} onValueChange={onChange}>
            {personas.map((p) => (
              <DropdownMenu.RadioItem key={p.id} value={p.id} className={menuItem}>
                <PersonaAvatar persona={p} size={18} />
                <span className="flex-1 truncate">{p.name}</span>
                <span className="w-[14px] text-accent">{p.id === value && <Icon name="check" size={14} />}</span>
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** The model chip: the assistant's own model until another is picked. */
function ModelChip({ value, onChange, disabled }: { value?: Selection; onChange: (s: Selection) => void; disabled?: boolean }) {
  const models = useChatModels();
  const groups = models.data ?? [];
  const label = value ? modelLabel(groups, value).model : "Default model";
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={`Model for the new chat: ${label}`}
          className="flex h-[26px] items-center gap-[6px] rounded-full border border-border-strong px-[10px] text-12 text-fg-secondary hover:bg-hover disabled:opacity-60"
        >
          {label}
          <Icon name="chev" size={11} />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "max-h-[320px] w-[240px] overflow-y-auto")}>
          {groups.map((g, i) => (
            <DropdownMenu.Group key={g.harness}>
              {i > 0 && <DropdownMenu.Separator className="my-[4px] h-px bg-border-subtle" />}
              <DropdownMenu.Label className="px-[8px] py-[4px] text-12 font-medium text-fg-tertiary">{g.label}</DropdownMenu.Label>
              {g.models.map((m) => (
                <DropdownMenu.Item key={m.id} disabled={!g.available} className={menuItem} onSelect={() => onChange({ harness: g.harness, model: m.id })}>
                  <span className="flex-1">{m.label}</span>
                  <span className="w-[14px] text-accent">{value?.harness === g.harness && value.model === m.id && <Icon name="check" size={14} />}</span>
                </DropdownMenu.Item>
              ))}
            </DropdownMenu.Group>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** "New chat in Health": starts a chat in the space and sends its first message. */
function Composer({ space, disabled }: { space: Space; disabled: boolean }) {
  const router = useRouter();
  const qc = useQueryClient();
  const personas = usePersonas();
  const [text, setText] = useState("");
  const [persona, setPersona] = useState<string>();
  const [model, setModel] = useState<Selection>();
  // On for the first message: the persona proposes a research plan, and its
  // report joins this space's sources.
  const [research, setResearch] = useState(false);
  const files = useAttachments();
  const picker = useRef<HTMLInputElement>(null);
  const start = useMutation({
    mutationFn: async (body: string) => {
      const chat = await unwrap(
        api.POST("/chats", { body: { space_id: space.id, ...(persona ? { persona_id: persona } : {}), ...(model ? { harness: model.harness, model: model.model } : {}) } }),
      );
      await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id: chat.id } }, body: { body, ...(research ? { research: true } : {}), ...(files.ids.length ? { attachment_ids: files.ids } : {}) } }));
      return chat;
    },
    onSettled: () => void Promise.all([qc.invalidateQueries({ queryKey: ["chats"] }), qc.invalidateQueries({ queryKey: ["spaces"] })]),
  });
  const locked = disabled || start.isPending;
  const drop = useFileDrop(files.add, !locked);
  const shown = persona ?? space.persona_id ?? personas.data?.default_persona_id;
  function submit(e?: FormEvent) {
    e?.preventDefault();
    const body = text.trim();
    if (!body || locked || files.pending) return;
    start.mutate(body, { onSuccess: (c) => router.push(`/chat/${c.id}`) });
  }
  return (
    <div className="flex flex-col gap-[10px]">
      <form onSubmit={submit} onPaste={files.onPaste} {...drop.props} className="relative flex flex-col gap-[12px] rounded-[14px] border border-border-strong bg-surface px-[20px] pb-[10px] pt-[16px] focus-within:border-accent">
        <DropOverlay over={drop.over} />
        <AttachmentChips attachments={files} />
        <textarea
          aria-label={`New chat in ${space.name}`}
          rows={1}
          value={text}
          disabled={locked}
          placeholder={research ? `What should ${space.name} research?` : `New chat in ${space.name}`}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              submit();
            }
          }}
          className="max-h-[192px] min-h-[24px] resize-none bg-transparent text-15 text-fg placeholder:text-fg-tertiary focus:outline-none [field-sizing:content]"
        />
        <div className="flex items-center gap-[8px]">
          <input
            ref={picker}
            type="file"
            multiple
            hidden
            accept={ACCEPT}
            onChange={(e) => {
              files.add([...(e.target.files ?? [])]);
              e.target.value = "";
            }}
          />
          <button type="button" aria-label="Attach files" title="Attach files" disabled={locked} onClick={() => picker.current?.click()} className="grid size-[28px] place-items-center rounded-full text-fg-secondary hover:bg-hover hover:text-fg disabled:opacity-50">
            <Icon name="plus" size={16} strokeWidth={1.8} />
          </button>
          <PersonaChip value={shown} onChange={setPersona} disabled={locked} />
          <ModelChip value={model} onChange={setModel} disabled={locked} />
          <ResearchToggle on={research} onChange={setResearch} disabled={locked} />
          <span className="flex-1" />
          <button
            type="submit"
            aria-label={research ? "Plan research" : "Start chat"}
            disabled={locked || files.pending || !text.trim()}
            className="grid size-[28px] place-items-center rounded-full bg-accent text-on-accent hover:brightness-110 disabled:opacity-60"
          >
            <svg aria-hidden viewBox="0 0 16 16" width={14} height={14} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
              <path d="M8 13V3M4 7l4-4 4 4" />
            </svg>
          </button>
        </div>
      </form>
      {start.isError ? (
        <p role="alert" className="px-[4px] text-12 text-pill-blocked-fg">{errorText(start.error)}</p>
      ) : (
        <p className="px-[4px] text-12 text-fg-tertiary">{research ? `The persona proposes a research plan to approve; its report joins ${space.name}’s sources.` : spaceUses(space)}</p>
      )}
    </div>
  );
}

function ChatList({ space }: { space: Space }) {
  const chats = useSpaceChats(space.id);
  const [sort, setSort] = useState<ChatSort>("newest");
  const [all, setAll] = useState(false);
  const list = sortSpaceChats(chats.data?.chats ?? [], sort);
  const shown = all ? list : list.slice(0, SPACE_PAGE_CHATS);
  const more = list.length - shown.length;
  return (
    <section aria-label="Chats" className="flex flex-col">
      <div className="flex items-center justify-between border-b border-border-subtle pb-[12px]">
        <h2 className="text-14 font-semibold text-fg">Chats</h2>
        <DropdownMenu.Root>
          <DropdownMenu.Trigger asChild>
            <button type="button" aria-label={`Sort chats: ${sort}`} className="flex items-center gap-[4px] text-12 text-fg-secondary hover:text-fg">
              {sort === "newest" ? "Newest" : "Oldest"}
              <Icon name="chev" size={11} />
            </button>
          </DropdownMenu.Trigger>
          <DropdownMenu.Portal>
            <DropdownMenu.Content align="end" sideOffset={6} className={cx(floatPanel, "w-[160px]")}>
              <DropdownMenu.RadioGroup value={sort} onValueChange={(v) => setSort(v as ChatSort)}>
                {(["newest", "oldest"] as const).map((v) => (
                  <DropdownMenu.RadioItem key={v} value={v} className={menuItem}>
                    <span className="flex-1">{v === "newest" ? "Newest" : "Oldest"}</span>
                    <span className="w-[14px] text-accent">{sort === v && <Icon name="check" size={14} />}</span>
                  </DropdownMenu.RadioItem>
                ))}
              </DropdownMenu.RadioGroup>
            </DropdownMenu.Content>
          </DropdownMenu.Portal>
        </DropdownMenu.Root>
      </div>
      {chats.isError ? (
        <div className="pt-[12px]">
          <Banner tone="blocked" title="Couldn’t load the chats">{errorText(chats.error)}</Banner>
        </div>
      ) : !chats.data ? (
        <div aria-busy="true" className="flex flex-col gap-[12px] pt-[16px]">
          <Skeleton className="h-[40px]" />
          <Skeleton className="h-[40px]" />
        </div>
      ) : list.length === 0 ? (
        <p className="py-[24px] text-13 text-fg-secondary">No chats in {space.name} yet. Start one above.</p>
      ) : (
        <ul>
          {shown.map((c) => (
            <li key={c.id} className="border-b border-border-row">
              <Link href={`/chat/${c.id}`} className="-mx-[8px] flex items-center gap-[12px] rounded-md px-[8px] py-[10px] hover:bg-hover">
                <span className="flex min-w-[0px] flex-1 flex-col gap-[4px]">
                  <span className="flex items-center gap-[8px] truncate text-14 text-fg">
                    {c.state === "running" && <span aria-hidden className="size-[6px] flex-none rounded-full bg-state-done" />}
                    <span className="truncate">{chatTitle(c)}</span>
                  </span>
                  <span className="truncate text-12 text-fg-tertiary">{c.preview ?? "No replies yet"}</span>
                </span>
                <time dateTime={c.last_message_at ?? c.created_at} className="flex-none text-11 text-fg-tertiary">
                  {shortAgo(c.last_message_at ?? c.created_at)}
                </time>
                <PersonaAvatar persona={personaLook(c.persona)} size={18} />
              </Link>
            </li>
          ))}
        </ul>
      )}
      {more > 0 && (
        <button type="button" className="mt-[16px] self-start text-13 text-accent hover:underline" onClick={() => setAll(true)}>
          Show {more} more
        </button>
      )}
    </section>
  );
}

/** Settings opens the name, description, color and connectors for editing in the header. */
function HeaderEditor({ space, onDone }: { space: Space; onDone: () => void }) {
  const update = useUpdateSpace();
  const [name, setName] = useState(space.name);
  const [description, setDescription] = useState(space.description);
  const [color, setColor] = useState<SpaceColor>(space.color);
  const [connectors, setConnectors] = useState<string[]>(space.connector_ids);
  return (
    <form
      className="flex flex-1 flex-col gap-[8px]"
      onSubmit={(e) => {
        e.preventDefault();
        if (!name.trim()) return;
        update.mutate(
          { id: space.id, patch: { name: name.trim(), description: description.trim(), color, connector_ids: connectors } },
          { onSuccess: onDone },
        );
      }}
    >
      <div className="flex items-center gap-[12px]">
        <ColorPicker name={name} value={color} onChange={setColor} size={36} />
        <input aria-label="Name" autoFocus value={name} maxLength={80} onChange={(e) => setName(e.target.value)} className="h-[36px] min-w-[0px] flex-1 rounded-lg border border-border-strong bg-surface-sunken px-[12px] text-18 font-semibold text-fg focus:border-accent focus:outline-none" />
      </div>
      <input aria-label="Description" value={description} maxLength={300} placeholder="What this space is for" onChange={(e) => setDescription(e.target.value)} className="ml-[48px] h-[32px] rounded-lg border border-border-strong bg-surface-sunken px-[12px] text-13 text-fg placeholder:text-fg-tertiary focus:border-accent focus:outline-none" />
      <div className="ml-[48px] max-w-[320px]">
        <ConnectorSelect value={connectors} onChange={setConnectors} disabled={update.isPending} />
      </div>
      {update.isError && <p role="alert" className="ml-[48px] text-12 text-pill-blocked-fg">{errorText(update.error)}</p>}
      <div className="ml-[48px] flex gap-[8px]">
        <Button type="submit" variant="primary" disabled={update.isPending || !name.trim()}>{update.isPending ? "Saving…" : "Save"}</Button>
        <Button variant="outline" onClick={onDone}>Cancel</Button>
      </div>
    </form>
  );
}

function DeleteSpaceDialog({ space, open, onOpenChange }: { space: Space; open: boolean; onOpenChange: (o: boolean) => void }) {
  const router = useRouter();
  const del = useDeleteSpace();
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content className="motion-dialog fixed left-1/2 top-[18vh] z-50 flex w-[min(460px,calc(100%-32px))] -translate-x-1/2 flex-col gap-[12px] rounded-2xl border border-border-float bg-surface-raised p-[24px] shadow-[var(--shadow-float)] outline-none">
          <Dialog.Title className="type-heading">Delete {space.name}?</Dialog.Title>
          <Dialog.Description className="text-13 text-fg-secondary">
            {space.work ? (
              <>{space.name} tracks work ({space.work.key}), so it stays while it does. Stop tracking work in its Work section first, or archive the work instead.</>
            ) : (
              <>
                Its instructions, {space.source_count} {space.source_count === 1 ? "source" : "sources"} and {space.memory_count}{" "}
                {space.memory_count === 1 ? "memory" : "memories"} are deleted. Its {space.chat_count} {space.chat_count === 1 ? "chat moves" : "chats move"} to Recent.
              </>
            )}
          </Dialog.Description>
          {del.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(del.error)}</p>}
          <div className="flex justify-end gap-[8px]">
            <Dialog.Close asChild>
              <Button variant="outline">Cancel</Button>
            </Dialog.Close>
            <Button variant="primary" className="bg-state-blocked" disabled={del.isPending || !!space.work} onClick={() => del.mutateAsync(space.id).then(() => router.push("/chat"), () => undefined)}>
              Delete space
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/**
 * A space's page (LAZYAGENTS-213 frame A): its chats, and when it tracks work, tabs to its
 * tickets, epics and runs. Its instructions, sources, memory, defaults and work are the About
 * tab of the companion panel, beside the work chat.
 */
export function SpaceScreen({ id }: { id: string }) {
  const q = useSpace(id);
  const health = useHarnessHealth();
  const noHarness = !!health && !health.ready;
  const [editing, setEditing] = useState(false);
  const [sources, setSources] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const space = q.data;
  // The Mac app's toolbar carries the header's Settings and "more" menu, and the window's title is the space's name.
  useNativeActions(space && !editing ? [
    { id: "space.settings", label: "Settings", kind: "button", icon: "gear", showsLabel: true, run: () => setEditing(true) },
    { id: "space.more", label: "More for this space", kind: "menu", icon: "dots", menu: [
      { id: "space.sources", label: "Manage sources", icon: "artifacts", run: () => setSources(true) },
      { id: "space.delete", label: "Delete space…", icon: "trash", destructive: true, run: () => setDeleting(true) },
    ] },
  ] : undefined);
  const titleToken = useRef(Symbol("space-title"));
  const spaceName = space?.name;
  useEffect(() => {
    if (!spaceName) return;
    const token = titleToken.current;
    setTopBarTitle(token, { title: spaceName });
    return () => setTopBarTitle(token, null);
  }, [spaceName]);
  if (q.isError) {
    return (
      <div className="p-8">
        <Banner tone="blocked" title="Couldn’t open this space">{errorText(q.error)}</Banner>
      </div>
    );
  }
  if (!space) {
    return (
      <div aria-busy="true" className="flex flex-col gap-[16px] p-[40px]">
        <Skeleton className="h-[36px] w-1/3" />
        <Skeleton className="h-[96px] w-2/3" />
      </div>
    );
  }
  return (
    <div className="h-app overflow-y-auto">
      <div className="mx-auto flex w-full max-w-[1048px] flex-col pb-[48px] pl-[48px] pr-[40px] pt-[24px] max-md:px-[20px]">
        <header className="flex items-start gap-[12px]">
          {editing ? (
            <HeaderEditor space={space} onDone={() => setEditing(false)} />
          ) : (
            <>
              <SpaceTile name={space.name} color={space.color} size={36} className="rounded-lg" />
              <div className="flex min-w-[0px] flex-1 flex-col gap-[4px]">
                <h1 className="flex min-w-[0px] items-baseline gap-[10px] text-22 font-semibold leading-7 text-fg">
                  <span className="truncate">{space.name}</span>
                  {space.work && <span className="flex-none font-mono text-12 font-normal text-fg-tertiary">{space.work.key}</span>}
                </h1>
                <p className="truncate text-13 text-fg-tertiary">{spaceSubtitle(space)}</p>
              </div>
            </>
          )}
        </header>
        {noHarness && (
          <div className="mt-[16px]">
            <NoHarnessNote health={health} />
          </div>
        )}
        <SpaceTabs space={space} />
        <div className="mt-[24px] flex min-w-[0px] flex-col gap-[40px]">
          <Composer space={space} disabled={noHarness} />
          <ChatList space={space} />
        </div>
      </div>
      <SpaceCompanion space={space} onEdit={() => setEditing(true)} onSources={() => setSources(true)} />
      <SourcesDialog spaceId={space.id} spaceName={space.name} open={sources} onOpenChange={setSources} />
      <DeleteSpaceDialog space={space} open={deleting} onOpenChange={setDeleting} />
    </div>
  );
}

function SpaceCompanion({
  space,
  onEdit,
  onSources,
}: {
  space: Space;
  onEdit: () => void;
  onSources: () => void;
}) {
  const sources = useSpaceSources(space.id);
  const personas = usePersonas();
  const update = useUpdateSpace();
  const projectName = useProjectName(space.project ?? "");
  const connectorsSummary = useConnectorNames(space.connector_ids);
  const list = sources.data?.sources ?? [];
  const budget = sources.data?.inline_budget ?? 40000;
  const used = sources.data?.inline_tokens ?? space.inline_tokens;
  const sections = buildSpaceInspectorSections({
    id: space.id,
    instructions: space.instructions,
    sourceCount: space.source_count,
    sources: list.map((s) => ({
      id: s.id,
      name: sourceName(s),
      kindLabel: SOURCE_KIND_LABEL[s.kind as SourceKind] ?? s.kind,
    })),
    inlineUsed: used,
    inlineBudget: budget,
    inlineLabel: `${formatTokens(used)} of ${formatTokens(budget)} inline`,
    spaceMemory: space.space_memory,
    spaceName: space.name,
    memoryCount: space.memory_count,
    personaId: space.persona_id ?? "",
    personaOptions: [
      { value: "", label: "Default persona" },
      ...(personas.data?.personas ?? []).map((p) => ({ value: p.id, label: p.name })),
    ],
    projectName,
    connectorsSummary,
    work: space.work
      ? {
          key: space.work.key,
          archived: space.work.archived,
          repoName: space.work.repo_url ? repoShortName(space.work.repo_url) : undefined,
          branch: space.work.default_branch,
        }
      : undefined,
    filesUnder: projectName,
  });

  return (
    <CompanionDock
      app="space"
      tabs={[
        {
          id: "about",
          label: "About",
          icon: "sidebar",
          native: {
            kind: "native",
            sections,
            onToggle: (fieldId, checked) => {
              if (fieldId === "space_memory") update.mutate({ id: space.id, patch: { space_memory: checked } });
            },
            onChange: (fieldId, value) => {
              if (fieldId === "persona_id") update.mutate({ id: space.id, patch: { persona_id: value } });
            },
            onAction: (actionId) => {
              if (actionId === "edit_space") onEdit();
              else if (actionId === "manage_sources") onSources();
            },
          },
        },
        { id: "chat", label: "Chat", icon: "msg", native: { kind: "companion" } },
      ]}
    />
  );
}
