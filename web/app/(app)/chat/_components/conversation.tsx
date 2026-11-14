"use client";

import { useNewDeck } from "@/components/domain/use-new-deck";
import { canvasFenceIds } from "@/lib/chat-canvas";
import { DOC_DRAFT, designRequest, type CreateKind } from "@/lib/chat-commands";
import { useRouter, useSearchParams } from "next/navigation";
import { Fragment, memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { createPortal } from "react-dom";
import { useDockHeaderSlot } from "@/components/shell/editor-layout";
import { useQueryClient } from "@tanstack/react-query";
import { Tooltip } from "radix-ui";
import { useEntrances } from "@/components/ui/motion";
import { api, ApiError, unwrap, type Schemas } from "@/lib/api/client";
import {
  chatKeys,
  useBootstrap,
  useCancelChat,
  useChat,
  useChatAsides,
  useChatFollowups,
  useChatTicketRuns,
  useChatMessages,
  useEditLastChatMessage,
  useChatModels,
  useCreateChat,
  useDeleteChat,
  useQueueFollowup,
  useSendChatMessage,
  useSetChatCommitEmail,
  useStartAside,
} from "@/lib/api/hooks";
import { asidesInWindow, commandSendMode, cycleSendMode, SEND_MODE_ENTER, SEND_MODE_HINT, SEND_MODE_LABEL, sendModeAction, sendModePlaceholder, type SendMode } from "@/lib/send-mode";
import { SEND_TONE, SendModeSwitch } from "./send-modes";
import { FollowupTray } from "./followups";
import { LiveAsides, ReplyAsides } from "./asides";
import { RepositoryPicker } from "./repository-picker";
import { useRepositories, useSetChatRepository } from "@/lib/api/repository-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useChatWorkflowRuns, useWorkflows, type Workflow } from "@/lib/api/workflow-hooks";
import { runActive } from "@/lib/workflows";
import { runEnded } from "@/lib/chat-dispatch";
import { StatusSlot, type StatusItem } from "./status-slot";
import { ChatWorkflowTray, WorkflowStartCard } from "@/components/domain/workflow-cards";
import { ChatRunsPill, ChatTicketRunTray } from "@/components/domain/dispatch-cards";
import { ActivityScene } from "./activity-scene";
import { Tabs } from "@/components/ui/controls";
import { focusActivityStep, useActivityFocus } from "./activity-focus";
import { openThread, setDock } from "@/lib/chat-panels";
import { isTyping } from "@/components/shell/shortcuts";
import { HistoryNav } from "@/components/shell/history-nav";
import { linkedItems, openItem, type LinkedItem } from "@/lib/chat-panels";
import { LinkedRow, OpenLinkedItem } from "./item-panel";
import { useRecordVisit } from "@/components/shell/use-record-visit";
import { addChip, chipFromRef, chipFromTarget, parseAttach, toContextRefs, typedText, type Chip } from "@/lib/chat-context";
import { chatTitle, endedTurns, needsSwitchConfirm, runningSince, turnWindows, type EndedTurn, type TurnWindow } from "@/lib/chat-ui";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Icon, type IconName } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { ChatMarkdown } from "./chat-markdown";
import { CodeChanges } from "./code-changes";
import { SentChips } from "./context-chips";
import { MessageActionsContext, MessageToolbar, ThreadLink, type MessageActions } from "./message-toolbar";
import { Sources } from "./sources";
import { splitSourceList } from "@/lib/chat-sources";
import { AskAboutSelection, quoteForComposer, ResearchToggle, TemporaryToggle } from "./reply-tools";
import { ChatSuggestions } from "./suggestions";
import { Composer, type CommandRun } from "./composer";
import { RecommendActions, SaveSummary, VideoPlayers } from "@/components/domain/recommend-fence";
import { VideoCards, VideoRendererNotes } from "@/components/domain/video-card";
import { AudioCards } from "@/components/domain/audio-card";
import { useChatAudio } from "@/lib/api/audio-hooks";
import type { ChatAudio } from "@/lib/chat-audio";
import { useChatVideos } from "@/lib/api/video-hooks";
import type { ChatVideo } from "@/lib/chat-video";
import { CiteContext } from "@/components/domain/cite-marker";
import { summaryRequestUrl } from "@/lib/chat-recommend";
import { hostOf } from "@/lib/web-search";
import { timelineTime } from "@/lib/format";
import { ModelEffortPicker, effortLabel, modelEffortSummary, modelEfforts, modelLabel, sameSelection, type Effort, type Selection } from "./model-picker";
import { ChatPresence, ChatStatus, InterimReply, OpenTurnStep, RunActivity, TurnSteps, TurnToolCalls } from "./activity";
import { MemoryNotices } from "./memory-notices";
import { DropOverlay, ReplyAttachments, SentAttachments, useAttachments, useFileDrop } from "./attachments";
import { useSnippets } from "./snippets";
import { messageWithSnippets } from "@/lib/snippets";
import { WebSearchPill } from "./web-search";
import { RestoreChat } from "./restore";
import { HarnessSwitchDialog } from "./switch-dialog";
import { UsageTag } from "./usage-tag";
import { HeaderPersona, PersonaAvatar, PersonaGreeting, PersonaName, PersonaStack, PersonaSwitcher, personaLook, toneLabel, type PersonaLook } from "./persona";
import { PersonaProposals } from "./persona-proposals";
import { ConnectorRequests } from "./connector-requests";
import { SecretRequests } from "./secret-requests";
import { TicketChangeRequests } from "./ticket-change-requests";
import { ChatTitleMenu } from "./title-menu";
import { ChatCostChip } from "@/components/domain/cost-chip";
import { unavailableReason } from "@/lib/setup";
import { ChatProjectPicker } from "./chat-project";
import { CompactChatHeader } from "./compact-chat-header";
import { useCompact } from "@/lib/viewport";
import { composerOptions } from "@/lib/composer-options";
import { CommitEmailPicker } from "./commit-email";
import { needsCommitEmailPick } from "@/lib/commit-email";
import { onComposerDrop } from "@/lib/playground-report";
import { SpaceBreadcrumb, SpaceContextChips } from "@/app/(app)/spaces/_components/space-chat";
import Link from "next/link";
import { confirmAction } from "@/components/ui/confirm";

type Message = Schemas["ChatMessage"];
type Groups = Schemas["ChatHarnessModels"][] | undefined;

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function Tag({ groups, m }: { groups: Groups; m: Message }) {
  if (!m.harness || !m.model) return null;
  const l = modelLabel(groups, { harness: m.harness, model: m.model });
  return (
    <UsageTag m={m}>
      {l.harness} · {l.model}
      {m.effort && ` · ${effortLabel(m.effort)}${m.effort_level ? " (auto)" : ""}`}
    </UsageTag>
  );
}

// Actions that stay out of the way until the message is hovered or focused.
const LONG_REPLY = 1500;
/** What the status card's "Ask what it's doing" sends as an aside when a turn has gone quiet. */
const QUIET_CHECK_IN = "What are you working on right now, and is anything holding you up?";

/** Above the replies that arrived since the person last read the chat, as messaging apps mark them. */
function NewDivider() {
  return (
    <li className="flex items-center gap-3 text-12 font-semibold text-state-blocked" data-testid="new-divider">
      <span aria-hidden className="h-px flex-1 bg-state-blocked/50" />
      <span>New</span>
      <span aria-hidden className="h-px flex-1 bg-state-blocked/50" />
    </li>
  );
}

function Divider({ children, testId }: { children: string; testId?: string }) {
  return (
    <li className="flex items-center gap-3 py-1 text-12 text-fg-tertiary" data-testid={testId}>
      <span aria-hidden className="h-px flex-1 bg-border-subtle" />
      <span>{children}</span>
      <span aria-hidden className="h-px flex-1 bg-border-subtle" />
    </li>
  );
}

type ChatInfo = { id: string; title: string; project?: string; agent: { name: string } };

const Bubble = memo(function Bubble({ m, chat, persona, saveable, names, turn, ended, summaryUrl, editable, onEdit, onRetry, highlighted, videos, audio, asides, thread }: { m: Message; chat: ChatInfo; persona: PersonaLook; saveable: boolean; names: Map<string, string>; turn?: TurnWindow; ended?: EndedTurn; summaryUrl?: string | null; editable?: boolean; onEdit?: (body: string) => void; onRetry?: () => void; highlighted?: boolean; videos?: ChatVideo[]; audio?: ChatAudio[]; asides?: ReactNode; thread?: { count: number; running: boolean } }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(m.body_md);
  const self = useRef<HTMLLIElement>(null);
  // The closing URL list shows as Sources cards, not as text. Saved replies keep it.
  const parts = useMemo(() => (m.role === "assistant" ? splitSourceList(m.body_md) : { body: typedText(m.body_md), listed: [] }), [m.role, m.body_md]);
  const [citeFocus, setCiteFocus] = useState<{ n: number; tick: number }>();
  const cites = useMemo(() => {
    const titles = new Map<number, string>();
    for (const l of parts.listed) if (l.n !== undefined) titles.set(l.n, l.title || l.ref || hostOf(l.url));
    return { numbers: [...titles.keys()], value: { titles, focus: (n: number) => setCiteFocus((f) => ({ n, tick: (f?.tick ?? 0) + 1 })) } };
  }, [parts.listed]);
  // A turn that ended without a reply keeps its steps: under the failure, or under the unanswered message.
  const endedSteps = ended && (
    <li className="flex flex-col items-start gap-1.5" data-testid="ended-turn">
      <span className="flex items-center gap-2 text-12 text-fg-tertiary">
        <PersonaAvatar persona={persona} size={22} />
        <PersonaName persona={persona} className="text-13" />
      </span>
      <TurnSteps runId={m.run_id} outcome={ended.outcome} since={ended.since} until={ended.until} end={ended.end} />
    </li>
  );
  if (m.role === "system") {
    // A turn that failed keeps the videos it started, so what went wrong stays visible.
    return (
      <>
        {endedSteps}
        {videos?.length ? <li className="flex flex-col items-start"><VideoCards chatId={chat.id} videos={videos} messageId={m.id} /></li> : null}
        {audio?.length ? <li className="flex flex-col items-start"><AudioCards chatId={chat.id} audio={audio} messageId={m.id} /></li> : null}
        <Divider testId="system-message">{m.body_md}</Divider>
      </>
    );
  }
  const mine = m.role === "user";
  const author = m.persona ? personaLook(m.persona) : persona;
  return (
    <>
    <li ref={self} id={`msg-${m.id}`} tabIndex={-1} data-message-id={m.id} data-author={m.persona?.name} data-author-id={m.persona?.id} className={cx("group/msg relative flex scroll-mt-4 flex-col gap-1 rounded-xl outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-accent/60 focus-visible:ring-offset-4 focus-visible:ring-offset-bg", mine ? "items-end" : "items-start", highlighted && "ring-2 ring-accent ring-offset-4 ring-offset-bg")} data-enter-key={m.id} data-enter={m.role} data-testid={`${m.role}-message`}>
      {/* Your messages need no name: the bubble on the right is you. */}
      {mine ? null : (
        // Assistant replies carry the avatar of the persona that wrote them (the chat's host
        // when unset) and its name in its color, so a group chat reads like one.
        // The harness · model tag and usage live in the Activity tab, so the chat stays immersive.
        <span className="flex items-center gap-2 text-12 text-fg-tertiary" data-testid="assistant-identity">
          <PersonaAvatar persona={author} size={22} />
          <PersonaName persona={author} className="text-13" />
          <time dateTime={m.created_at}>{timelineTime(m.created_at)}</time>
        </span>
      )}
      {/* The live card's steps, folded to a line once the turn ended. Its events all precede the reply. */}
      {!mine && turn && <TurnSteps runId={m.run_id} outcome="done" since={turn.since} until={m.created_at} end={Date.parse(m.created_at)} replyId={m.id} />}
      {!mine && videos?.length ? <VideoCards chatId={chat.id} videos={videos} messageId={m.id} /> : null}
      {!mine && audio?.length ? <AudioCards chatId={chat.id} audio={audio} messageId={m.id} /> : null}
      {/* Replies read as prose on the page; only real objects (canvases, runs, sources) get a card. */}
      <div
        className={cx(
          "type-chat max-w-[min(720px,100%)]",
          mine ? "rounded-2xl bg-selected px-4 py-2.5" : "w-full text-fg-2",
        )}
        data-testid={mine ? undefined : "reply-body"}
      >
        {editing ? (
          <form
            className="flex w-[min(560px,70vw)] flex-col gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (draft.trim() && onEdit) {
                // The draft is what was typed; the dock's context it was sent with goes back with it.
                onEdit(draft + m.body_md.slice(parts.body.length));
                setEditing(false);
              }
            }}
          >
            <textarea aria-label="Edit message" autoFocus rows={Math.min(10, draft.split("\n").length + 1)} value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => e.key === "Escape" && setEditing(false)} className="w-full resize-y rounded-md border border-border-strong bg-surface p-2 text-14 text-fg focus:border-accent focus:outline-none" />
            <div className="flex justify-end gap-1.5">
              <Button variant="ghost" onClick={() => setEditing(false)}>Cancel</Button>
              <Button type="submit" variant="primary" disabled={!draft.trim()}>Save and resend</Button>
            </div>
          </form>
        ) : (
          <CiteContext.Provider value={cites.value}>
            <ChatMarkdown replyId={mine ? undefined : m.id} cites={cites.numbers}>{parts.body}</ChatMarkdown>
          </CiteContext.Provider>
        )}
      </div>
      {!mine && videos?.length ? <VideoRendererNotes videos={videos} /> : null}
      {mine ? <SentAttachments attachments={m.attachments} /> : <ReplyAttachments attachments={m.attachments} />}
      {!mine && <CodeChanges changes={m.code_changes} />}
      {mine && <SentChips chips={(m.context_refs ?? []).map((r) => {
        const chip = chipFromRef(r, names);
        // A design's selection rides along with every message sent from the editor.
        return r.kind === "canvas" && r.selection ? { ...chip, label: r.selection.nodes.length ? `Design · ${r.selection.nodes.length} selected` : "Design" } : chip;
      })} />}
      {mine && !editing && m.body_md.trim() && (
        <MessageToolbar messageId={m.id} body={parts.body} mine chat={chat} testId="message-actions"
          onEdit={editable ? () => { setDraft(parts.body); setEditing(true); } : undefined} />
      )}
      {!mine && <Sources citations={m.citations} body={parts.body} listed={parts.listed} runId={m.run_id} since={turn?.since} until={turn?.until} webEvents={!!turn} focus={citeFocus} />}
      {!mine && asides}
      {thread && <ThreadLink messageId={m.id} count={thread.count} running={thread.running} />}
      {!mine && saveable && summaryUrl && <SaveSummary messageId={m.id} url={summaryUrl} />}
      {!mine && saveable && m.body_md.trim() && (
        <MessageToolbar messageId={m.id} body={m.body_md} authorId={m.persona?.id} author={author.name} mine={false} chat={chat} testId="reply-actions"
          onTop={m.body_md.length > LONG_REPLY ? () => self.current?.scrollIntoView({ block: "start", behavior: "smooth" }) : undefined}
          onRetry={onRetry && (async () => { if (await confirmAction({ title: "Replace this reply with a new one?", body: "The current reply is discarded.", confirmLabel: "Retry" })) onRetry(); })} />
      )}
    </li>
    {mine && endedSteps}
    </>
  );
});

type ChatAsides = NonNullable<ReturnType<typeof useChatAsides>["data"]>;

/**
 * The transcript's messages. Typing in the composer re-renders the whole chat screen, so
 * everything handed to a Bubble here is kept referentially stable (memoized, or read through
 * a ref when it is a callback) and a keystroke only re-checks props instead of re-rendering
 * every message's markdown.
 */
function BubbleList({ unreadFrom, list, chat, persona, speakerName, names, highlight, running, since, locked, archived, editPending, lastUser, videosByMessage, audioByMessage, asideList, pinnedRef, editLast }: {
  /** The first reply since the person last read the chat: "New" goes above it. */
  unreadFrom?: string;
  list: Message[];
  chat: ChatInfo;
  persona: PersonaLook;
  speakerName: string;
  names: Map<string, string>;
  highlight: string | null;
  running: boolean;
  since?: string;
  locked: boolean;
  archived: boolean;
  editPending: boolean;
  lastUser?: Message;
  videosByMessage: Map<string, ChatVideo[]>;
  audioByMessage: Map<string, ChatAudio[]>;
  asideList?: ChatAsides;
  pinnedRef: RefObject<boolean>;
  editLast: (body: string) => void;
}) {
  const turns = useMemo(() => turnWindows(list), [list]);
  const latest = useRef({ editLast, retryBody: lastUser?.body_md });
  useEffect(() => {
    latest.current = { editLast, retryBody: lastUser?.body_md };
  });
  const onEdit = useCallback((body: string) => {
    pinnedRef.current = true;
    latest.current.editLast(body);
  }, [pinnedRef]);
  const onRetry = useCallback(() => {
    pinnedRef.current = true;
    if (latest.current.retryBody !== undefined) latest.current.editLast(latest.current.retryBody);
  }, [pinnedRef]);
  // The last reply's window stays open while the next turn runs: that turn's asides are live, below.
  const asideNodes = useMemo(() => {
    const out = new Map<string, ReactNode>();
    for (const [id, t] of turns) {
      const asked = asidesInWindow(asideList, t.since, t.until ?? (running ? since : undefined));
      if (asked.length) out.set(id, <ReplyAsides asides={asked} name={speakerName} />);
    }
    return out;
  }, [turns, asideList, running, since, speakerName]);
  const ended = useMemo(() => endedTurns(list, running), [list, running]);
  // Each message's newest thread, for the line under it.
  const threads = useMemo(() => {
    const out = new Map<string, { count: number; running: boolean }>();
    for (const a of asideList ?? []) if (a.anchor_message_id) out.set(a.anchor_message_id, { count: a.message_count ?? 0, running: a.state === "running" });
    return out;
  }, [asideList]);
  const canEdit = !running && !locked && !editPending && !archived;
  const canRetry = !running && !editPending && !archived && !!lastUser;
  const lastId = list.at(-1)?.id;
  return list.map((m, i) => (
    <Fragment key={m.id}>
    {m.id === unreadFrom && <NewDivider />}
    <Bubble m={m} chat={chat} persona={persona} saveable={!running} names={names} turn={turns.get(m.id)} ended={ended.get(m.id)} highlighted={highlight === m.id}
      editable={canEdit && m.id === lastUser?.id}
      onEdit={onEdit}
      onRetry={canRetry && m.id === lastId ? onRetry : undefined}
      summaryUrl={m.role === "assistant" && turns.has(m.id) ? summaryRequestUrl(list.slice(0, i).findLast((x) => x.role === "user")?.body_md) : null}
      videos={videosByMessage.get(m.id)}
      audio={audioByMessage.get(m.id)}
      asides={asideNodes.get(m.id) ?? null}
      thread={threads.get(m.id)} />
    </Fragment>
  ));
}

/**
 * What a card in a reply can do. The value only changes with the chat's data, not with the
 * draft, so the cards in every reply don't re-render per keystroke; the callbacks are read
 * through a ref for the same reason.
 */
function ReplyActions({ list, chat, running, disabled, agent, ask, researchMore, children }: {
  list: Message[];
  chat: { id: string; project?: string; archived: boolean };
  running: boolean;
  disabled: boolean;
  agent: string;
  ask: (messageId: string, body: string) => void;
  researchMore: (artifactId: string, title: string) => void;
  children: ReactNode;
}) {
  const callbacks = useRef({ ask, researchMore });
  useEffect(() => {
    callbacks.current = { ask, researchMore };
  });
  const canvas = useMemo(() => {
    const last = new Map<string, string>();
    let newest: string | undefined;
    for (const m of list) {
      if (m.role !== "assistant") continue;
      for (const canvasId of canvasFenceIds(m.body_md)) {
        last.set(canvasId, m.id);
        newest = canvasId;
      }
    }
    return { newest, lastMessage: (canvasId: string) => last.get(canvasId), live: running, readOnly: chat.archived, agent };
  }, [list, running, chat.archived, agent]);
  const value = useMemo(() => ({
    ask: (messageId: string, body: string) => callbacks.current.ask(messageId, body),
    researchMore: (artifactId: string, title: string) => callbacks.current.researchMore(artifactId, title),
    disabled,
    chatId: chat.id,
    project: chat.project,
    canvas,
    nextMessage: (id: string) => list.slice(list.findIndex((m) => m.id === id) + 1).find((m) => m.role === "user")?.body_md,
  }), [disabled, chat.id, chat.project, canvas, list]);
  return <RecommendActions.Provider value={value}>{children}</RecommendActions.Provider>;
}

const snippet = (s: string) => (s.length > 120 ? `${s.slice(0, 120).trimEnd()}…` : s);

/**
 * Everything behind the replies: per turn, the model and usage, tool calls, web searches
 * and memory changes (with Undo), plus the running turn's live activity. Kept out of the
 * chat tab so the conversation reads as if no tools ran.
 */
function ActivityLog({ list, turns, groups, running, runId, since, focus }: { list: Message[] | undefined; turns: Map<string, TurnWindow>; groups: Groups; running: boolean; runId?: string; since?: string; focus?: { key: string; at: number } }) {
  const replies = (list ?? []).filter((m) => turns.has(m.id));
  const prompt = new Map<string, string>();
  let last: Message | undefined;
  for (const m of list ?? []) {
    if (m.role === "user") last = m;
    else if (turns.get(m.id)?.followup) prompt.set(m.id, "Follow-up: reacting to the generated images");
    else if (turns.has(m.id) && last) prompt.set(m.id, last.body_md);
  }
  if (!replies.length && !running) {
    return <EmptyState icon="msg" title="No activity yet">Tool calls, web searches and memory changes show here once the assistant replies.</EmptyState>;
  }
  return (
    <ol aria-label="Activity" className="mx-auto flex max-w-[860px] flex-col gap-4">
      {replies.map((m) => {
        const t = turns.get(m.id)!;
        return (
          <li key={m.id} data-testid="activity-turn" className="flex flex-col items-start gap-1.5 border-b border-border-subtle pb-4">
            <span className="flex w-full items-center gap-2 text-12 text-fg-tertiary">
              <span className="min-w-0 flex-1 truncate text-fg-secondary">{snippet(prompt.get(m.id) ?? "")}</span>
              <Tag groups={groups} m={m} />
            </span>
            <TurnToolCalls runId={m.run_id} since={t.since} until={t.until} replyId={m.id} focus={focus} />
            <WebSearchPill runId={m.run_id} since={t.since} until={t.until} />
            <MemoryNotices runId={m.run_id} since={t.since} until={t.until} />
          </li>
        );
      })}
      {running && (
        <li className="flex flex-col gap-2" data-testid="activity-running">
          <span className="text-12 text-fg-secondary">Current turn</span>
          <RunActivity runId={runId} since={since} focus={focus} />
        </li>
      )}
    </ol>
  );
}

/** Activity's cost, model line and log, for the compact tab and the desktop dock's tab. */
function ActivityBody({ chat: c, list, groups, focus }: { chat: NonNullable<ReturnType<typeof useChat>["data"]>; list: Message[] | undefined; groups: Groups; focus?: { key: string; at: number } }) {
  const current: Selection = { harness: c.harness, model: c.model, auto: !!c.auto_model };
  const running = c.state === "running";
  const lastUser = list?.findLast((m) => m.role === "user");
  const since = runningSince(list) ?? lastUser?.created_at;
  return (
    <>
      <div className="mx-auto mb-4 flex max-w-[860px] flex-wrap items-center gap-2">
        <ChatCostChip chatId={c.id} project={c.project} />
        <span className="truncate font-mono text-12 text-fg-tertiary">
          {modelLabel(groups, current).harness} · {modelLabel(groups, current).model}
          {current.auto && " (auto)"}
          {c.effort && ` · ${effortLabel(c.effort)} effort`}
        </span>
      </div>
      <ActivityLog list={list} turns={turnWindows(list)} groups={groups} running={running} runId={c.current_run_id} since={since} focus={focus} />
    </>
  );
}

/** The desktop dock's Activity tab: beside the conversation, so a reply and its trace read side by side. */
export function ChatActivity({ chatId }: { chatId: string }) {
  const chat = useChat(chatId).data;
  const target = useSearchParams().get("message");
  // The same query the conversation reads, so it's shared rather than fetched twice.
  const list = useChatMessages(chatId, target ? 1000 : 200).data?.messages;
  const groups: Groups = useChatModels().data;
  const focus = useActivityFocus();
  if (!chat) return null;
  return (
    // Its own tooltip provider: the dock sits outside the conversation's.
    <Tooltip.Provider delayDuration={200}>
      <div data-testid="chat-activity" className="flex-1 overflow-y-auto px-4 py-4">
        <ActivityBody chat={chat} list={list} groups={groups} focus={focus} />
      </div>
    </Tooltip.Provider>
  );
}

const DRAFT_KEY = (id: string) => `lazyagents.chat-draft:${id}`;
function putDraft(id: string, text: string) {
  try {
    sessionStorage.setItem(DRAFT_KEY(id), text);
  } catch {
    /* No storage: the draft is lost, as before. */
  }
}
function readDraft(id: string): string {
  try {
    return sessionStorage.getItem(DRAFT_KEY(id)) ?? "";
  } catch {
    return "";
  }
}
function dropDraft(id: string) {
  try {
    sessionStorage.removeItem(DRAFT_KEY(id));
  } catch {
    /* Nothing stored. */
  }
}

/**
 * `activityInDock`: the chat page's dock (chat-panel-host) shows Activity beside the conversation
 * on desktop, so the header has no Chat/Activity switch there. Chats embedded in an app's dock
 * (Designs, Docs, Slides, Finance) leave it unset and keep the switch.
 */
export type ConversationContext = {
  /** Replacement conversations keep the host's visibility. */
  hidden?: boolean;
  composer: ReactNode;
  prepare: (body: Schemas["NewChatMessage"]) => Promise<Schemas["NewChatMessage"]>;
  /** Queues and asides accept text only, so the host supplies a snapshot. */
  prepareText: (body: string) => Promise<string>;
  onSent: () => void;
  /**
   * An empty chat's welcome in a narrow app dock: a one-line greeting and the host's own starters,
   * in place of the full-page greeting and the person's general suggestions, which are about other work.
   */
  welcome?: DockWelcome;
};

export type DockStarter = { icon: IconName; title: string; prompt: string };
export type DockWelcome = { where: string; intro: string; label: string; starters: DockStarter[] };

/** Renders `children` into `slot` when there is one (the dock's header row), else in place. */
function InSlot({ slot, children }: { slot: HTMLElement | null; children: ReactNode }) {
  return slot ? createPortal(children, slot) : <>{children}</>;
}

/** `docked`: the conversation sits in an app's or a side panel's dock, narrow beside the work, so a live reply's steps start folded. */
export function Conversation({ id, onNew, actions, activityInDock = false, docked = false, context, onReplace }: { id: string; onNew: () => void; actions?: ReactNode; activityInDock?: boolean; docked?: boolean; context?: ConversationContext; onReplace?: (id: string) => void | Promise<void> }) {
  const chat = useChat(id);
  // In an app's dock the chat's header is the dock's first row, which continues the page's top bar.
  const headerSlot = useDockHeaderSlot();
  const urlSearch = useSearchParams();
  const target = urlSearch.get("message");
  const messages = useChatMessages(id, target ? 1000 : 200);
  const edit = useEditLastChatMessage(id);
  const models = useChatModels();
  const send = useSendChatMessage(id, context?.prepare);
  const queue = useQueueFollowup(id, context?.prepareText);
  const aside = useStartAside(id, context?.prepareText);
  const asideList = useChatAsides(id).data;
  // While a reply runs, how Send sends: queue a follow-up (the default), ask an aside, or interrupt.
  const [sendMode, setSendMode] = useState<SendMode>("followup");
  const [modeError, setModeError] = useState<string | null>(null);
  const [players] = useState(() => new Map<string, (seconds: number) => void>());
  const cancel = useCancelChat(id);
  const boot = useBootstrap();
  const personas = usePersonas();
  const create = useCreateChat();
  const selectRepo = useSetChatRepository(id);
  const [repoSignal, setRepoSignal] = useState(0);
  // The compact composer keeps the repository picker in its options sheet: the chat menu opens that.
  const [sheetSignal, setSheetSignal] = useState(0);
  const savedRepos = useRepositories();
  const discard = useDeleteChat();
  const qc = useQueryClient();
  // A persona switch hands the unsent draft over to the new chat.
  const [text, setText] = useState(() => readDraft(id));
  // Read once into state, then forget it (an effect, so a StrictMode re-render still sees it).
  useEffect(() => dropDraft(id), [id]);
  const [picked, setPicked] = useState<Selection | null>(null);
  // null keeps the chat's effort; "default" clears it.
  const [pickedEffort, setPickedEffort] = useState<Effort | "default" | null>(null);
  // The header switches the conversation for Activity, except on the chat page's desktop dock, where Activity is a tab beside it.
  const [tab, setTab] = useState<"chat" | "activity">("chat");
  const compact = useCompact();
  const dockActivity = activityInDock && !compact;
  const view = dockActivity ? "chat" : tab;
  // "View reasoning" on a chat step: Activity opens on that step (the compact tab, or the dock's tab).
  const [traceFocus, setTraceFocus] = useState<{ key: string; at: number }>();
  // The same for a finished turn's step in the conversation, kept stable so replies don't re-render.
  const openStepRef = useRef<(key: string) => void>(undefined);
  const openTurnStep = useCallback((key: string) => openStepRef.current?.(key), []);
  // The header's live line opens the turn's Activity: the dock's tab on desktop, the chat's own tab otherwise.
  const openActivity = () => {
    if (!dockActivity) return setTab("activity");
    const q = setDock(new URLSearchParams(window.location.search), { tab: "activity", open: true });
    router.replace(`${window.location.pathname}?${q.toString()}`, { scroll: false });
  };
  const openStep = (key: string) => {
    if (dockActivity) {
      focusActivityStep(key);
      const q = setDock(new URLSearchParams(window.location.search), { tab: "activity", open: true });
      router.replace(`${window.location.pathname}?${q.toString()}`, { scroll: false });
      return;
    }
    setTab("activity");
    setTraceFocus({ key, at: Date.now() });
  };
  useEffect(() => {
    openStepRef.current = openStep;
  });
  // A pick on another harness waits here until the person confirms what the switch loses.
  const [confirming, setConfirming] = useState<Selection | null>(null);
  const router = useRouter();
  const search = useSearchParams();
  const { start: startDeck } = useNewDeck();
  // "Start chat" links arrive with ?attach=kind:id; seed once, then drop it from the URL.
  const [chips, setChips] = useState<Chip[]>(() => parseAttach(search.getAll("attach"), search.get("attach_title")));
  const files = useAttachments();
  const snippets = useSnippets();
  const area = useRef<HTMLTextAreaElement>(null);
  const end = useRef<HTMLLIElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const log = useRef<HTMLOListElement>(null);
  // Following the newest message; off once the person scrolls up, or arrives at a search hit.
  const pinned = useRef(!target);
  // Dragging the scrollbar or touch-scrolling: only then does a scroll away from the end mean the person moved.
  const dragging = useRef(false);
  const [newReply, setNewReply] = useState(false);
  // On for one message: asks for a research plan to approve.
  const [research, setResearch] = useState(false);
  const [highlight, setHighlight] = useState<string | null>(null);
  const workflows = useWorkflows();
  const [startingWorkflow, setStartingWorkflow] = useState<Workflow | null>(null);
  const setCommitEmail = useSetChatCommitEmail();
  const [commitPickerOpen, setCommitPickerOpen] = useState(false);
  // What the trays above the composer hold, so the status slot can rank them (the queries are shared with the trays).
  const allTicketRuns = useChatTicketRuns(id).data?.runs;
  const ticketRuns = (allTicketRuns ?? []).filter((r) => !runEnded(r.state));
  const workflowRuns = (useChatWorkflowRuns(id).data?.runs ?? []).filter((r) => runActive(r.state));
  const followups = useChatFollowups(id).data ?? [];

  const c = chat.data;
  // A chat you open on the chat page is a place to come back to; a dock's chat belongs to the page it sits beside.
  useRecordVisit(c && !docked && !context?.hidden && c.message_count > 0
    ? { id: `chat-${c.id}`, title: c.title || "Untitled chat", meta: (c.speaker ?? c.persona)?.name ?? "Assistant", href: `/chat/${c.id}`, kind: "Chats" } : undefined);
  const loaded = !!c;
  const running = c?.state === "running";
  // Videos sit on the reply their turn stored; the running turn's show live under it.
  const videos = useChatVideos(c?.id, running);
  const videosByMessage = useMemo(() => {
    const out = new Map<string, ChatVideo[]>();
    for (const v of videos.data?.videos ?? []) if (v.message_id) out.set(v.message_id, [...(out.get(v.message_id) ?? []), v]);
    return out;
  }, [videos.data]);
  const liveVideos = useMemo(() => (videos.data?.videos ?? []).filter((v) => !v.message_id && running && v.run_id === c?.current_run_id), [videos.data, running, c?.current_run_id]);
  // Audio the same way.
  const audioJobs = useChatAudio(c?.id, running);
  const audioByMessage = useMemo(() => {
    const out = new Map<string, ChatAudio[]>();
    for (const a of audioJobs.data?.audio ?? []) if (a.message_id) out.set(a.message_id, [...(out.get(a.message_id) ?? []), a]);
    return out;
  }, [audioJobs.data]);
  const liveAudio = useMemo(() => (audioJobs.data?.audio ?? []).filter((a) => !a.message_id && running && a.run_id === c?.current_run_id), [audioJobs.data, running, c?.current_run_id]);
  const stopping = running && (cancel.isPending || cancel.isSuccess);
  // Also locked while a persona switch creates the replacement chat, so nothing is sent to the one it drops.
  // A running reply doesn't lock the composer: a message sent then interrupts it,
  // and the next reply answers both, picking up from what the stopped one had done.
  const locked = send.isPending || create.isPending;
  const groups: Groups = models.data;
  const current: Selection | undefined = c && { harness: c.harness, model: c.model, auto: !!c.auto_model };
  const selection = picked ?? current;
  const pending = !!(picked && current && !sameSelection(picked, current));
  const offered = selection ? modelEfforts(groups, selection) : { efforts: [] };
  // The effort the next message runs at; one the selected model lacks falls back to automatic, as on the server.
  const wanted = pickedEffort === null ? c?.effort : pickedEffort === "default" ? undefined : pickedEffort;
  const effort = wanted && offered.efforts.includes(wanted) ? wanted : undefined;
  const modelSummary = selection ? modelEffortSummary(groups, selection, offered.efforts.length > 0, effort).text : undefined;
  const effortPending = !!c && effort !== c.effort;
  // The next message would start a run on a harness that can't run: say why before sending.
  const unavailable = selection && groups?.find((g) => g.harness === selection.harness && !g.available);
  const nextRunSettings = {
    ...(pending && picked ? (picked.auto ? { model: "auto" } : { harness: picked.harness, model: picked.model }) : {}),
    ...(effortPending ? { effort: effort ?? ("default" as const) } : {}),
  };
  const list = messages.data?.messages;
  // Where "New" goes: before the first reply that arrived since the person last read this chat,
  // fixed when the chat opens so it doesn't move as they read on.
  const [unreadFrom, setUnreadFrom] = useState<{ chat: string; message: string | null }>();
  if (c && list && unreadFrom?.chat !== c.id) {
    const replies = list.filter((m) => m.role === "assistant");
    const n = c.unread ?? 0;
    setUnreadFrom({ chat: c.id, message: n > 0 && n <= replies.length ? replies[replies.length - n].id : null });
  }
  useEntrances(log);
  const lastUser = list?.findLast((m) => m.role === "user");
  // The running turn starts after the newest message, which may be a reply, not
  // the person's: a persona handing on, or the image follow-up.
  const since = runningSince(list) ?? lastUser?.created_at;
  const drop = useFileDrop(files.add, !!c && !c.archived && !locked);
  // From the playground: Send to chat's report and screenshot, or an ask to map its API.
  const addFiles = useRef(files.add);
  useEffect(() => {
    addFiles.current = files.add;
  });
  useEffect(() => {
    if (!c?.id || c.archived) return;
    return onComposerDrop(c.id, (drop) => {
      if (drop.files?.length) addFiles.current(drop.files);
      if (drop.text) setText((t) => (t.trim() ? `${t}\n\n${drop.text}` : drop.text!));
      area.current?.focus();
    });
  }, [c?.id, c?.archived]);

  useEffect(() => {
    if (!search.has("attach")) return;
    const q = new URLSearchParams(search.toString());
    q.delete("attach");
    q.delete("attach_title");
    router.replace(`/chat/${id}?${q.toString()}`);
  }, [search, router, id]);
  // Refs only carry ids; remember what the chips were called so sent messages can show it.
  const [names, setNames] = useState(() => new Map<string, string>());
  // What the conversation links to, opened beside it in the chat page's dock (not from an app's dock: it has none of its own).
  const linked = useMemo(
    () => linkedItems((list ?? []).flatMap((m) => (m.role === "user" ? (m.context_refs ?? []) : [])), allTicketRuns ?? []),
    [list, allTicketRuns],
  );
  const openLinked = useCallback(
    (item: LinkedItem) => router.replace(`${window.location.pathname}?${openItem(new URLSearchParams(window.location.search), item)}`, { scroll: false }),
    [router],
  );
  const linkedLabel = (item: LinkedItem) => {
    if (item.kind === "ticket") return item.key;
    if (item.kind === "page") return names.get(item.id) ?? "Page";
    const r = allTicketRuns?.find((x) => x.run_id === item.id);
    return r ? `${r.ticket} run` : "Run";
  };

  // Refetch the transcript when the chat changes (also covers polling without SSE).
  const stamp = c && `${c.state}:${c.message_count}:${c.revision}`;
  useEffect(() => {
    if (!stamp) return;
    void qc.invalidateQueries({ queryKey: chatKeys.messages(id) });
    // A finished turn's last tool results (memory notices) may have landed after the final poll.
    void qc.invalidateQueries({ queryKey: ["runs", "chat"] });
  }, [stamp, id, qc]);
  // Focus returns to the composer on load and whenever a turn ends.
  useEffect(() => {
    if (loaded && !locked) area.current?.focus();
  }, [locked, loaded]);
  useEffect(() => {
    if (pinned.current) {
      end.current?.scrollIntoView?.({ block: "end" });
      return;
    }
    if (list?.at(-1)?.role !== "assistant") return;
    const show = setTimeout(() => setNewReply(true), 0);
    return () => clearTimeout(show);
  }, [list?.length, running]); // eslint-disable-line react-hooks/exhaustive-deps -- only a new message or turn moves the view
  // Replies keep growing after they land (a running turn's narration and steps, diagrams, apps,
  // images) and trays above the composer shrink the view; stay at the end while pinned there.
  const hasLog = !!list && (list.length > 0 || running);
  useEffect(() => {
    const view = scroller.current;
    const content = log.current;
    if (!view || !content) return;
    const follow = new ResizeObserver(() => {
      if (pinned.current) view.scrollTop = view.scrollHeight;
    });
    follow.observe(view);
    follow.observe(content);
    return () => follow.disconnect();
  }, [hasLog]);
  const targetFound = !!target && !!list?.some((m) => m.id === target);
  useEffect(() => {
    if (!target || !targetFound) return;
    pinned.current = false;
    document.getElementById(`msg-${target}`)?.scrollIntoView({ block: "center" });
    const on = setTimeout(() => setHighlight(target), 0);
    const off = setTimeout(() => setHighlight(null), 2400);
    return () => {
      clearTimeout(on);
      clearTimeout(off);
    };
  }, [target, targetFound]);
  // The composer starts at one line and grows with what's typed, up to a limit.
  useEffect(() => {
    const el = area.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight + 2, 220)}px`;
  }, [text, loaded]);
  const followLatest = () => {
    pinned.current = true;
    setNewReply(false);
    end.current?.scrollIntoView?.({ block: "end", behavior: "smooth" });
  };
  const researchMore = (artifactId: string, title: string) => {
    const chip = chipFromTarget({ kind: "artifact", id: artifactId, title, artifact_type: "report" });
    if (chip) setChips((cs) => addChip(cs, chip));
    setResearch(true);
    setText("Go deeper on this report: ");
    area.current?.focus();
  };
  // Sent from its own box, so the draft in the composer (and its chips and files) stays put.
  // A failed send moves the question to the composer rather than losing it.
  const askAboutSelection = (selected: string, question: string, authorId?: string, author?: string) => {
    if (locked || unavailable) return false;
    const body = quoteForComposer(selected, authorId && authorId !== (c?.speaker ?? c?.persona)?.id ? author : undefined) + question;
    cancel.reset();
    pinned.current = true;
    send.mutate({ body, ...nextRunSettings }, { onSuccess: context?.onSent, onError: () => setText((t) => (t ? `${body}\n\n${t}` : body)) });
    return true;
  };

  // A message's Reply quotes it into the box, above whatever is already drafted, and puts the caret after it.
  const replyTo = useRef<(body: string, authorId?: string, author?: string) => void>(() => {});
  replyTo.current = (body, authorId, author) => {
    const quote = quoteForComposer(body, authorId && authorId !== (c?.speaker ?? c?.persona)?.id ? author : undefined);
    setText((t) => quote + t);
    requestAnimationFrame(() => {
      const el = area.current;
      el?.focus();
      el?.setSelectionRange(quote.length, quote.length);
    });
  };
  // Threads open in the desktop dock (the compact sheet has no Thread tab yet).
  const threadDock = dockActivity;
  const messageActions = useMemo<MessageActions>(() => ({
    reply: (body, authorId, author) => replyTo.current(body, authorId, author),
    ...(threadDock ? { thread: (messageId: string) => router.replace(`${window.location.pathname}?${openThread(new URLSearchParams(window.location.search), messageId).toString()}`, { scroll: false }) } : {}),
  }), [threadDock, router]);

  // J/K move between messages, R replies to the one in focus, T threads it, E edits your last
  // message, Esc goes back to the box: the messaging-app keys, listed in the ? reference.
  const keyNav = useRef<(e: KeyboardEvent) => void>(() => {});
  keyNav.current = (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || e.defaultPrevented || isTyping(e.target) || view !== "chat") return;
    const items = [...(log.current?.querySelectorAll<HTMLElement>("li[data-message-id]") ?? [])];
    const at = items.findIndex((el) => el === document.activeElement);
    const key = e.key.toLowerCase();
    if (key === "j" || key === "k") {
      if (!items.length) return;
      e.preventDefault();
      const next = at < 0 ? (key === "k" ? items.length - 1 : 0) : Math.min(items.length - 1, Math.max(0, at + (key === "j" ? 1 : -1)));
      items[next].focus();
      items[next].scrollIntoView({ block: "nearest" });
      if (key === "k") pinned.current = false;
      return;
    }
    if (e.key === "Escape" && at >= 0) {
      e.preventDefault();
      area.current?.focus();
      return;
    }
    const focused = at >= 0 ? list?.find((x) => x.id === items[at].dataset.messageId) : undefined;
    if (key === "r" && focused && !c?.archived) {
      e.preventDefault();
      replyTo.current(focused.body_md, focused.persona?.id, focused.persona?.name);
    } else if (key === "t" && focused && focused.role !== "system" && threadDock && !c?.archived) {
      e.preventDefault();
      messageActions.thread?.(focused.id);
    } else if (key === "e" && lastUser && !running && !c?.archived) {
      e.preventDefault();
      document.querySelector<HTMLElement>(`#msg-${lastUser.id} [aria-label="Edit"]`)?.click();
    }
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => keyNav.current(e);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  function submit(body: string) {
    if (!body.trim() || locked || unavailable || files.pending || commitPickRequired) return;
    cancel.reset();
    pinned.current = true;
    const context_refs = toContextRefs(chips);
    setNames((n) => new Map([...n, ...chips.map((c): [string, string] => [c.key, c.label])]));
    send.mutate(
      {
        body,
        ...(research ? { research: true } : {}),
        ...nextRunSettings,
        ...(context_refs ? { context_refs } : {}), ...(files.ids.length ? { attachment_ids: files.ids } : {}) },
      {
        onSuccess: () => {
          context?.onSent();
          files.clear();
          snippets.clear();
          setText("");
          setPicked(null);
          setPickedEffort(null);
          setChips([]);
          setResearch(false);
        },
      },
    );
  }

  // Queues the message, or asks it as an aside, without stopping the reply; Interrupt
  // sends it as usual. Neither of the first two carries context, files or research.
  function sendWhileRunning(mode: SendMode, body: string): string | void {
    if (mode === "interrupt") return submit(body);
    if (!body.trim() || locked || queue.isPending || aside.isPending) return;
    if (chips.length || files.ids.length || files.pending || research) {
      const what = mode === "aside" ? "An aside" : "A follow-up";
      return `${what} is text only: remove the context and files, or pick Interrupt to send them now.`;
    }
    setModeError(null);
    pinned.current = true;
    const sent = () => {
      context?.onSent();
      setText("");
      snippets.clear();
    };
    if (mode === "aside") aside.mutate(body, { onSuccess: sent });
    else queue.mutate(body, { onSuccess: sent });
  }

  // A card's button or a choice: goes to the persona that wrote the reply. A mention
  // is only needed when someone else would answer next.
  function askAuthor(messageId: string, body: string) {
    pinned.current = true;
    const by = list?.find((m) => m.id === messageId)?.persona;
    send.mutate({ body: by && by.id !== (c?.speaker ?? c?.persona)?.id ? `@${by.name} ${body}` : body }, { onSuccess: context?.onSent });
  }

  // Before the first message the persona can still change: a chat keeps its persona for life,
  // so switching starts a fresh chat with the other persona and drops this empty one.
  const fresh = !!c && !c.archived && c.message_count === 0 && !running && !list?.length;
  // Whether the live status card is on screen: the header's live line shrinks to a dot while it is.
  const statusRef = useRef<HTMLDivElement>(null);
  const [statusInView, setStatusInView] = useState(false);
  useEffect(() => {
    const card = statusRef.current?.querySelector("[data-testid='chat-status-card']");
    if (!running || !card) {
      setStatusInView(false);
      return;
    }
    const seen = new IntersectionObserver(([entry]) => setStatusInView(entry.isIntersecting));
    seen.observe(card);
    return () => seen.disconnect();
  }, [running, c?.current_run_id]);
  // With several addresses, a coding chat asks which one its commits use; the
  // first message waits for the answer, later ones don't.
  const myEmails = boot.data?.me.emails ?? [];
  const askCommitEmail = !!c && !c.archived && needsCommitEmailPick(myEmails, c.repo_url, c.commit_email);
  const commitPickRequired = fresh && askCommitEmail;
  function switchPersona(personaId: string) {
    if (!c || personaId === c.persona?.id || create.isPending || send.isPending || send.isSuccess) return;
    replaceChat(personaId, undefined, messageWithSnippets(text, snippets.items), !!c.temporary);
  }
  // A chat is temporary for life, so before the first message switching it is a fresh chat too.
  function switchTemporary(temporary: boolean) {
    if (!c || temporary === !!c.temporary || create.isPending || send.isPending || send.isSuccess) return;
    replaceChat(c.persona?.id, c.repo_url, messageWithSnippets(text, snippets.items), temporary);
  }
  // Moves to a new chat, carrying the draft over. The old one is only dropped if it is still empty.
  function replaceChat(personaId: string | undefined, repo: string | undefined, draft: string, temporary: boolean) {
    if (!c) return;
    const old = c;
    create.mutate(
      { ...(old.project ? { project: old.project } : {}), ...(personaId ? { persona_id: personaId } : {}), ...(temporary ? { temporary } : {}), ...(context?.hidden ? { hidden: true } : {}), harness: old.harness, model: old.auto_model ? "auto" : old.model, ...(old.effort ? { effort: old.effort } : {}), ...(repo ? { repo_url: repo } : {}) },
      {
        onSuccess: async (next) => {
          if (draft.trim()) putDraft(next.id, draft);
          if (onReplace) {
            try { await onReplace(next.id); }
            catch { return; } // The host shows the failure; keep the old chat until the replacement is linked.
          } else router[old.message_count === 0 ? "replace" : "push"](`/chat/${next.id}`);
          // Only drop the old chat if it is still empty (a message may have come from another tab).
          // If the check or the delete fails, the empty chat just stays in the list.
          const latest = await unwrap(api.GET("/chats/{id}", { params: { path: { id: old.id } } })).catch(() => undefined);
          if (latest && latest.message_count === 0 && latest.state !== "running") discard.mutate(old.id);
        },
      },
    );
  }

  if (chat.isError) {
    const gone = chat.error instanceof ApiError && chat.error.status === 404;
    return (
      <div className="p-6">
        <Banner tone="blocked" title={gone ? "This chat doesn’t exist" : "Couldn’t load the chat"}>
          {errorText(chat.error)}
        </Banner>
      </div>
    );
  }
  if (!c) {
    return (
      <div aria-busy="true" className="flex flex-1 flex-col gap-4 p-6">
        <Skeleton className="h-6 w-1/3" />
        <Skeleton className="h-16 w-2/3" />
        <Skeleton className="ml-auto h-10 w-1/2" />
      </div>
    );
  }
  const actionError = send.error ?? queue.error ?? aside.error ?? edit.error ?? cancel.error ?? create.error ?? setCommitEmail.error;
  // A chat without a persona, or whose persona was deleted, is the built-in Assistant.
  const persona = personaLook(c.persona);
  const full = personas.data?.personas.find((p) => p.id === c.persona?.id);
  const participants = (c.participants ?? (c.persona ? [c.persona] : [])).map(personaLook);
  const group = participants.length > 1;
  // Who answers next (or is answering now): the last speaker, else the host.
  const speaker = personaLook(c.speaker ?? c.persona);
  // Restoring a chat opened from the Archived list shows it under Active again.
  const restored = () => {
    if (!search.has("view")) return;
    const q = new URLSearchParams(search.toString());
    q.delete("view");
    router.replace(`/chat/${id}?${q.toString()}`);
  };
  const pick = (s: Selection) => {
    if (current && needsSwitchConfirm(current, s, picked, c.message_count)) setConfirming(s);
    else setPicked(s);
  };

  // ---- / commands: what each does; the Composer parses and runs them ----
  const startInstead = (personaId: string, repo?: string): string | void => {
    if (create.isPending || send.isPending) return "Wait for the current message to finish sending.";
    replaceChat(personaId, repo, "", false);
  };
  const whileIdle = (what: string, run: () => void): string | void => (running ? `Wait for the reply to finish before changing the ${what}.` : run());
  const plainCommands: Record<string, CommandRun> = {
    new: onNew,
    memory: () => router.push("/customization"),
    stop: () => {
      if (!running) return "There’s no reply to stop.";
      if (!stopping) cancel.mutate();
    },
  };
  const published = (workflows.data?.workflows ?? []).filter((w) => w.published_version > 0);
  // /workflow on the welcome makes the chat first, then opens it with ?workflow= to show the start card.
  const workflowCard = startingWorkflow ?? published.find((w) => w.id === search.get("workflow")) ?? null;
  const closeWorkflow = () => {
    setStartingWorkflow(null);
    if (!search.has("workflow")) return;
    const q = new URLSearchParams(search.toString());
    q.delete("workflow");
    const qs = q.toString();
    router.replace(qs ? `/chat/${id}?${qs}` : `/chat/${id}`);
  };
  // The + menu's "Create with {persona}": Doc and Design start a draft for the person to finish; a deck is made and opened.
  const createWith = (kind: CreateKind) => {
    if (kind === "slides") return startDeck();
    setText((t) => (kind === "design" ? `/design ${t.trim()}` : `${DOC_DRAFT}${t.trim()}`));
    requestAnimationFrame(() => {
      const el = area.current;
      el?.focus();
      el?.setSelectionRange(el.value.length, el.value.length);
    });
  };
  const commandOptions = (name: string): { name: string; run: CommandRun }[] => {
    switch (name) {
      case "workflow":
        return published.map((w) => ({ name: w.name, run: () => setStartingWorkflow(w) }));
      case "model":
        return [
          ...(current ? [{ name: "Auto", run: () => whileIdle("model", () => pick({ ...current, auto: true })) }] : []),
          ...(groups ?? [])
            .filter((g) => g.available)
            .flatMap((g) => g.models.map((m) => ({ name: `${g.label} ${m.label}`, run: () => whileIdle("model", () => pick({ harness: g.harness, model: m.id })) }))),
        ];
      case "effort":
        return [undefined, ...offered.efforts].map((e) => ({ name: effortLabel(e).toLowerCase(), run: () => whileIdle("effort", () => setPickedEffort(e ?? "default")) }));
      case "persona":
        return (personas.data?.personas ?? []).map((p) => ({ name: p.name, run: () => (p.id === c.persona?.id ? `You’re already talking to ${p.name}.` : startInstead(p.id)) }));
      case "repo":
        return (c.speaker ?? c.persona)?.capabilities?.code
          ? (savedRepos.data ?? []).map((r) => ({ name: r.name, run: () => selectRepo.mutate(r.url) }))
          : [];
      default:
        return [];
    }
  };
  const composerList = composerOptions({
    code: !!(c.speaker ?? c.persona)?.capabilities?.code,
    repo: c.repo_url,
    pendingRepo: c.pending_repo_url,
    persona: fresh ? (c.persona?.name ?? speaker.name) : undefined,
    sendMode: running ? SEND_MODE_LABEL[sendMode] : undefined,
    research,
    temporary: fresh ? !!c.temporary : undefined,
    model: modelSummary,
    project: c.space ? undefined : { name: boot.data?.projects.find((p) => p.key === c.project)?.name },
  });
  const canCode = !!(c.speaker ?? c.persona)?.capabilities?.code;
  const repoPicker = canCode && (
    <RepositoryPicker
      value={c.repo_url}
      pending={c.pending_repo_url}
      onPick={(r) => selectRepo.mutate(r)}
      disabled={c.archived || selectRepo.isPending}
      error={selectRepo.error}
      signal={repoSignal}
      personaName={speaker.name}
      personaRepos={personas.data?.personas.find((p) => p.id === (c.speaker ?? c.persona)?.id)?.repos}
    />
  );
  return (
    <Tooltip.Provider delayDuration={200}>
      <section aria-label={chatTitle(c)} className="relative flex min-h-0 flex-1 flex-col" {...drop.props}>
        <DropOverlay over={drop.over} />
        {/* Sized by its own width: a panel beside the chat can leave it narrow on a wide screen. */}
        {/* The page's only header: who you're talking to, the title, then the chat's context. */}
        {compact ? (
          <CompactChatHeader
            chat={c}
            personas={group ? participants : [persona]}
            tab={tab}
            onTab={setTab}
            running={running}
            canCode={!!(c.speaker ?? c.persona)?.capabilities?.code}
            onRepository={() => { setTab("chat"); setSheetSignal((n) => n + 1); }}
            onRestored={restored}
          />
        ) : (
        <InSlot slot={headerSlot}>
        <div data-testid="chat-header" className={cx(
          "@container flex min-w-0 items-center",
          headerSlot ? "h-full flex-1 gap-1.5 pl-1" : cx("min-h-[44px] border-b border-border-subtle py-1.5", docked ? "gap-1.5 pl-3 pr-2" : "gap-2.5 pl-3 pr-6"),
        )}>
          {/* Back and forward lead the page; a dock's chat sits beside a page that has its own. */}
          {!docked && <HistoryNav />}
          {group ? <PersonaStack personas={participants} size={22} /> : <HeaderPersona persona={persona} personaId={c.persona?.id} fresh={fresh} onSwitch={switchPersona} disabled={locked || create.isPending} compact={docked} />}
          {/* In an app's dock the app is the page around it, so the header doesn't name it again. */}
          {c.space && !docked && <SpaceBreadcrumb space={c.space} />}
          {/* The title over a live line, as a messaging app shows who's typing; the line goes when the reply ends. */}
          <div className="flex min-w-0 flex-1 flex-col items-start justify-center">
            <ChatTitleMenu
              chat={c}
              participants={participants}
              running={running}
              commitEmail={c.repo_url && c.commit_email && myEmails.length > 1 ? c.commit_email : undefined}
              onCommitEmail={() => setCommitPickerOpen((o) => !o)}
            />
            {running && <ChatPresence runId={c.current_run_id} since={since} persona={speaker} dotOnly={docked || statusInView} onOpen={openActivity} />}
          </div>
          {/* A dock has no room for the picker in its one header row: it moves to the composer's + menu. */}
          {repoPicker && !docked && <span className="flex min-w-0 max-w-[40%] flex-shrink">{repoPicker}</span>}
          <ChatRunsPill chatId={c.id} />
          {!dockActivity && docked && (
            <button type="button" aria-pressed={tab === "activity"} aria-label="Activity" title={tab === "activity" ? "Back to the chat" : "Activity: this chat's tool calls and memory"}
              onClick={() => setTab(tab === "activity" ? "chat" : "activity")}
              className={cx("grid size-7 flex-none place-items-center rounded-md", tab === "activity" ? "bg-selected text-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg")}>
              <Icon name="history" size={14} />
            </button>
          )}
          {!dockActivity && !docked && (
            <span className="flex-none">
              <Tabs
                label="Chat view"
                value={tab}
                onChange={(k) => setTab(k === "activity" ? "activity" : "chat")}
                items={[
                  { key: "chat", label: "Chat" },
                  { key: "activity", label: "Activity" },
                ]}
              />
            </span>
          )}
          {c.archived && <RestoreChat chat={c} onRestored={restored} />}
          {actions}
        </div>
        </InSlot>
        )}
        {dockActivity && view === "chat" && <LinkedRow items={linked} label={linkedLabel} onOpen={openLinked} />}
        {c.space && view === "chat" && <SpaceContextChips space={c.space} chat={c} disabled={running} dense={docked} />}
        {/* Mounted while hidden so memory notices still refresh. On the chat page's desktop dock Activity is its own tab (ChatActivity). */}
        {!dockActivity && (
          <div role="tabpanel" aria-label="Activity" hidden={tab !== "activity"} className="flex-1 overflow-y-auto px-6 py-5">
            <ActivityBody chat={c} list={list} groups={groups} focus={traceFocus} />
          </div>
        )}
        <div
          ref={scroller}
          role="tabpanel"
          aria-label="Chat"
          hidden={view !== "chat"}
          className="relative flex-1 overflow-y-auto px-6 py-5"
          // Only the person's input lets go of the end. A scroll event alone can't tell: the one for our
          // own scroll, or for the browser clamping it as content shrinks, may land after the content grew
          // again, far from the end without anyone having moved.
          onWheel={(e) => {
            if (e.deltaY < 0) pinned.current = false;
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowUp" || e.key === "PageUp" || e.key === "Home") pinned.current = false;
          }}
          onPointerDown={(e) => {
            // On the panel itself rather than a message: that's the scrollbar.
            if (e.target === e.currentTarget) dragging.current = true;
          }}
          onPointerUp={() => (dragging.current = false)}
          onTouchStart={() => (dragging.current = true)}
          onTouchEnd={() => (dragging.current = false)}
          onScroll={(e) => {
            const el = e.currentTarget;
            const atEnd = el.scrollHeight - el.scrollTop - el.clientHeight < 120;
            if (atEnd) {
              pinned.current = true;
              setNewReply(false);
            } else if (dragging.current) pinned.current = false;
          }}
        >
          {messages.isError ? (
            <Banner tone="blocked" title="Couldn’t load messages">{errorText(messages.error)}</Banner>
          ) : !list ? (
            <div aria-busy="true" className="flex flex-col gap-3">
              <Skeleton className="h-12 w-1/2" />
              <Skeleton className="h-16 w-2/3" />
            </div>
          ) : list.length === 0 && !running ? (
            c.archived ? (
              <EmptyState icon="msg" title="A new conversation">
                Ask about your runs, tickets, epics and wiki, or have me draft tickets. I save useful things to your private memory and tell you when I do.
              </EmptyState>
            ) : (
              context?.welcome ? (
                <DockGreeting persona={persona} tone={full?.tone} welcome={context.welcome} onPick={submit} disabled={locked || !!unavailable || !!text.trim()} />
              ) : (
              <>
              <PersonaGreeting
                persona={persona}
                tone={full?.tone}
                isDefault={!!c.persona && c.persona.id === personas.data?.default_persona_id}
                firstName={boot.data?.me.name?.split(" ")[0]}
                canSwitch={!!personas.data?.personas.length}
              />
              {/* Picking one sends it, which would drop a half-written message. */}
              {!text.trim() && <ChatSuggestions onPick={submit} disabled={locked || !!unavailable} />}
              </>
              )
            )
          ) : (
            <>
            <VideoPlayers.Provider value={players}>
            <ReplyActions list={list} chat={c} running={running} disabled={running || locked || !!unavailable || c.archived} agent={(c.speaker ?? c.persona)?.name ?? "Assistant"} ask={askAuthor} researchMore={researchMore}>
            <OpenLinkedItem.Provider value={dockActivity ? openLinked : undefined}>
            <OpenTurnStep.Provider value={openTurnStep}>
            <MessageActionsContext.Provider value={c.archived ? null : messageActions}>
            <ol ref={log} aria-label="Conversation" role="log" aria-live="polite" className="mx-auto flex max-w-[768px] flex-col gap-6">
              {messages.data?.has_more && <Divider>Earlier messages are not shown</Divider>}
              <BubbleList unreadFrom={unreadFrom?.message ?? undefined} list={list} chat={c} persona={persona} speakerName={speaker.name} names={names} highlight={highlight} running={running} since={since}
                locked={locked} archived={c.archived} editPending={edit.isPending} lastUser={lastUser} videosByMessage={videosByMessage} audioByMessage={audioByMessage} asideList={asideList}
                pinnedRef={pinned} editLast={edit.mutate} />
              <PersonaProposals chatId={c.id} disabled={c.archived} />
              <ConnectorRequests chatId={c.id} disabled={c.archived} />
              <SecretRequests chatId={c.id} disabled={c.archived} />
              <TicketChangeRequests chatId={c.id} disabled={c.archived} />
              {pending && selection && (
                <Divider testId="pending-switch">
                  {selection.auto
                    ? "Next message will pick its model automatically"
                    : `Next message will use ${modelLabel(groups, selection).harness} · ${modelLabel(groups, selection).model}`}
                </Divider>
              )}
              {effortPending && (
                <Divider testId="pending-effort">{`Next message will use ${effortLabel(effort).toLowerCase()} effort`}</Divider>
              )}
              {running && (
                <li className="flex flex-col gap-2" data-testid="thinking">
                  <InterimReply runId={c.current_run_id} since={since} persona={speaker} />
                  <VideoCards chatId={c.id} videos={liveVideos} onStop={stopping ? undefined : () => cancel.mutate()} />
                  <AudioCards chatId={c.id} audio={liveAudio} onStop={stopping ? undefined : () => cancel.mutate()} />
                  <div ref={statusRef} className="contents">
                  <ChatStatus chatId={c.id} disabled={c.archived} runId={c.current_run_id} since={since} persona={speaker} stopping={stopping} folded={docked} onOpenStep={openStep}
                    onAsk={locked || aside.isPending ? undefined : () => aside.mutate(QUIET_CHECK_IN)} onStop={stopping ? undefined : () => cancel.mutate()} />
                  </div>
                  <LiveAsides
                    asides={asidesInWindow(asideList, since)}
                    actions={{
                      onQueue: (question) => queue.mutate(question, { onSuccess: context?.onSent }),
                      onSteer: (question) => {
                        pinned.current = true;
                        send.mutate({ body: question }, { onSuccess: context?.onSent });
                      },
                      disabled: locked || queue.isPending,
                    }}
                  />
                </li>
              )}
              <li ref={end} aria-hidden />
            </ol>
            </MessageActionsContext.Provider>
            </OpenTurnStep.Provider>
            </OpenLinkedItem.Provider>
            </ReplyActions>
            </VideoPlayers.Provider>
            {!c.archived && <AskAboutSelection root={log} onAsk={askAboutSelection} />}
            {newReply && (
              <div className="sticky bottom-1 z-20 flex justify-center">
                <button type="button" onClick={followLatest} className="flex items-center gap-1.5 rounded-full border border-border-float bg-surface-raised px-3 py-1 text-12 font-medium text-fg shadow-[var(--shadow-float)] hover:bg-hover">
                  <Icon name="chev" size={12} />
                  New reply
                </button>
              </div>
            )}
            </>
          )}
        </div>
        <div className="mx-auto flex w-full max-w-[816px] flex-col gap-2 px-6 pb-3">
          {(() => {
            // Everything above the composer goes through one slot, ranked by STATUS_PRIORITY (lib/chat-status-slot).
            // The trays stay mounted while empty (present: false) so they see their first item arrive.
            const status: StatusItem[] = [];
            if (c.repo_url && (askCommitEmail || commitPickerOpen) && !c.archived) {
              status.push({
                key: "commit-email",
                kind: commitPickRequired ? "blocking" : "needs-you",
                label: "Commit email",
                pinned: commitPickerOpen,
                node: (
                  <CommitEmailPicker
                    emails={myEmails}
                    name={boot.data?.me.name ?? ""}
                    repo={c.repo_url}
                    value={askCommitEmail ? undefined : c.commit_email}
                    required={commitPickRequired}
                    disabled={setCommitEmail.isPending}
                    onPick={(email) => {
                      setCommitEmail.reset();
                      setCommitEmail.mutate({ id: c.id, email }, { onSuccess: () => setCommitPickerOpen(false) });
                    }}
                    onClose={() => setCommitPickerOpen(false)}
                  />
                ),
              });
            }
            if (unavailable && !c.archived) {
              status.push({
                key: "model-unavailable",
                kind: "blocking",
                label: `${unavailable.label} unavailable`,
                node: (
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
                ),
              });
            }
            if (!c.archived && workflowCard) {
              status.push({
                key: "workflow-start",
                kind: "needs-you",
                label: `Start ${workflowCard.name}`,
                node: <WorkflowStartCard workflow={workflowCard} chatId={c.id} onDone={closeWorkflow} onDismiss={closeWorkflow} />,
              });
            }
            if (c.state === "failed") {
              status.push({
                key: "failed-turn",
                kind: "failed-turn",
                label: "Last turn failed",
                node: (
                  <Banner
                    tone="blocked"
                    title="The last turn failed"
                    actions={
                      lastUser && (
                        <Button variant="outline" icon="refresh" disabled={locked || !!unavailable} onClick={() => submit(lastUser.body_md)}>
                          Retry
                        </Button>
                      )
                    }
                  >
                    {c.error ?? "No error details were recorded."}
                  </Banner>
                ),
              });
            }
            if (modeError) {
              status.push({
                key: "send-mode-error",
                kind: "error",
                label: "Couldn’t send",
                node: (
                  <p role="alert" data-testid="send-mode-error" className="text-13 text-pill-blocked-fg">
                    {modeError}
                  </p>
                ),
              });
            }
            if (actionError) {
              status.push({
                key: "action-error",
                kind: "error",
                label: "Something failed",
                node: (
                  <p role="alert" className="text-13 text-pill-blocked-fg">
                    {actionError instanceof ApiError && actionError.status === 409
                      ? `Can’t do that right now: ${actionError.message}`
                      : errorText(actionError)}
                  </p>
                ),
              });
            }
            if (!c.archived) {
              const needsYou = ticketRuns.some((r) => r.approval || r.state === "waiting" || r.state === "paused");
              status.push({
                key: "ticket-runs",
                present: ticketRuns.length > 0,
                kind: needsYou ? "needs-you" : "live",
                label: needsYou ? "Run needs you" : `${ticketRuns.length} ${ticketRuns.length === 1 ? "run" : "runs"} active`,
                node: <ChatTicketRunTray chatId={c.id} scene={(kind) => <ActivityScene current={kind} />} persona={<PersonaAvatar persona={persona} size={26} />} />,
              });
            }
            if (!c.archived) {
              const gate = workflowRuns.some((r) => r.state === "waiting");
              status.push({
                key: "workflow-runs",
                present: workflowRuns.length > 0,
                kind: gate ? "needs-you" : "live",
                label: gate ? "Workflow needs you" : `${workflowRuns.length} ${workflowRuns.length === 1 ? "workflow" : "workflows"} running`,
                node: <ChatWorkflowTray chatId={c.id} />,
              });
            }
            if (!c.archived) {
              status.push({
                key: "followups",
                present: followups.length > 0,
                kind: "live",
                label: `${followups.length} queued`,
                node: (
                  <FollowupTray
                    chatId={c.id}
                    name={speaker.name}
                    running={running}
                    held={!running && list?.at(-1)?.role !== "assistant"}
                    disabled={locked}
                    onSendNow={(body, done) => {
                      pinned.current = true;
                      send.mutate({ body }, { onSuccess: () => { context?.onSent(); done(); } });
                    }}
                    onEdit={(body) => {
                      setText((t) => (t.trim() ? `${body}\n\n${t}` : body));
                      setSendMode("followup");
                      area.current?.focus();
                    }}
                  />
                ),
              });
            }
            return <StatusSlot items={status} />;
          })()}
          {c.archived ? (
            <div className="flex items-center gap-3 rounded-lg border border-border bg-surface px-4 py-2.5">
              <p className="flex-1 text-13 text-fg-secondary">This chat is archived. Restore it to continue.</p>
              <RestoreChat chat={c} variant="primary" onRestored={restored} />
            </div>
          ) : (
            <>
            {context?.composer}
            <Composer
              sheetSignal={sheetSignal}
              text={text}
              onText={setText}
              inputRef={area}
              files={files}
              snippets={snippets}
              chips={chips}
              onChips={setChips}
              onSubmit={(body) => {
                const problem = running ? sendWhileRunning(sendMode, body) : submit(body);
                setModeError(problem || null);
              }}
              onCycle={running ? (back) => setSendMode((m) => cycleSendMode(m, back)) : undefined}
              hints={
                running
                  ? `Enter ${SEND_MODE_ENTER[sendMode]}  ·  Tab switches mode  ·  /aside  ·  /queue  ·  Shift+Enter for a new line`
                  : undefined
              }
              commands={{ plain: plainCommands, options: commandOptions,
              free: {
                ...Object.fromEntries(
                  (["aside", "queue"] as const).map((name) => [
                    name,
                    (body: string) => {
                      const mode = commandSendMode(name)!;
                      if (running) return sendWhileRunning(mode, body);
                      if (mode === "aside") return `Nothing is running, so there's nothing to ask about on the side: send it as a message.`;
                      submit(body);
                    },
                  ]),
                ),
                // The persona starts it with design_create, which opens it beside the chat.
                design: (brief: string) => (running ? sendWhileRunning("followup", designRequest(brief)) : submit(designRequest(brief))),
              },
              repository: (arg) => { if (!(c.speaker ?? c.persona)?.capabilities?.code) return "This persona cannot write code."; if (arg) selectRepo.mutate(arg); else setRepoSignal((n) => n + 1); }, hasWorkflows: published.length > 0 }}
              personas={personas.data?.personas ?? []}
              inChat={(personaId) => participants.some((x) => x.id === personaId)}
              create={c.archived ? undefined : { persona: speaker.name, onCreate: createWith }}
              disabled={locked}
              placeholder={
                locked
                  ? "Sending…"
                  : running
                    ? sendModePlaceholder(sendMode, c.speaker || c.persona ? speaker.name : "your assistant")
                    : `Message ${c.speaker || c.persona ? speaker.name : "your assistant"}${c.space ? ` in ${c.space.name}` : ""}…`
              }
              options={composerList}
              controls={{
                // The desktop header holds it; the compact + sheet lists it.
                repository: (compact || docked) && repoPicker,
                persona: <PersonaSwitcher value={c.persona?.id} onChange={switchPersona} disabled={locked || create.isPending} />,
                "send-mode": (
                  <SendModeSwitch
                    value={sendMode}
                    onChange={(m) => {
                      setSendMode(m);
                      setModeError(null);
                      area.current?.focus();
                    }}
                    disabled={locked}
                  />
                ),
                research: <ResearchToggle on={research} onChange={setResearch} disabled={locked} />,
                temporary: <TemporaryToggle on={!!c.temporary} onChange={switchTemporary} disabled={locked || create.isPending} />,
                model: selection && (
                  <ModelEffortPicker
                    groups={groups}
                    value={selection}
                    onChange={pick}
                    efforts={offered.efforts}
                    effort={effort}
                    onEffort={(e) => setPickedEffort(e ?? "default")}
                    disabled={locked || running}
                  />
                ),
                // The desktop composer leaves this to the header; the compact + sheet lists it too.
                project: compact && !c.space && <ChatProjectPicker chat={c} disabled={running} />,
              }}
              actions={
                running && (
                  <Button variant="outline" icon="pause" disabled={stopping} onClick={() => cancel.mutate()}>
                    {stopping ? "Stopping…" : "Stop"}
                  </Button>
                )
              }
              send={{
                label: running ? sendModeAction(sendMode) : research ? "Plan it" : "Send",
                disabled: locked || !!unavailable || files.pending || (!text.trim() && !snippets.items.length) || commitPickRequired || queue.isPending || aside.isPending,
                title: commitPickRequired ? "Pick which email commits use first" : running ? SEND_MODE_HINT[sendMode] : undefined,
                tone: running ? SEND_TONE[sendMode] : "accent",
              }}
            />
            </>
          )}
        </div>
        {current && (
          <HarnessSwitchDialog
            from={modelLabel(groups, current)}
            to={confirming && modelLabel(groups, confirming)}
            agent={c.agent.name || "The agent"}
            onCancel={() => setConfirming(null)}
            onClosed={() => area.current?.focus()}
            onConfirm={() => {
              setPicked(confirming);
              setConfirming(null);
            }}
          />
        )}
      </section>
    </Tooltip.Provider>
  );
}

/** The welcome of an empty chat in an app dock: who you're talking to on one line, then starters about where you are. */
function DockGreeting({ persona, tone, welcome, onPick, disabled }: { persona: PersonaLook; tone?: Schemas["PersonaTone"]; welcome: DockWelcome; onPick: (prompt: string) => void; disabled: boolean }) {
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center gap-2.5">
        <PersonaAvatar persona={persona} size={28} />
        <span className="min-w-0">
          <span className="block truncate text-14 font-semibold text-fg">{persona.id ? persona.name : "Your assistant"}</span>
          <span className="block truncate text-12 text-fg-tertiary">{welcome.where}{persona.id ? ` · ${toneLabel(tone)}` : ""}</span>
        </span>
      </div>
      <p className="text-13 text-fg-secondary">{welcome.intro}</p>
      {welcome.starters.length > 0 && (
        <div>
          <h3 className="mb-2 text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">{welcome.label}</h3>
          <ul aria-label="Conversation starters" className="flex flex-col gap-1.5">
            {welcome.starters.map((s) => (
              <li key={s.title}>
                <button
                  type="button"
                  disabled={disabled}
                  title={s.prompt}
                  onClick={() => onPick(s.prompt)}
                  className="flex w-full items-start gap-2.5 rounded-md border border-border bg-surface-raised p-2.5 text-left hover:bg-hover disabled:opacity-60"
                >
                  <Icon name={s.icon} size={15} className="mt-px flex-none text-fg-secondary" />
                  <span className="min-w-0">
                    <span className="block truncate text-13 font-medium text-fg">{s.title}</span>
                    <span className="line-clamp-2 block text-12 text-fg-secondary">{s.prompt}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
