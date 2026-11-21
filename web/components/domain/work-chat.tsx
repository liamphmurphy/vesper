"use client";

import { useCallback, useEffect, useState } from "react";
import { Conversation, type ConversationContext, type DockWelcome } from "@/app/(app)/chat/_components/conversation";
import { personaLook, useDockPersona } from "@/app/(app)/chat/_components/persona";
import { DockChatSwitcher } from "@/components/domain/dock-chat-switcher";
import { DockContext, dockContextChip } from "@/components/domain/dock-context";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { Icon } from "@/components/ui/icon";
import { useAddDockChat, useDockChats, type DockScope } from "@/lib/api/dock-hooks";
import { ApiError, type Schemas } from "@/lib/api/client";
import { useChat, useCreateChat } from "@/lib/api/hooks";
import { parsePin, sameSubject, withWorkContext, workSubjectLabel, type WorkSubject } from "@/lib/work-context";

/** One list of work chats, shared by every run and ticket, so the conversation follows you between them. */
const SCOPE: DockScope = "app:work";
/** The chat the panel opened last, in any run or ticket. */
const CURRENT_KEY = "vesper.work.chat";

/** The pin, kept across runs and tickets in this browser. */
const PIN_KEY = "vesper.work.pinned";

const subjectIcon = (s: WorkSubject) => (s.kind === "run" ? "play" : "tickets");
const chipButton = "grid size-4 flex-none place-items-center rounded-xs text-fg-tertiary hover:bg-hover hover:text-fg";

/**
 * Whom the next message goes to and what it carries: the persona, the item in the main pane, and
 * the item you pinned, which stays attached as you move between runs and tickets until you unpin it.
 */
function Chips({ persona, subject, pinned, onPin, className }: { persona?: string; subject?: WorkSubject; pinned?: WorkSubject; onPin: (s: WorkSubject | undefined) => void; className?: string }) {
  const viewingIsPinned = !!pinned && !!subject && sameSubject(pinned, subject);
  return (
    <DockContext persona={persona} label="Message context" className={className}>
      {pinned && (
        <span data-testid="work-chat-pinned" className={dockContextChip} title={`Pinned: ${workSubjectLabel(pinned)}`}>
          <Icon name="bookmark" size={12} className="flex-none text-accent" />
          <span className="min-w-0 truncate">Pinned: {workSubjectLabel(pinned)}</span>
          <button type="button" aria-label={`Unpin ${workSubjectLabel(pinned)}`} onClick={() => onPin(undefined)} className={chipButton}>
            <Icon name="x" size={11} />
          </button>
        </span>
      )}
      {subject && !viewingIsPinned && (
        <span data-testid="work-chat-subject" className={dockContextChip} title={workSubjectLabel(subject)}>
          <Icon name={subjectIcon(subject)} size={12} className="flex-none text-fg-tertiary" />
          <span className="min-w-0 truncate">Viewing: {workSubjectLabel(subject)}</span>
          <button type="button" aria-label={`Pin ${workSubjectLabel(subject)}`} title="Pin: keep it attached as you move to other runs and tickets" onClick={() => onPin(subject)} className={chipButton}>
            <Icon name="bookmark" size={11} />
          </button>
        </span>
      )}
    </DockContext>
  );
}

function welcomeFor(subject: WorkSubject | undefined): DockWelcome {
  // The companion beside a page with no run or ticket of its own: the same chat, about your work.
  if (!subject)
    return {
      where: "beside this page",
      intro: "One chat that follows you around Vesper. Pin a run or ticket from its page to keep it attached here.",
      label: "Your work",
      starters: [
        { icon: "check", title: "What did my agents finish?", prompt: "What did my agents finish since yesterday, and what's waiting on me?" },
        { icon: "search", title: "What needs me?", prompt: "What needs me right now, most urgent first?" },
      ],
    };
  const what = subject.kind === "run" ? "this run" : "this ticket";
  return {
    where: subject.kind === "run" ? "beside the run" : `beside ${subject.key}`,
    intro: `I can read ${what}, its ticket and its history, and talk it through with you. Replies to the agent go in the main pane.`,
    label: subject.kind === "run" ? "For this run" : "For this ticket",
    starters:
      subject.kind === "run"
        ? [
            { icon: "search", title: "What is it doing?", prompt: "Summarise what this run has done so far and what it's doing now." },
            { icon: "shield", title: "Is it safe to approve?", prompt: "Is it safe to approve what this run is asking for? What could go wrong?" },
            { icon: "check", title: "Check the criteria", prompt: "Which of this ticket's acceptance criteria has the run met, and which are still open?" },
          ]
        : [
            { icon: "search", title: "Where does it stand?", prompt: "Summarise where this ticket stands: its runs, what's done and what's left." },
            { icon: "edit", title: "Tighten the criteria", prompt: "Suggest clearer acceptance criteria for this ticket." },
          ],
  };
}

/**
 * The persona chat in the companion panel: beside a run or ticket, and beside every page with no
 * panel of its own. The dock always talks to your persona, while a run's own composer talks to its
 * agent. One chat follows you between pages; every message says which run or ticket was in view.
 */
export function WorkChat({ subject }: { subject?: WorkSubject }) {
  const [current, setCurrent] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
    setCurrent(window.localStorage.getItem(CURRENT_KEY));
    setLoaded(true);
  }, []);
  const [pinned, setPinned] = useState<WorkSubject>();
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
    setPinned(parsePin(window.localStorage.getItem(PIN_KEY)));
  }, []);
  const pin = useCallback((next: WorkSubject | undefined) => {
    setPinned(next);
    try {
      if (next) window.localStorage.setItem(PIN_KEY, JSON.stringify(next));
      else window.localStorage.removeItem(PIN_KEY);
    } catch {
      /* Pinned for this visit only. */
    }
  }, []);
  const remember = useCallback((id: string) => {
    window.localStorage.setItem(CURRENT_KEY, id);
    setCurrent(id);
  }, []);

  // A remembered chat can be gone (deleted, or an id from another instance): treat it as none.
  const remembered = useChat(current ?? undefined);
  const gone = remembered.error instanceof ApiError && remembered.error.status === 404;
  const id = gone ? undefined : (current ?? undefined);
  const chat = gone ? undefined : remembered.data;

  const list = useDockChats(SCOPE);
  const add = useAddDockChat();
  const create = useCreateChat();
  const select = (next: string) => {
    remember(next);
    add.mutate({ scope: SCOPE, chatId: next });
  };
  // A new work chat starts with the persona last used here, named in the empty state's To chip.
  const starting = useDockPersona(SCOPE);
  // The chat's own persona, not a guest who spoke last in a group chat.
  const openPersonaId = chat?.persona?.id;
  const rememberPersona = starting.remember;
  useEffect(() => rememberPersona(openPersonaId), [rememberPersona, openPersonaId]);
  const start = () => create.mutate({ title: "Work", hidden: true, ...(starting.id ? { persona_id: starting.id } : {}) }, { onSuccess: (c) => select(c.id) });
  const chats = list.data?.chats ?? [];
  const switcher = (
    <DockChatSwitcher
      current={chats.find((c) => c.id === id)}
      sections={[{ label: "Work chats", chats }]}
      newLabel="New chat"
      onSelect={(next) => { if (next !== id) select(next); }}
      onNew={start}
      creating={create.isPending}
      inline={!!id}
    />
  );

  // Named as the conversation names it: a chat with no persona of its own is the built-in Assistant.
  const persona = chat ? personaLook(chat.speaker ?? chat.persona).name : starting.look.name;
  const context: ConversationContext = {
    hidden: true,
    composer: <Chips persona={persona} subject={subject} pinned={pinned} onPin={pin} />,
    prepare: async (input: Schemas["NewChatMessage"]) => {
      const refs = [...(input.context_refs ?? [])];
      // The tickets of the pinned item and the one in view, so the persona can open either.
      for (const s of [pinned, subject]) {
        const key = !s ? undefined : s.kind === "ticket" ? s.key : s.ticketKey;
        if (key && !refs.some((r) => r.kind === "ticket" && r.key === key)) refs.push({ kind: "ticket", key });
      }
      return { ...input, body: withWorkContext(input.body, subject, pinned), ...(refs.length ? { context_refs: refs } : {}) };
    },
    prepareText: async (body) => withWorkContext(body, subject, pinned),
    onSent: () => {},
    welcome: welcomeFor(subject),
  };

  if (!loaded) return null;
  if (id)
    return (
      <div className="flex min-h-0 min-w-0 flex-1 flex-col" data-testid="work-chat">
        <Conversation key={id} id={id} docked hideTitle onNew={start} onReplace={async (next) => select(next)} context={context} actions={switcher} />
      </div>
    );
  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col" data-testid="work-chat">
      {chats.length > 0 && switcher}
      <div className="flex min-w-0 flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
        <Icon name="msg" size={22} className="text-fg-tertiary" />
        <Chips persona={persona} subject={subject} pinned={pinned} onPin={pin} className="justify-center" />
        <p className="text-13 text-fg-secondary">
          {subject
            ? `Talk it through with a persona. It can read the ${subject.kind} and its ticket; replies to the agent stay in the main pane.`
            : "Talk your work through with a persona: runs, tickets, what's waiting on you. The same chat follows you to every page."}
        </p>
        <Button variant="primary" disabled={create.isPending} onClick={start}>Start a chat</Button>
        {create.error && <p role="alert" className="text-12 text-state-blocked">{create.error.message}</p>}
      </div>
    </div>
  );
}

/** The work chat on a phone: a full-height sheet over the run or ticket, which has no side panel there. */
export function WorkChatSheet({ subject, open, onOpenChange }: { subject: WorkSubject; open: boolean; onOpenChange: (open: boolean) => void }) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange} title="Chat" className="h-[85dvh]">
      <div className="flex h-full min-h-0 flex-col">{open && <WorkChat subject={subject} />}</div>
    </Sheet>
  );
}
