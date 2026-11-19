"use client";

import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { chatKeys, useChat, useChatAsides, useChatMessages, useSendChatMessage, useStartThread } from "@/lib/api/hooks";
import { Icon } from "@/components/ui/icon";
import { cx } from "@/lib/cx";
import { ChatMarkdown } from "./chat-markdown";
import { PersonaAvatar, PersonaName, personaLook } from "./persona";
import { composerInput, SendButton } from "./reply-tools";

const excerpt = (s: string) => (s.length > 280 ? `${s.slice(0, 280).trimEnd()}…` : s);

/**
 * A thread in the chat's dock, Slack-style: the message it's about, the side conversation under it,
 * and a box to reply in it. The first reply starts the thread (an aside anchored to the message);
 * the persona answers in a read-only session and the main conversation never sees it.
 */
export function ThreadPanel({ chatId, messageId, onClose, hideHeader }: { chatId: string; messageId: string; onClose: () => void; hideHeader?: boolean }) {
  const parent = useChatMessages(chatId).data?.messages.find((m) => m.id === messageId);
  // The newest thread about this message, if one was started (second opinions render inline in the transcript).
  const thread = useChatAsides(chatId).data?.findLast((a) => a.anchor_message_id === messageId && !a.second_opinion);
  const start = useStartThread(chatId);
  const [text, setText] = useState("");
  const box = useRef<HTMLTextAreaElement>(null);
  useEffect(() => box.current?.focus(), [messageId]);

  const host = useChat(chatId).data;
  // A reply without its own persona is the chat's host's (or speaker's).
  const author = parent?.persona ? personaLook(parent.persona) : parent?.role === "assistant" ? personaLook(host?.speaker ?? host?.persona) : undefined;
  const submit = (body: string) => {
    if (!body.trim()) return;
    setText("");
    if (!thread) start.mutate({ messageId, body }, { onError: () => setText(body) });
  };
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="thread-panel">
      {!hideHeader && (
        <div className="flex flex-none items-center gap-2 border-b border-border-subtle px-3 py-2">
          <Icon name="branch" size={14} className="text-fg-secondary" />
          <span className="flex-1 text-13 font-semibold text-fg">Thread</span>
          <button type="button" aria-label="Close thread" onClick={onClose} className="grid size-7 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg">
            <Icon name="x" size={13} />
          </button>
        </div>
      )}
      <div className="min-h-0 flex-1 overflow-y-auto px-3 py-3">
        <figure className="rounded-lg border border-border bg-surface p-3" data-testid="thread-anchor">
          <figcaption className="mb-1 flex items-center gap-1.5 text-12 text-fg-tertiary">
            {author ? <><PersonaAvatar persona={author} size={16} /><PersonaName persona={author} className="text-12" /></> : parent?.role === "user" ? "You" : "Message"}
          </figcaption>
          <blockquote className="whitespace-pre-wrap text-13 text-fg-secondary">{parent ? excerpt(parent.body_md) : "This message isn't loaded."}</blockquote>
        </figure>
        {thread ? (
          <ThreadMessages threadId={thread.id} />
        ) : (
          <p className="mt-4 text-center text-12 text-fg-tertiary">Ask about this message. The main conversation won’t see this thread.</p>
        )}
      </div>
      {thread ? (
        <ThreadReply threadId={thread.id} />
      ) : (
        <ReplyBox text={text} onText={setText} onSubmit={submit} pending={start.isPending} inputRef={box} error={start.error} placeholder="Ask about this message…" />
      )}
    </div>
  );
}

/** The thread's own conversation, kept current while it answers. */
function ThreadMessages({ threadId }: { threadId: string }) {
  const chat = useChat(threadId).data;
  const messages = useChatMessages(threadId).data?.messages ?? [];
  const qc = useQueryClient();
  // The thread's chat moves on as it answers; its messages follow.
  const revision = chat?.revision;
  useEffect(() => {
    if (revision !== undefined) void qc.invalidateQueries({ queryKey: chatKeys.messages(threadId) });
  }, [revision, threadId, qc]);
  const who = personaLook(chat?.speaker ?? chat?.persona);
  const running = chat?.state === "running";
  return (
    <ol className="mt-4 flex flex-col gap-4" aria-label="Thread" role="log" aria-live="polite">
      <li className="flex items-center gap-2 text-12 text-fg-tertiary">
        <span aria-hidden className="h-px flex-1 bg-border-subtle" />
        {messages.length} {messages.length === 1 ? "message" : "messages"}
        <span aria-hidden className="h-px flex-1 bg-border-subtle" />
      </li>
      {messages.filter((m) => m.role !== "system").map((m) =>
        m.role === "user" ? (
          <li key={m.id} className="self-end rounded-2xl bg-selected px-3 py-2 text-13 text-fg" data-testid="thread-user-message">{m.body_md}</li>
        ) : (
          <li key={m.id} className="flex flex-col gap-1" data-testid="thread-reply">
            <span className="flex items-center gap-1.5 text-12 text-fg-tertiary"><PersonaAvatar persona={who} size={16} /><PersonaName persona={who} className="text-12" /></span>
            <div className="type-chat text-13 text-fg-2"><ChatMarkdown>{m.body_md}</ChatMarkdown></div>
          </li>
        ),
      )}
      {running && (
        <li className="flex items-center gap-2 text-12" data-testid="thread-answering">
          <span className="dusk-aura flex-none"><PersonaAvatar persona={who} size={16} /></span>
          <span className="dusk-shimmer">{who.name} is answering…</span>
        </li>
      )}
    </ol>
  );
}

function ThreadReply({ threadId }: { threadId: string }) {
  const send = useSendChatMessage(threadId);
  const running = useChat(threadId).data?.state === "running";
  const [text, setText] = useState("");
  const box = useRef<HTMLTextAreaElement>(null);
  return (
    <ReplyBox
      text={text}
      onText={setText}
      inputRef={box}
      pending={send.isPending || running}
      error={send.error}
      placeholder={running ? "Wait for the answer…" : "Reply in thread…"}
      onSubmit={(body) => {
        setText("");
        send.mutate({ body }, { onError: () => setText(body) });
      }}
    />
  );
}

function ReplyBox({ text, onText, onSubmit, pending, inputRef, error, placeholder }: { text: string; onText: (t: string) => void; onSubmit: (body: string) => void; pending: boolean; inputRef: React.RefObject<HTMLTextAreaElement | null>; error: Error | null; placeholder: string }) {
  return (
    <form
      className="flex flex-none flex-col gap-1.5 border-t border-border-subtle p-3"
      onSubmit={(e) => {
        e.preventDefault();
        if (!pending) onSubmit(text);
      }}
    >
      {error && <p role="alert" className="text-12 text-pill-blocked-fg">{error.message}</p>}
      <div className={cx("flex items-end gap-2 rounded-xl border border-border bg-surface p-2 focus-within:border-accent")}>
        <textarea
          ref={inputRef}
          aria-label="Reply in thread"
          rows={1}
          value={text}
          placeholder={placeholder}
          onChange={(e) => onText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              if (!pending) onSubmit(text);
            }
          }}
          className={cx(composerInput, "min-h-[24px] flex-1")}
        />
        <SendButton label="Send in thread" disabled={pending || !text.trim()} />
      </div>
    </form>
  );
}
