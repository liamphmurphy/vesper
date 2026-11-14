"use client";

import { useNewDeck } from "@/components/domain/use-new-deck";
import { HistoryNav } from "@/components/shell/history-nav";
import { ResearchToggle, TemporaryToggle } from "./reply-tools";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { useBootstrap, useChat, useChatModels, useChatSuggestions, useChats, useCreateChat, useInbox, usePersonaDock, useStartChat } from "@/lib/api/hooks";
import { useWorkflows } from "@/lib/api/workflow-hooks";
import { RepositoryPicker } from "./repository-picker";
import { composerOptions } from "@/lib/composer-options";
import { useRepositories } from "@/lib/api/repository-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { newestChat } from "@/lib/chat-ui";
import { toneLabel } from "@/lib/persona-ui";
import { unavailableReason } from "@/lib/setup";
import { carouselOrder, carouselWindow, FALLBACK_STARTERS, newChatSelection, personaTagline, pickUpCards, type PickUpTone } from "@/lib/welcome";
import { timelineTime } from "@/lib/format";
import { cx } from "@/lib/cx";
import Link from "next/link";
import { parseAttach, toContextRefs, type Chip } from "@/lib/chat-context";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { NoHarnessNote, useHarnessHealth } from "@/components/domain/setup";
import { ChatActivity, Conversation } from "./conversation";
import { DropOverlay, useAttachments, useFileDrop } from "./attachments";
import { useSnippets } from "./snippets";
import { Composer, type CommandRun, type ComposerCommands } from "./composer";
import { ModelEffortPicker, effortLabel, modelEffortSummary, modelEfforts, type Effort, type Selection } from "./model-picker";
import { useNewConversation } from "./chat-history";
import { CanvasButton } from "@/components/domain/canvas-view";
import { ChatPanelHost } from "./chat-panel-host";
import { useClaimCompanion } from "@/components/shell/companion";
import { useCompact } from "@/lib/viewport";
import { DOC_DRAFT, designRequest, type CreateKind } from "@/lib/chat-commands";
import { PlaygroundButton } from "@/components/domain/playground";
import { PersonaCarousel, personaLook } from "./persona";
import { CommitEmailPicker } from "./commit-email";
import { needsCommitEmailPick } from "@/lib/commit-email";
import { wizardMode } from "@/lib/onboarding";
import { WelcomeWizard } from "./welcome-wizard";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** The welcome's conversation starters: the personalised ones from /chat-suggestions, else a few general ones. Picking one fills the box. */
function Starters({ onPick, disabled, color }: { onPick: (prompt: string) => void; disabled: boolean; color: string }) {
  const written = useChatSuggestions().data?.suggestions ?? [];
  const starters = written.length ? written.slice(0, 3).map((s) => ({ title: s.title, prompt: s.prompt })) : FALLBACK_STARTERS.map((t) => ({ title: t, prompt: t }));
  return (
    <ul aria-label="Suggestions" className="flex flex-wrap justify-center gap-2.5">
      {starters.map((s) => (
        <li key={s.title}>
          <button
            type="button"
            disabled={disabled}
            title={s.prompt}
            onClick={() => onPick(s.prompt)}
            className="inline-flex h-8 items-center gap-2 rounded-full border border-border bg-surface px-3.5 text-13 text-fg-2 hover:bg-hover hover:text-fg disabled:opacity-50"
          >
            <svg aria-hidden width="11" height="11" viewBox="0 0 12 12" style={{ color }} className="flex-none">
              <path d="M6 .5c.4 2.9 1.2 3.7 4.1 4.1-2.9.4-3.7 1.2-4.1 4.1C5.6 5.8 4.8 5 1.9 4.6 4.8 4.2 5.6 3.4 6 .5Z" fill="currentColor" />
            </svg>
            {s.title}
          </button>
        </li>
      ))}
    </ul>
  );
}

const PICK_UP_PILL: Record<PickUpTone, string> = {
  human: "bg-pill-human-bg text-pill-human-fg",
  persona: "",
  neutral: "bg-pill-neutral-bg text-pill-neutral-fg",
};

/** "Pick up where you left off": what needs you, unread replies, then your latest chats. Nothing until there's something. */
function PickUp() {
  const inbox = useInbox();
  const dock = usePersonaDock();
  const chats = useChats(false, "all");
  const cards = pickUpCards(inbox.data ?? [], dock.data?.personas ?? [], chats.data?.chats ?? [], (iso) => timelineTime(iso));
  if (!cards.length) return null;
  return (
    <section aria-label="Pick up where you left off" className="flex w-full flex-col gap-3">
      <h2 className="text-12 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">Pick up where you left off</h2>
      <ul className="grid grid-cols-3 gap-3 max-md:grid-cols-1">
        {cards.map((c) => (
          <li key={c.key} className="min-w-0">
            <Link href={c.href} className="flex h-full flex-col items-start gap-2 rounded-xl border border-border bg-surface p-3.5 text-left hover:border-border-hover hover:bg-hover">
              <span
                className={cx("rounded-full px-2.5 py-0.5 text-12 font-semibold", PICK_UP_PILL[c.tone])}
                style={c.tone === "persona" && c.color ? { color: c.color, background: `color-mix(in srgb, ${c.color} 15%, transparent)` } : undefined}
              >
                {c.label}
              </span>
              <span className="line-clamp-2 text-14 font-medium text-fg">{c.title}</span>
              <span className="truncate text-12 text-fg-tertiary">{c.meta}</span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** A first conversation (the persona-led welcome): pick who to talk to, write, or pick up where you left off. */
function Welcome({ disabled, onNew, arrived }: { disabled: boolean; onNew: () => void; arrived?: boolean }) {
  const router = useRouter();
  const search = useSearchParams();
  const boot = useBootstrap();
  const start = useStartChat();
  const create = useCreateChat();
  const models = useChatModels();
  const workflows = useWorkflows();
  const personas = usePersonas();
  // Undefined until picked: the chat gets the persona the link named (the landing page's most used), else the default.
  const [picked, setPicked] = useState<string>();
  const linked = search.get("persona");
  const linkedKnown = personas.data?.personas.some((p) => p.id === linked) ? linked! : undefined;
  const defaultId = personas.data?.default_persona_id;
  const personaId = picked ?? linkedKnown ?? defaultId;
  const fullPersona = personas.data?.personas.find((p) => p.id === personaId);
  const persona = personaLook(fullPersona);
  const ordered = carouselOrder(personas.data?.personas ?? [], defaultId);
  const around = carouselWindow(ordered, ordered.findIndex((p) => p.id === personaId));
  // A coding persona works in its first repo unless /repo picks another.
  const [repoPicked, setRepoPicked] = useState<string>();
  const repos = fullPersona?.repos ?? [];
  const repo = fullPersona?.capabilities.code ? (repoPicked ?? repos[0]) : undefined;
  const [repoSignal, setRepoSignal] = useState(0);
  const savedRepos = useRepositories(!!fullPersona?.capabilities.code);
  // With several addresses, a coding chat's first message waits for which one its commits use.
  const emails = boot.data?.me.emails ?? [];
  const [commitEmail, setCommitEmail] = useState<string>();
  const askCommitEmail = needsCommitEmailPick(emails, repo, commitEmail);
  const [text, setText] = useState("");
  const [research, setResearch] = useState(false);
  const [temporary, setTemporary] = useState(false);
  // A "Start chat" link with no chat yet (?attach=…) lands here; its chips go with the first message.
  const [chips, setChips] = useState<Chip[]>(() => parseAttach(search.getAll("attach"), search.get("attach_title")));
  const files = useAttachments();
  const snippets = useSnippets();
  const area = useRef<HTMLTextAreaElement>(null);
  const name = boot.data?.me.name?.split(" ")[0];
  const locked = disabled || start.isPending || create.isPending;
  const drop = useFileDrop(files.add, !locked);

  // The model and effort, as in a chat. A new chat routes its model automatically until the person
  // picks one (null is Auto); the guess only says which harness and efforts Auto starts from.
  const groups = models.data;
  const [pickedModel, setPickedModel] = useState<Selection | null>(null);
  const [pickedEffort, setPickedEffort] = useState<Effort | null>(null);
  const guess = newChatSelection(groups, boot.data?.agents ?? []);
  const selection = pickedModel ?? (guess && { ...guess, auto: true });
  const pickModel = (s: Selection) => setPickedModel(s.auto ? null : s);
  const offered = selection ? modelEfforts(groups, selection) : { efforts: [] };
  const effort = pickedEffort && offered.efforts.includes(pickedEffort) ? pickedEffort : undefined;
  const unavailable = selection && groups?.find((g) => g.harness === selection.harness && !g.available);
  const published = (workflows.data?.workflows ?? []).filter((w) => w.published_version > 0);

  const newChat = () => ({
    persona_id: personaId,
    ...(temporary ? { temporary } : {}),
    ...(repo ? { repo_url: repo, ...(commitEmail ? { commit_email: commitEmail } : {}) } : {}),
  });
  function submit(body: string) {
    if (!body.trim() || locked || unavailable || files.pending || askCommitEmail) return;
    const context_refs = toContextRefs(chips);
    start.mutate(
      {
        ...newChat(),
        message: {
          body,
          ...(research ? { research: true } : {}),
          ...(pickedModel ? { harness: pickedModel.harness, model: pickedModel.model } : { model: "auto" }),
          ...(effort ? { effort } : {}),
          ...(context_refs ? { context_refs } : {}),
          ...(files.ids.length ? { attachment_ids: files.ids } : {}),
        },
      },
      { onSuccess: (c) => router.push(`/chat/${c.id}`) },
    );
  }
  const commands: ComposerCommands = {
    plain: {
      new: onNew,
      memory: () => router.push("/customization"),
      stop: () => "There’s no reply to stop.",
    },
    options: (command): { name: string; run: CommandRun }[] => {
      switch (command) {
        case "workflow":
          // A workflow runs in a chat: make it, then show the start card there.
          return published.map((w) => ({
            name: w.name,
            run: () => {
              if (locked) return "Wait for the current message to finish sending.";
              create.mutate(newChat(), { onSuccess: (c) => router.push(`/chat/${c.id}?workflow=${encodeURIComponent(w.id)}`) });
            },
          }));
        case "model":
          return [
            { name: "Auto", run: () => setPickedModel(null) },
            ...(groups ?? [])
              .filter((g) => g.available)
              .flatMap((g) => g.models.map((m) => ({ name: `${g.label} ${m.label}`, run: () => setPickedModel({ harness: g.harness, model: m.id }) }))),
          ];
        case "effort":
          return [undefined, ...offered.efforts].map((e) => ({ name: effortLabel(e).toLowerCase(), run: () => setPickedEffort(e ?? null) }));
        case "persona":
          return (personas.data?.personas ?? []).map((p) => ({ name: p.name, run: () => (p.id === personaId ? `You’re already talking to ${p.name}.` : setPicked(p.id)) }));
        case "repo":
          return fullPersona?.capabilities.code
            ? (savedRepos.data ?? []).map((r) => ({ name: r.name, run: () => setRepoPicked(r.url) }))
            : [];
        default:
          return [];
      }
    },
    repository: (arg) => { if (!fullPersona?.capabilities.code) return "This persona cannot write code."; if (arg) setRepoPicked(arg); else setRepoSignal((n) => n + 1); },
    hasWorkflows: published.length > 0,
    // The persona starts it with design_create once the chat exists.
    free: { design: (brief) => submit(designRequest(brief)) },
  };
  const { start: startDeck } = useNewDeck();
  // The + menu's "Create with {persona}", as in a conversation.
  const createWith = (kind: CreateKind) => {
    if (kind === "slides") return startDeck();
    setText((t) => (kind === "design" ? `/design ${t.trim()}` : `${DOC_DRAFT}${t.trim()}`));
    requestAnimationFrame(() => {
      const el = area.current;
      el?.focus();
      el?.setSelectionRange(el.value.length, el.value.length);
    });
  };
  const actionError = start.error ?? create.error;
  return (
    <div className="relative flex min-h-0 flex-1 flex-col overflow-y-auto" {...drop.props}>
      <DropOverlay over={drop.over} />
      {/* No chat header yet, but back and forward still lead the page, where the header's would be. */}
      <div className="flex h-[44px] flex-none items-center pl-3">
        <HistoryNav />
      </div>
      <div className="mx-auto flex w-full max-w-[768px] flex-1 flex-col items-center justify-center px-6 py-10">
        {/* Fresh from the Welcome Wizard, the new persona slides into the centre and the Assistant moves aside. */}
        <PersonaCarousel ordered={ordered} current={persona} left={around.left} right={around.right} onPick={setPicked} disabled={locked} enterFrom={arrived ? 1 : 0} />
        {/* Keyed so the name and tagline fade over as the carousel steps. */}
        <div key={personaId ?? ""} className="motion-page flex flex-col items-center">
          <h1 className="mt-5 text-26 font-semibold leading-tight tracking-[-0.02em] text-fg">{persona.name}</h1>
          <p className="mt-2 text-center text-14 text-fg-secondary">{personaTagline(fullPersona, toneLabel, !!fullPersona && fullPersona.id === defaultId)}</p>
        </div>
        <div className="mt-7 flex w-full flex-col gap-2">
          {actionError && (
            <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(actionError)}</p>
          )}
          {unavailable && (
            <Banner
              tone="human"
              title={unavailable.checking ? `Checking ${unavailable.label} models…` : `${unavailable.label} is unavailable`}
              actions={
                !unavailable.checking && <Link href="/settings#secrets" className="text-13 text-accent hover:underline">
                  Add the key →
                </Link>
              }
            >
              {unavailable.checking ? "This updates automatically when the model list is ready." : `${unavailableReason(unavailable)}. Pick another model or add the key.`}
            </Banner>
          )}
          {repo && emails.length > 1 && (
            <CommitEmailPicker emails={emails} name={boot.data?.me.name ?? ""} repo={repo} value={commitEmail} onPick={setCommitEmail} disabled={locked} required />
          )}
          <Composer
            text={text}
            onText={setText}
            inputRef={area}
            files={files}
            snippets={snippets}
            chips={chips}
            onChips={setChips}
            onSubmit={submit}
            commands={commands}
            personas={personas.data?.personas ?? []}
            inChat={(id) => id === personaId}
            create={{ persona: persona.name, onCreate: createWith }}
            rows={2}
            disabled={locked}
            placeholder={arrived ? `Message ${persona.name}…` : name ? `What’s on your mind, ${name}?` : "What’s on your mind?"}
            options={composerOptions({
              code: !!fullPersona?.capabilities.code,
              repo,
              research,
              temporary,
              model: selection ? modelEffortSummary(groups, selection, offered.efforts.length > 0, effort).text : undefined,
            })}
            controls={{
              repository: <RepositoryPicker value={repo} onPick={setRepoPicked} disabled={locked} signal={repoSignal} personaName={persona.name} personaRepos={repos} />,
              research: <ResearchToggle on={research} onChange={setResearch} disabled={locked} />,
              temporary: <TemporaryToggle on={temporary} onChange={setTemporary} disabled={locked} />,
              model: selection && (
                <ModelEffortPicker
                  groups={groups}
                  value={selection}
                  onChange={pickModel}
                  efforts={offered.efforts}
                  effort={effort}
                  onEffort={(e) => setPickedEffort(e ?? null)}
                  disabled={locked}
                />
              ),
            }}
            send={{
              label: start.isPending ? "Starting…" : research ? "Plan it" : "Send",
              disabled: locked || !!unavailable || files.pending || (!text.trim() && !snippets.items.length) || askCommitEmail,
              title: askCommitEmail ? "Pick which email commits use first" : undefined,
            }}
          />
        </div>
        <div className="mt-5">
          <Starters
            disabled={locked}
            color={persona.color}
            onPick={(prompt) => {
              setText(prompt);
              area.current?.focus();
            }}
          />
        </div>
        <div className="mt-12 w-full">
          <PickUp />
        </div>
      </div>
      <p className="pb-4 text-center text-12 text-fg-tertiary">Your memory is private to you and separate from the team wiki.</p>
    </div>
  );
}

/**
 * The Personal Assistant (replaces Chat): one conversation surface with no agent
 * picker; its history (rename, archive, restore, delete) is in the main menu's Chat mode.
 * /chat opens the newest conversation, or the first-time welcome; /chat?new (the landing
 * page, with ?persona=) always opens the welcome; "New
 * conversation" starts afresh. Memory and Personas open as right-hand panels from the main menu.
 */
export function ChatScreen({ id }: { id?: string }) {
  // The conversation is the page here, and its own dock (canvases, activity, linked items) is the
  // right-hand panel: no work chat beside it.
  useClaimCompanion();
  const router = useRouter();
  const search = useSearchParams();
  const current = useChat(id);
  const turnRunning = current.data?.state === "running";
  const health = useHarnessHealth();
  const boot = useBootstrap();
  // First run (or ?setup, from Settings): the Welcome Wizard takes the welcome's place until it hands over.
  const [arrived, setArrived] = useState<string>();
  // Compact: the panels are one sheet over the chat (chat-panel-host); the compact header's Panels button reopens it.
  const compact = useCompact();
  const mode = search.has("setup") ? "full" : wizardMode(boot.data?.me);
  const wizard = !id && !arrived && !!boot.data && !!mode;
  const noHarness = !!health && !health.ready && !wizard;
  // /chat resumes the newest conversation, unless a "Start chat" link brought context to attach
  // or the landing page asked for a new one (?new).
  const fresh = search.has("attach") || search.has("new");
  // Resume the newest conversation with any persona, whatever the sidebar shows.
  const chats = useChats(false, "all");
  const newest = newestChat(chats.data?.chats);
  useEffect(() => {
    if (id || fresh || wizard || !newest) return;
    const q = new URLSearchParams(search.toString());
    q.delete("project"); // Old links; a chat carries its own project.
    const qs = q.toString();
    router.replace(qs ? `/chat/${newest.id}?${qs}` : `/chat/${newest.id}`);
  }, [id, fresh, wizard, newest, router, search]);

  const conversation = useNewConversation(id);
  const resolving = !id && !fresh && !wizard && (!chats.data || !!newest);
  return (
    <div className="flex h-app flex-col">
      <div className="relative flex min-h-0 flex-1 max-md:flex-col">
          <div className="flex min-w-0 flex-1 flex-col">
            {noHarness && (
              <div className="flex flex-col gap-1 px-6 pt-3">
                <NoHarnessNote health={health} />
              </div>
            )}
            {id ? (
              <Conversation key={id} id={id} onNew={conversation.start} activityInDock actions={<><PlaygroundButton chatId={id} /><CanvasButton chatId={id} live={turnRunning} /></>} />
            ) : (
              <>
                {chats.isError ? (
                  <div className="p-6">
                    <Banner tone="blocked" title="Couldn’t load your conversations">{errorText(chats.error)}</Banner>
                  </div>
                ) : wizard ? (
                  <WelcomeWizard
                    only={mode === "harness" ? "harness" : undefined}
                    onDone={(persona) => {
                      // Only the harness step: back to the welcome as it was.
                      setArrived(persona ?? "harness");
                      if (persona) router.replace(`/chat?new&persona=${encodeURIComponent(persona)}`);
                    }}
                  />
                ) : resolving ? (
                  <div aria-busy="true" className="flex flex-1 flex-col gap-4 p-6">
                    <Skeleton className="h-6 w-1/3" />
                    <Skeleton className="h-16 w-2/3" />
                  </div>
                ) : (
                  // Keyed by the linked persona so New chat from the welcome starts over on the one it names.
                  <Welcome key={search.get("persona") ?? ""} disabled={noHarness} onNew={conversation.start} arrived={!!arrived && search.get("persona") === arrived} />
                )}
              </>
            )}
          </div>
          {id && <ChatPanelHost key={id} chatId={id} live={turnRunning} readOnly={!!current.data?.archived} agent={current.data?.persona?.name ?? "Assistant"} activity={<ChatActivity chatId={id} />} layout={compact ? "sheet" : "side"} />}
      </div>
    </div>
  );
}
