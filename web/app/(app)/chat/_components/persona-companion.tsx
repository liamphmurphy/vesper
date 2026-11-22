"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { cx } from "@/lib/cx";
import { DOCK_HEIGHT_VAR } from "@/lib/dock-height";
import { useCompanionState, useRevealedText } from "@/lib/companion-store";
import type { StateMediaSummary } from "@/lib/persona-state-media";
import { PersonaStateStage } from "@/components/domain/persona-state-stage";
import { Button, IconButton } from "@/components/ui/button";
import { ChatMarkdown } from "./chat-markdown";
import type { PersonaLook } from "./persona";

// The persona companion: a chat's persona loop standing bottom-right above the composer,
// acting out the chat (idle, the turn's work, talking while a reply reveals). A click opens
// it large in the middle of the chat with a small composer beside it.

const hiddenKey = (personaId: string) => `vesper:companion-hidden:${personaId}`;
const hiddenListeners = new Set<() => void>();

/** Whether the person tucked a persona's companion away; remembered per persona. */
export function useCompanionHidden(personaId: string | undefined): [boolean, (hidden: boolean) => void] {
  const hidden = useSyncExternalStore(
    (l) => {
      hiddenListeners.add(l);
      return () => hiddenListeners.delete(l);
    },
    () => !!personaId && localStorage.getItem(hiddenKey(personaId)) === "1",
    () => false,
  );
  const set = (next: boolean) => {
    if (!personaId) return;
    if (next) localStorage.setItem(hiddenKey(personaId), "1");
    else localStorage.removeItem(hiddenKey(personaId));
    for (const l of hiddenListeners) l();
  };
  return [hidden, set];
}

/** Width of the docked companion; the transcript keeps this much clear on narrow windows. */
export const COMPANION_WIDTH = 140;

export function PersonaCompanion({
  chatId,
  persona,
  media,
  reply,
  disabled,
  onSend,
}: {
  chatId: string;
  persona: PersonaLook;
  media: StateMediaSummary;
  /** The latest reply, for the pop-out to show (revealing along with the transcript). */
  reply?: { id: string; body: string };
  disabled?: boolean;
  /** Sends like the main composer; a returned string is why it couldn't. */
  onSend: (body: string) => string | void;
}) {
  const state = useCompanionState(chatId);
  const [hidden, setHidden] = useCompanionHidden(persona.id);
  const [open, setOpen] = useState(false);
  const label = `${persona.name}, ${state.replace("_", " ")}`;

  if (hidden) {
    return (
      <button
        type="button"
        onClick={() => setHidden(false)}
        title={`Show ${persona.name}`}
        aria-label={`Show ${persona.name}`}
        style={{ bottom: `calc(var(${DOCK_HEIGHT_VAR}, 0px) + 8px)` }}
        className="absolute right-4 z-20 grid size-9 place-items-center overflow-hidden rounded-full border border-border bg-surface shadow-sm"
        data-testid="persona-companion-show"
      >
        {media.head_url ? <img src={media.head_url} alt="" className="size-full object-cover" /> : <span className="text-13 font-semibold">{persona.name.slice(0, 1)}</span>}
      </button>
    );
  }

  return (
    <>
      <div style={{ bottom: `calc(var(${DOCK_HEIGHT_VAR}, 0px) - 4px)` }} className="group/companion pointer-events-none absolute right-4 z-20 max-sm:hidden" data-testid="persona-companion" data-companion-state={state}>
        <button type="button" onClick={() => setOpen(true)} title={`Talk with ${persona.name}`} className="pointer-events-auto block cursor-pointer rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-accent">
          <PersonaStateStage media={media} state={state} width={COMPANION_WIDTH} label={label} />
        </button>
        <IconButton
          icon="x"
          label={`Hide ${persona.name}`}
          size={22}
          onClick={() => setHidden(true)}
          className="pointer-events-auto absolute right-0 top-0 bg-surface/80 opacity-0 shadow-sm transition-opacity group-hover/companion:opacity-100 focus-visible:opacity-100"
        />
      </div>
      {open && <CompanionPopOut chatId={chatId} persona={persona} media={media} state={state} label={label} reply={reply} disabled={disabled} onSend={onSend} onClose={() => setOpen(false)} />}
    </>
  );
}

function CompanionPopOut({
  chatId,
  persona,
  media,
  state,
  label,
  reply,
  disabled,
  onSend,
  onClose,
}: {
  chatId: string;
  persona: PersonaLook;
  media: StateMediaSummary;
  state: ReturnType<typeof useCompanionState>;
  label: string;
  reply?: { id: string; body: string };
  disabled?: boolean;
  onSend: (body: string) => string | void;
  onClose: () => void;
}) {
  const [text, setText] = useState("");
  const [error, setError] = useState<string>();
  const input = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    input.current?.focus();
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);

  function send() {
    const body = text.trim();
    if (!body || disabled) return;
    const problem = onSend(body);
    if (problem) setError(problem);
    else {
      setText("");
      setError(undefined);
    }
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Talking with ${persona.name}`}
      className="absolute inset-0 z-40 grid place-items-center bg-bg/80 p-6 backdrop-blur-sm motion-safe:animate-[scene-in_200ms_ease-out]"
      onMouseDown={(e) => e.target === e.currentTarget && onClose()}
      data-testid="persona-companion-popout"
    >
      <div className="flex max-h-full items-end gap-6 max-md:flex-col max-md:items-center">
        <PersonaStateStage media={media} state={state} width={240} label={label} />
        <div className="flex w-[min(380px,90vw)] flex-col gap-3 rounded-2xl border border-border bg-surface p-4 shadow-lg">
          <div className="flex items-center justify-between">
            <span style={{ color: persona.color }} className="text-14 font-semibold">{persona.name}</span>
            <IconButton icon="x" label="Close" size={24} onClick={onClose} />
          </div>
          {reply && <PopOutReply chatId={chatId} reply={reply} />}
          <textarea
            ref={input}
            aria-label={`Message ${persona.name}`}
            rows={3}
            value={text}
            disabled={disabled}
            placeholder={`Say something to ${persona.name}…`}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                send();
              }
            }}
            className="w-full resize-none rounded-lg border border-border-strong bg-bg p-2.5 text-14 text-fg focus:border-accent focus:outline-none"
          />
          {error && <p role="alert" className="text-13 text-pill-blocked-fg">{error}</p>}
          <div className="flex items-center justify-between">
            <span className="text-12 text-fg-tertiary">Enter to send · Shift+Enter for a new line · Esc to close</span>
            <Button variant="primary" disabled={disabled || !text.trim()} onClick={send}>Send</Button>
          </div>
        </div>
      </div>
    </div>
  );
}

/** The latest reply, revealing in step with the transcript, scrolled to its newest words. */
function PopOutReply({ chatId, reply }: { chatId: string; reply: { id: string; body: string } }) {
  const shown = useRevealedText(chatId, reply.id, reply.body);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (shown.revealing) box.current?.scrollTo({ top: box.current.scrollHeight });
  }, [shown.text, shown.revealing]);
  return (
    <div ref={box} className={cx("type-chat max-h-[min(320px,45vh)] overflow-y-auto text-fg-2")} data-testid="persona-companion-reply">
      <ChatMarkdown replyId={reply.id}>{shown.text}</ChatMarkdown>
    </div>
  );
}
