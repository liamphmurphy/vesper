"use client";

import { useBacklinks, useChatMessages, useTicket, useWikiPage } from "@/lib/api/hooks";
import { usePage, type PageRow } from "@/lib/api/knowledge-hooks";
import type { Schemas } from "@/lib/api/client";
import { Icon, type IconName } from "@/components/ui/icon";
import { STATUS_LABEL } from "@/components/domain/glyphs";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { matchParts, plainExcerpt, type ChatMatch, type MessageMatch } from "@/lib/command-palette";

/** What the preview pane shows for the selected row. */
export type Preview =
  | { kind: "inbox"; item: Schemas["InboxItem"] }
  | { kind: "ticket"; key: string; title: string }
  | { kind: "page"; id: string; path: string; title: string; source?: "knowledge" | "wiki"; row?: PageRow }
  | { kind: "chat"; chat: ChatMatch }
  | { kind: "message"; chat: ChatMatch; message: MessageMatch }
  | { kind: "item"; label: string; title: string; detail?: string; at?: string };

/** The pane's buttons: the primary opens (↵); the second is ⌥↵ when the row has one. */
export type PreviewAction = { label: string; keys: string; run: () => void; tone?: "approve" };

const STATUS_TEXT: Record<string, string> = {
  in_progress: "text-state-progress",
  in_review: "text-state-review",
  done: "text-state-done",
  canceled: "text-fg-tertiary",
  backlog: "text-fg-tertiary",
  todo: "text-fg-secondary",
};

/** A ticket status's colour, for the row's right-hand label and the preview's pill. */
export function statusTone(status: string | undefined): string {
  return (status && STATUS_TEXT[status]) || "text-fg-tertiary";
}

export function statusLabel(status: string): string {
  return (STATUS_LABEL as Record<string, string>)[status]?.toLowerCase() ?? status.replaceAll("_", " ");
}

function Kind({ children, tone = "accent" }: { children: string; tone?: "accent" | "human" }) {
  return (
    <div className={cx("text-11 font-semibold uppercase tracking-wide", tone === "human" ? "text-state-human" : "text-accent")}>{children}</div>
  );
}

function Title({ children }: { children: string }) {
  return <h3 className="mt-1.5 line-clamp-2 text-18 font-bold leading-tight text-fg">{children}</h3>;
}

function Label({ children }: { children: string }) {
  return <div className="mb-2 text-11 font-semibold uppercase tracking-wide text-fg-tertiary">{children}</div>;
}

function Highlighted({ text, query }: { text: string; query: string }) {
  return (
    <>
      {matchParts(text, query).map((p, i) =>
        p.match ? (
          <strong key={i} className="font-bold text-fg">
            {p.text}
          </strong>
        ) : (
          <span key={i}>{p.text}</span>
        ),
      )}
    </>
  );
}

export function CommandPreview({ preview, query, actions }: { preview?: Preview; query: string; actions: PreviewAction[] }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden px-6 pb-5 pt-5" aria-live="polite">
      <div className="min-h-0 flex-1 overflow-y-auto">{preview ? <Body preview={preview} query={query} /> : null}</div>
      {actions.length > 0 && (
        <div className="flex flex-none flex-wrap items-center gap-2 pt-4">
          {actions.map((a, i) => (
            <button
              key={a.label}
              type="button"
              // The palette keeps focus in its input; a click shouldn't take it.
              onMouseDown={(e) => e.preventDefault()}
              onClick={a.run}
              className={cx(
                "inline-flex h-8 items-center gap-2 rounded-lg border px-4 text-13 transition-colors",
                i === 0
                  ? a.tone === "approve"
                    ? "border-state-human/60 bg-pill-human-bg font-semibold text-fg hover:brightness-110"
                    : "border-accent bg-accent-soft font-semibold text-fg hover:brightness-110"
                  : "border-border-strong text-fg-secondary hover:bg-hover",
              )}
            >
              {a.label}
              <span className="font-mono text-12 opacity-80">{a.keys}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function Body({ preview, query }: { preview: Preview; query: string }) {
  switch (preview.kind) {
    case "inbox":
      return <InboxPreview item={preview.item} />;
    case "ticket":
      return <TicketPreview ticketKey={preview.key} title={preview.title} query={query} />;
    case "page":
      return <PagePreview preview={preview} query={query} />;
    case "chat":
      return <ChatPreview chat={preview.chat} />;
    case "message":
      return <MessagePreview chat={preview.chat} message={preview.message} query={query} />;
    case "item":
      return (
        <>
          <Kind>{preview.label}</Kind>
          <Title>{preview.title}</Title>
          {(preview.detail || preview.at) && (
            <p className="mt-1.5 text-12 text-fg-secondary">{[preview.detail, preview.at && `changed ${ago(preview.at)}`].filter(Boolean).join(" · ")}</p>
          )}
        </>
      );
  }
}

function InboxPreview({ item }: { item: Schemas["InboxItem"] }) {
  const label = [item.kind.replaceAll("_", " "), item.ticket_key].filter(Boolean).join(" · ");
  return (
    <>
      <Kind tone={item.needs_you ? "human" : "accent"}>{label}</Kind>
      <Title>{item.title}</Title>
      <p className="mt-1.5 text-12 text-fg-secondary">
        {item.agent ? `${item.agent.name} asked ${ago(item.created_at)}` : `Waiting since ${ago(item.created_at)}`}
      </p>
      {item.summary &&
        (item.kind === "approval" ? (
          <pre className="mt-5 whitespace-pre-wrap rounded-lg border border-border bg-surface-sunken px-3.5 py-2.5 font-mono text-12 text-state-done">{item.summary}</pre>
        ) : (
          <p className="mt-5 text-13 leading-relaxed text-fg-secondary">{item.summary}</p>
        ))}
    </>
  );
}

function TicketPreview({ ticketKey, title, query }: { ticketKey: string; title: string; query: string }) {
  const t = useTicket(ticketKey).data;
  const facts = [t?.assignee?.name ?? (t ? "unassigned" : undefined), t?.epic?.name, t?.estimate_points != null ? `${t.estimate_points} pts` : undefined].filter(Boolean);
  const excerpt = t ? plainExcerpt(t.description_md, 280) : "";
  return (
    <>
      <Kind>{`Ticket · ${ticketKey}`}</Kind>
      <Title>{t?.title ?? title}</Title>
      {t && (
        <div className="mt-2.5 flex flex-wrap items-center gap-2 text-12 text-fg-secondary">
          <span className={cx("rounded-md bg-surface-sunken px-2 py-0.5 font-medium", statusTone(t.status))}>{statusLabel(t.status)}</span>
          {facts.join(" · ")}
        </div>
      )}
      {excerpt && (
        <p className="mt-4 line-clamp-5 text-13 leading-relaxed text-fg-secondary">
          <Highlighted text={excerpt} query={query} />
        </p>
      )}
      {t?.run && (
        <div className="mt-6">
          <Label>Last run</Label>
          <p className="flex items-center gap-1.5 text-13 text-fg-secondary">
            <Icon name="play" size={12} className={t.run.state === "failed" ? "text-state-blocked" : "text-state-progress"} />
            <span className="text-fg">{t.run.state.replaceAll("_", " ")}</span>
            <span className="text-fg-tertiary">· {t.run.agent.name}</span>
          </p>
        </div>
      )}
    </>
  );
}

const KIND_ICON: Partial<Record<string, IconName>> = { ticket: "tickets", artifact: "wiki", comment: "msg" };

const PAGE_KIND_LABEL: Record<string, string> = { deck: "Deck", design: "Design", document: "Page" };
const AUDIENCE_LABEL: Record<string, string> = { private: "Private", shared: "Shared", agent: "Agent" };

function PagePreview({ preview, query }: { preview: Extract<Preview, { kind: "page" }>; query: string }) {
  const isKnowledge = preview.source === "knowledge";
  const wiki = useWikiPage(isKnowledge ? "" : preview.path).data;
  const kpage = usePage(isKnowledge ? preview.id : undefined).data;
  const links = useBacklinks("artifact", preview.id).data?.linked ?? [];
  const folder = preview.path.includes("/") ? preview.path.slice(0, preview.path.lastIndexOf("/")) : "";
  const kind = kpage?.kind ?? preview.row?.kind;
  const kindLabel = (kind && PAGE_KIND_LABEL[kind]) ?? "Page";
  const audience = kpage?.audience ?? wiki?.audience ?? preview.row?.audience;
  const updatedAt = wiki?.updated_at ?? preview.row?.updated_at;
  const rawTags = wiki?.tags ?? (Array.isArray(kpage?.properties?.tags) ? kpage.properties.tags : Array.isArray(preview.row?.properties?.tags) ? preview.row.properties.tags : []);
  const tags = rawTags.filter((t): t is string => typeof t === "string");
  const facts = [
    audience ? AUDIENCE_LABEL[audience] : undefined,
    updatedAt ? `edited ${ago(updatedAt)}` : undefined,
    ...tags.slice(0, 3).map((t) => `#${t}`),
  ].filter(Boolean);
  const body = kpage?.body_md ?? wiki?.body_md ?? preview.row?.summary ?? "";
  const excerpt = body ? plainExcerpt(body, 360) : "";
  return (
    <>
      <Kind>{folder ? `${kindLabel} · ${folder}` : kindLabel}</Kind>
      <Title>{kpage?.title ?? wiki?.title ?? preview.title}</Title>
      {facts.length > 0 && <p className="mt-1.5 text-12 text-fg-secondary">{facts.join(" · ")}</p>}
      {excerpt && (
        <p className="mt-4 line-clamp-6 text-13 leading-relaxed text-fg-secondary">
          <Highlighted text={excerpt} query={query} />
        </p>
      )}
      {links.length > 0 && (
        <div className="mt-6">
          <Label>{`Linked from ${links.length}`}</Label>
          <ul className="flex flex-col gap-1.5">
            {links.slice(0, 4).map((m) => (
              <li key={`${m.source_kind}-${m.source_id}`} className="flex min-w-0 items-center gap-2 text-13 text-fg-secondary">
                <Icon name={KIND_ICON[m.source.kind] ?? "link"} size={13} className="flex-none text-fg-tertiary" />
                <span className="truncate">{m.source.display_id ?? m.source.path ?? m.source.title}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}

type Message = Schemas["ChatMessage"];

function Bubble({ m, focus, query }: { m: Message; focus?: boolean; query: string }) {
  const mine = m.role === "user";
  const who = mine ? "You" : (m.persona?.name ?? m.author?.name ?? "Assistant");
  const text = plainExcerpt(m.body_md, focus ? 320 : 160);
  return (
    <div className={cx("flex flex-col gap-1", mine && !focus && "items-end")}>
      <span className="text-11 font-semibold text-fg-secondary">
        {who} · {new Date(m.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
      </span>
      <div
        className={cx(
          "max-w-[90%] rounded-lg px-3 py-2 text-12 leading-relaxed",
          focus ? "w-full max-w-none border border-accent bg-accent-soft/40 text-fg" : mine ? "bg-surface-sunken text-fg-secondary" : "text-fg-secondary",
        )}
      >
        <span className={cx(focus ? "line-clamp-6" : "line-clamp-3")}>
          <Highlighted text={text} query={query} />
        </span>
      </div>
    </div>
  );
}

const said = (m: Message) => m.role === "user" || m.role === "assistant";

function ChatPreview({ chat }: { chat: ChatMatch }) {
  const messages = (useChatMessages(chat.id).data?.messages ?? []).filter(said);
  return (
    <>
      <Kind>{chat.persona ? `Chat · ${chat.persona}` : "Chat"}</Kind>
      <Title>{chat.title}</Title>
      {chat.at && <p className="mt-1.5 text-12 text-fg-secondary">Last message {ago(chat.at)}</p>}
      <div className="mt-5 flex flex-col gap-3">
        {messages.slice(-3).map((m) => (
          <Bubble key={m.id} m={m} query="" />
        ))}
      </div>
    </>
  );
}

/** The matching message with one turn either side, so it's clearly the right one before jumping. */
function MessagePreview({ chat, message, query }: { chat: ChatMatch; message: MessageMatch; query: string }) {
  // Far enough back to reach most hits; an older one falls back to its snippet.
  const messages = (useChatMessages(chat.id, 1000).data?.messages ?? []).filter(said);
  const i = messages.findIndex((m) => m.id === message.id);
  return (
    <>
      <Kind>{`Message · ${chat.title}`}</Kind>
      <div className="mt-4 flex flex-col gap-4">
        {i >= 0 ? (
          messages.slice(Math.max(0, i - 1), i + 2).map((m) => <Bubble key={m.id} m={m} focus={m.id === message.id} query={query} />)
        ) : (
          <p className="text-13 text-fg-secondary">{message.snippet.replace(/[«»]/g, "")}</p>
        )}
      </div>
    </>
  );
}
