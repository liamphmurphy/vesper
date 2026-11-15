"use client";

import { useEffect, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { Schemas } from "@/lib/api/client";
import { chatKeys, useCancelChat, useChatMessages, useChatModels, useSendChatMessage } from "@/lib/api/hooks";
import { asideCount } from "@/lib/send-mode";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";
import { ChatMarkdown } from "./chat-markdown";
import { modelLabel } from "./model-picker";
import { PersonaAvatar, personaLook } from "./persona";

type Aside = Schemas["ChatSession"];

/** What an aside's card can do with its question once answered. */
export type AsideActions = { onQueue: (question: string) => void; onSteer: (question: string) => void; disabled?: boolean };

/**
 * The asides asked during the running reply, under its status card and joined
 * to it by a rail: each answered by a side instance that saw the reply so far.
 */
export function LiveAsides({ asides, actions }: { asides: Aside[]; actions: AsideActions }) {
  const [hidden, setHidden] = useState<Set<string>>(() => new Set());
  const shown = asides.filter((a) => !hidden.has(a.id));
  if (shown.length === 0) return null;
  return (
    <AsideRail testId="live-asides">
      {shown.map((a) => (
        <AsideCard key={a.id} aside={a} live actions={actions} onHide={() => setHidden((h) => new Set(h).add(a.id))} />
      ))}
    </AsideRail>
  );
}

/** On a finished reply: its asides, folded into one chip, since they never became part of the conversation. */
export function ReplyAsides({ asides, name }: { asides: Aside[]; name: string }) {
  const [open, setOpen] = useState(false);
  if (asides.length === 0) return null;
  return (
    <div className="flex flex-col items-start gap-2" data-testid="reply-asides">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        className="inline-flex h-[26px] items-center gap-1.5 rounded-full border border-border px-2.5 text-12 text-fg-secondary hover:bg-hover hover:text-fg"
      >
        <Icon name="branch" size={12} />
        {asideCount(asides.length)} · not in {name}&rsquo;s context
        <Icon name="chev" size={11} className={cx("transition-transform", open && "rotate-180")} />
      </button>
      {open && (
        <AsideRail>
          {asides.map((a) => (
            <AsideCard key={a.id} aside={a} />
          ))}
        </AsideRail>
      )}
    </div>
  );
}

function AsideRail({ children, testId }: { children: ReactNode; testId?: string }) {
  return (
    <div data-testid={testId} className="relative ml-[22px] flex w-[calc(100%-22px)] max-w-[698px] flex-col gap-2.5 border-l-[1.5px] border-state-review/35 pl-4">
      {children}
    </div>
  );
}

function AsideCard({ aside, live, actions, onHide }: { aside: Aside; live?: boolean; actions?: AsideActions; onHide?: () => void }) {
  // The persona that was answering the chat when the aside was asked.
  const persona = personaLook(aside.persona);
  const qc = useQueryClient();
  const messages = useChatMessages(aside.id);
  const stop = useCancelChat(aside.id);
  // Refetch as the aside moves on, also without the realtime connection.
  const stamp = `${aside.state}:${aside.message_count}`;
  useEffect(() => {
    void qc.invalidateQueries({ queryKey: chatKeys.messages(aside.id) });
  }, [stamp, aside.id, qc]);
  const list = messages.data?.messages ?? [];
  const question = list.find((m) => m.role === "user")?.body_md ?? aside.title.replace(/^Aside: /, "");
  const answer = list.findLast((m) => m.role === "assistant");
  const failure = aside.state === "failed" ? (list.findLast((m) => m.role === "system")?.body_md ?? aside.error ?? "The aside couldn’t answer.") : null;
  const answering = aside.state === "running";
  return (
    <article
      aria-label={`Aside: ${question}`}
      data-testid="aside"
      className="relative flex flex-col gap-2 rounded-xl border border-state-review/25 bg-surface px-3 py-2.5 before:absolute before:-left-[17px] before:top-[18px] before:w-4 before:border-t-[1.5px] before:border-state-review/35"
    >
      <header className="flex items-center gap-2 text-12 text-fg-tertiary">
        <PersonaAvatar persona={persona} size={20} />
        <span className="text-13 font-medium text-pill-review-fg">{persona.name}</span>
        <span className="rounded-xs bg-pill-review-bg px-1.5 py-0.5 text-10 font-semibold uppercase tracking-[0.06em] text-pill-review-fg">Aside</span>
        <span className="min-w-0 truncate">{live ? "sees the live reply · read-only" : "asked during this reply"}</span>
        {live && answering && (
          <button type="button" disabled={stop.isPending} onClick={() => stop.mutate()} className="ml-auto rounded-md px-1.5 py-0.5 hover:bg-hover hover:text-fg disabled:opacity-50">
            Stop
          </button>
        )}
        {live && !answering && onHide && (
          <button type="button" aria-label="Hide aside" onClick={onHide} className="ml-auto grid size-5 place-items-center rounded-md hover:bg-hover hover:text-fg">
            <Icon name="x" size={11} />
          </button>
        )}
      </header>
      <p className="max-w-[90%] self-end whitespace-pre-wrap rounded-xl bg-selected px-3 py-1.5 text-14 text-fg">{question}</p>
      {answer ? (
        <div className="type-chat text-14 leading-[1.55] text-fg-2">
          <ChatMarkdown>{answer.body_md}</ChatMarkdown>
        </div>
      ) : failure ? (
        <p role="alert" className="text-13 text-pill-blocked-fg">{failure}</p>
      ) : answering ? (
        <p role="status" className="text-shimmer text-13">Reading the live reply: its steps, tool output and what it has written…</p>
      ) : (
        <p className="text-13 text-fg-tertiary">Stopped before answering.</p>
      )}
      {live && answer && actions && (
        <div className="flex flex-wrap gap-1.5">
          <button type="button" disabled={actions.disabled} onClick={() => actions.onQueue(question)} className={ACTION}>
            <Icon name="clock" size={12} />
            Queue as follow-up
          </button>
          <button type="button" disabled={actions.disabled} onClick={() => actions.onSteer(question)} className={ACTION}>
            <Icon name="bolt" size={12} />
            Steer with this
          </button>
        </div>
      )}
    </article>
  );
}

const ACTION =
  "inline-flex h-[26px] items-center gap-1.5 rounded-md border border-border-strong px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg disabled:cursor-not-allowed disabled:opacity-50";

const DEFAULT_COMPARE_RE = /^(Review the latest reply and code changes|Give a concise second opinion)/i;

/** Inline cross-harness critiques anchored to a message (or shown inside CodePanel). */
export function SecondOpinions({
  asides,
  speakerName,
  onQuote,
  compact,
}: {
  asides: Aside[];
  speakerName: string;
  onQuote?: (quote: { text: string; modelLabel: string }) => void;
  compact?: boolean;
}) {
  if (asides.length === 0) return null;
  const cards = asides.map((a) => (
    <SecondOpinionCard key={a.id} aside={a} speakerName={speakerName} onQuote={onQuote} compact={compact} />
  ));
  if (compact) {
    return (
      <div data-testid="second-opinions" className="flex flex-col gap-2">
        {cards}
      </div>
    );
  }
  return <AsideRail testId="second-opinions">{cards}</AsideRail>;
}

function SecondOpinionCard({
  aside,
  speakerName,
  onQuote,
  compact,
}: {
  aside: Aside;
  speakerName: string;
  onQuote?: (quote: { text: string; modelLabel: string }) => void;
  compact?: boolean;
}) {
  const qc = useQueryClient();
  const models = useChatModels();
  const messages = useChatMessages(aside.id);
  const stop = useCancelChat(aside.id);
  const sendFollowup = useSendChatMessage(aside.id);
  const [followupOpen, setFollowupOpen] = useState(false);
  const [followup, setFollowup] = useState("");
  const [followupError, setFollowupError] = useState<string | null>(null);

  const stamp = `${aside.state}:${aside.message_count}`;
  useEffect(() => {
    void qc.invalidateQueries({ queryKey: chatKeys.messages(aside.id) });
  }, [stamp, aside.id, qc]);

  const labels = modelLabel(models.data, { harness: aside.harness, model: aside.model });
  const fullModelLabel = `${labels.harness} · ${labels.model}`;
  const list = messages.data?.messages ?? [];
  const firstUser = list.find((m) => m.role === "user");
  const answers = list.filter((m) => m.role === "assistant");
  const latestAnswer = answers.at(-1);
  const failure = aside.state === "failed" ? (list.findLast((m) => m.role === "system")?.body_md ?? aside.error ?? "The second opinion couldn’t answer.") : null;
  const answering = aside.state === "running";
  const hasVisibleTurns = list.some((m) => m.role === "assistant" || (m.role === "user" && (m !== firstUser || !DEFAULT_COMPARE_RE.test(m.body_md.trim()))));

  const submitFollowup = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = followup.trim();
    if (!trimmed || sendFollowup.isPending) return;
    setFollowupError(null);
    sendFollowup.mutate(
      { body: trimmed },
      {
        onSuccess: () => {
          setFollowup("");
          setFollowupOpen(false);
        },
        onError: (err) => setFollowupError(err instanceof Error ? err.message : "Could not send follow-up."),
      },
    );
  };

  return (
    <article
      aria-label={`Second opinion from ${fullModelLabel}`}
      data-testid="second-opinion-card"
      className={cx(
        "relative flex flex-col gap-2 rounded-xl border border-state-review/30 bg-surface px-3 py-2.5",
        !compact && "before:absolute before:-left-[17px] before:top-[18px] before:w-4 before:border-t-[1.5px] before:border-state-review/35",
      )}
    >
      <header className="flex flex-wrap items-center gap-2 text-12 text-fg-tertiary">
        <span className="inline-flex items-center gap-1 rounded-xs bg-pill-review-bg px-1.5 py-0.5 text-10 font-semibold uppercase tracking-[0.06em] text-pill-review-fg">
          <Icon name="compare" size={11} />
          Second opinion
        </span>
        <span data-testid="second-opinion-model" className="text-13 font-medium text-fg">
          {fullModelLabel}
        </span>
        <span className="min-w-0 truncate">read-only · cache untouched</span>
        {answering && (
          <button
            type="button"
            disabled={stop.isPending}
            onClick={() => stop.mutate()}
            className="ml-auto rounded-md px-1.5 py-0.5 hover:bg-hover hover:text-fg disabled:opacity-50"
          >
            Stop
          </button>
        )}
      </header>

      {!hasVisibleTurns && !answering && !failure && (
        <p className="text-12 text-fg-tertiary">Stopped before answering.</p>
      )}

      <div className="flex flex-col gap-2">
        {list.map((m) => {
          if (m.role === "user") {
            if (m === firstUser && DEFAULT_COMPARE_RE.test(m.body_md.trim())) {
              return (
                <p key={m.id} className="text-12 text-fg-tertiary">
                  Reviewing anchored snapshot and diff
                </p>
              );
            }
            return (
              <p key={m.id} className="max-w-[90%] self-end whitespace-pre-wrap rounded-xl bg-selected px-3 py-1.5 text-13 text-fg">
                {m.body_md}
              </p>
            );
          }
          if (m.role === "assistant") {
            return (
              <div key={m.id} className="type-chat text-14 leading-[1.55] text-fg-2">
                <ChatMarkdown>{m.body_md}</ChatMarkdown>
              </div>
            );
          }
          return null;
        })}
      </div>

      {failure && (
        <p role="alert" className="text-13 text-pill-blocked-fg">
          {failure}
        </p>
      )}
      {answering && (
        <p role="status" className="text-shimmer text-13">
          Reviewing snapshot and diff with {labels.model}…
        </p>
      )}

      {latestAnswer && !answering && (
        <div className="flex flex-wrap items-center gap-1.5 pt-0.5">
          {onQuote && (
            <button
              type="button"
              data-testid="second-opinion-quote"
              onClick={() => onQuote({ text: latestAnswer.body_md, modelLabel: fullModelLabel })}
              className={ACTION}
            >
              <Icon name="msg" size={12} />
              Quote to {speakerName}
            </button>
          )}
          <button
            type="button"
            data-testid="second-opinion-followup-toggle"
            aria-expanded={followupOpen}
            onClick={() => setFollowupOpen((o) => !o)}
            className={ACTION}
          >
            <Icon name="branch" size={12} />
            Ask follow-up
          </button>
        </div>
      )}

      {followupOpen && !answering && (
        <form onSubmit={submitFollowup} className="flex flex-col gap-1.5 pt-1">
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              value={followup}
              onChange={(e) => setFollowup(e.target.value)}
              aria-label="Ask follow-up to second opinion"
              data-testid="second-opinion-followup-input"
              placeholder={`Ask ${labels.model} a follow-up…`}
              disabled={sendFollowup.isPending}
              className="h-8 min-w-0 flex-1 rounded-md border border-border bg-surface-raised px-2.5 text-13 text-fg placeholder:text-fg-tertiary focus:border-accent focus:outline-none disabled:opacity-50"
            />
            <button
              type="submit"
              data-testid="second-opinion-followup-send"
              disabled={!followup.trim() || sendFollowup.isPending}
              className="inline-flex h-8 items-center rounded-md bg-accent px-3 text-12 font-medium text-accent-fg hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Send
            </button>
          </div>
          {followupError && (
            <p role="alert" className="text-12 text-pill-blocked-fg">
              {followupError}
            </p>
          )}
        </form>
      )}
    </article>
  );
}
