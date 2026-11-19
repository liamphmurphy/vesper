"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { useCanvasActions, useCanvasComments, useChatCanvas } from "@/lib/api/canvas-hooks";
import { useDoc, useMarkDocReviewed } from "@/lib/api/docs-hooks";
import { useChat, useSendChatMessage } from "@/lib/api/hooks";
import type { Schemas } from "@/lib/api/client";
import { editorKeeps, locateQuote } from "@/lib/doc-markdown";
import { reviewBase, reviewSegments, splitBlocks } from "@/lib/doc-review";
import type { DockState } from "@/lib/editor-layout";
import { Button } from "@/components/ui/button";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { EditorLayout, type DockTab, type NativeEditorHeader } from "@/components/shell/editor-layout";
import { CanvasView, Rail, type Target } from "@/components/domain/canvas-view";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { toast } from "@/lib/toast";
import { buildDocActions, buildDocOutlineNav, parseHeadingId } from "@/lib/native-shell/models/doc-editor";
import { buildDocReviewInspector } from "@/lib/native-shell/models/doc-inspector";
import { navAvatar, pageOrigin } from "@/lib/native-shell/models/common";
import { presenceLabel } from "@/lib/native-shell/models/editor-header";
import { makePanelSpec } from "@/lib/native-shell/panel-events";
import { DocEditor, type DocEditorHandle, type Picked, type SaveState } from "./doc-editor";
import { DocReview, useDocReview } from "./doc-review";
import { useDocExports } from "./export-menu";

type Comment = Schemas["ChatCanvasComment"];

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** The document's headings, in order, as plain text with their level. */
function outlineOf(body: string): { level: number; text: string }[] {
  return splitBlocks(body).flatMap((b) => {
    const m = /^(#{1,6})\s+(.*)$/.exec(b.split("\n")[0]);
    return m ? [{ level: m[1].length, text: m[2].replace(/\s+#+\s*$/, "").replace(/[*_`~]|\[([^\]]*)\]\([^)]*\)/g, "$1").trim() }] : [];
  });
}

/**
 * A document full page, on the shared editor layout: you type on it, its
 * persona works on it with you from the dock's Chat tab, the persona's edits
 * come back as suggestions in place (listed in the Review tab), and comments
 * sit in the margin. The outline of headings is on the left, collapsed by default.
 */
export function DocScreen({ id }: { id: string }) {
  const doc = useDoc(id);
  const router = useRouter();
  const chatId = doc.data?.chat_id ?? "";
  const chat = useChat(chatId || undefined).data;
  const live = chat?.state === "running";
  const readOnly = !!chat?.archived;
  const persona = (chat?.speaker ?? chat?.persona)?.name ?? "Assistant";
  const look = personaLook(chat?.speaker ?? chat?.persona);
  const head = useChatCanvas(chatId, chatId ? id : undefined, undefined, live);
  const c = head.data;

  // The persona's versions since the person's last edit or review wait on
  // them. Nothing is decided mid-turn: the changes are still coming in.
  const base = c ? reviewBase(c.versions, doc.data?.reviewed_seq ?? 0) : 0;
  const reviewing = !!c && !live && base > 0 && c.seq > base;
  const before = useChatCanvas(chatId, reviewing ? id : undefined, base).data;
  const baseBody = reviewing && before?.viewing_seq === base ? before.body : undefined;
  const actions = useCanvasActions(chatId, id);
  const reviewed = useMarkDocReviewed(id);
  // Versions that changed nothing in the end need no decision.
  const empty = reviewing && baseBody !== undefined && c && !reviewSegments(baseBody, c.body).some((s) => s.kind === "change");
  useEffect(() => {
    if (empty && c && !reviewed.isPending) reviewed.mutate(c.seq);
  }, [empty, c, reviewed]);
  const review = useDocReview({
    base: baseBody,
    head: baseBody === undefined ? undefined : c?.body,
    persona,
    onAcceptAll: () => c && reviewed.mutate(c.seq),
    onResolve: (body, note) => c && actions.save.mutate({ base_seq: c.seq, body, note }),
  });
  const reviewBusy = readOnly || reviewed.isPending || actions.save.isPending;
  const reviewError = reviewed.error || actions.save.error ? errorText(reviewed.error ?? actions.save.error) : undefined;
  const suggesting = reviewing && baseBody !== undefined && !empty;

  const editable = useMemo(() => (c ? editorKeeps(c.body) : true), [c]);
  const outline = useMemo(() => (c ? outlineOf(c.body) : []), [c]);

  // The version the editor's text was last saved as; comments anchor to it.
  const saved = useRef<{ seq: number; body: string }>({ seq: 0, body: "" });
  useEffect(() => {
    if (c && c.seq > saved.current.seq) saved.current = { seq: c.seq, body: c.body };
  }, [c]);
  const editor = useRef<DocEditorHandle>(null);
  const page = useRef<HTMLDivElement>(null);
  const [saveState, setSaveState] = useState<{ s: SaveState; message?: string }>({ s: "saved" });

  // ---- The dock: asking the persona brings Chat up; suggestions arriving bring Review up.
  const [show, setShow] = useState({ tab: "chat", n: 0 });
  const showTab = (tab: string) => setShow((s) => ({ tab, n: s.n + 1 }));
  const [suggestionsShown, setSuggestionsShown] = useState(false);
  if (suggesting !== suggestionsShown) {
    setSuggestionsShown(suggesting);
    if (suggesting) setShow((s) => ({ tab: "review", n: s.n + 1 }));
  }
  const [dock, setDock] = useState<DockState>();
  const chatShowing = !dock || (dock.open && !dock.hidden && dock.tab === "chat");
  const lastReply = chat?.last_message_at;
  const [seenReply, setSeenReply] = useState<string>();
  // The reply that was there on load, or that arrived while Chat showed, counts as read.
  if (lastReply && seenReply !== lastReply && (chatShowing || seenReply === undefined)) setSeenReply(lastReply);
  const unread = !chatShowing && !!lastReply && !!seenReply && lastReply !== seenReply && !live;

  const send = useSendChatMessage(chatId);
  const [notice, setNotice] = useState<string>();
  const [target, setTarget] = useState<{ t: Extract<Target, { kind: "text" }>; seq: number } | null>(null);
  const [activeId, setActiveId] = useState<string>();
  const comments = useCanvasComments(chatId, chatId ? id : undefined, live).data?.comments;
  const { open, resolved, replies } = useMemo(() => {
    const replies = new Map<string, Comment[]>();
    const top: Comment[] = [];
    for (const x of comments ?? []) {
      if (x.parent_id) replies.set(x.parent_id, [...(replies.get(x.parent_id) ?? []), x]);
      else top.push(x);
    }
    return { open: top.filter((x) => x.status !== "resolved"), resolved: top.filter((x) => x.status === "resolved"), replies };
  }, [comments]);
  const highlights = useMemo(() => open.filter((x) => !x.target_lost && x.anchor.quote).map((x) => ({ quote: x.anchor.quote!, active: x.id === activeId })), [open, activeId]);

  const ask = async (body: string) => {
    showTab("chat");
    await send.mutateAsync({ body });
  };
  const flushed = async () => {
    await editor.current?.flush();
    return saved.current;
  };
  // A selection either opens a comment in the margin, or goes to the persona as one.
  const pick = async (p: Picked, message?: string) => {
    setNotice(undefined);
    try {
      const at = await flushed();
      const r = locateQuote(at.body, p.quote, p.at * at.body.length);
      if (!message) {
        if (r) setTarget({ t: { kind: "text", start: r.start, end: r.end, quote: p.quote.slice(0, 140) }, seq: at.seq });
        else setNotice("Couldn't place a comment on that selection. Try a shorter one.");
        return;
      }
      if (r) {
        const made = await actions.add.mutateAsync({ seq: at.seq, body: message, start: r.start, end: r.end });
        await actions.send.mutateAsync({ comment_ids: [made.id], message });
        showTab("chat");
      } else await ask(`${message}\n\nThe passage, in the document:\n> ${p.quote.replace(/\n/g, "\n> ")}`);
    } catch (e) {
      setNotice(errorText(e));
    }
  };
  const mention = async (instruction: string, after: string) => {
    setNotice(undefined);
    try {
      await flushed();
      const where = after ? `right after the passage “${after.length > 160 ? `${after.slice(0, 160)}…` : after}”` : "at the start";
      await ask(`${instruction}\n\n(Asked from inside the document, ${where}. Write it into the document there.)`);
    } catch (e) {
      setNotice(errorText(e));
    }
  };
  // Headings on the page whose text matches, in order; the nth such heading is the outline's nth of that text.
  const jumpTo = (i: number) => {
    const h = outline[i];
    const nth = outline.slice(0, i).filter((x) => x.text === h.text).length;
    const found = [...(page.current?.querySelectorAll("h1, h2, h3, h4, h5, h6") ?? [])].filter((el) => el.textContent?.trim() === h.text);
    found[nth]?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const title = c?.title ?? doc.data?.title ?? "Document";
  const showRail = !reviewing && editable && (open.length > 0 || resolved.length > 0 || !!target);

  const exports = useDocExports({ id, title, current: async () => (await flushed()).body });
  const exportNotice = exports.notice;
  useEffect(() => {
    if (!exportNotice) return;
    toast({ id: "doc-export", title: exportNotice.text, tone: exportNotice.tone === "error" ? "error" : "success", ...(exportNotice.href ? { action: { label: "Open", onClick: () => router.push(exportNotice.href!) } } : {}) });
  }, [exportNotice, router]);

  const header: NativeEditorHeader = {
    title,
    actions: buildDocActions({
      save: c ? { state: saveState.s, seq: c.seq } : undefined,
      presence: doc.data ? { label: presenceLabel(persona, live, reviewing), avatar: navAvatar(look.name, look.color, look.avatar_url, pageOrigin()) } : undefined,
      canShare: !!doc.data,
      pdf: exports.pdf,
      word: exports.word,
      markdown: exports.markdown,
      copy: exports.copy,
      saveToLibrary: exports.save,
      promote: exports.publish,
      libraryPending: exports.libraryPending,
      promotePending: exports.promotePending,
    }),
  };
  // The outline is always in the sidebar (the web's collapsible panel is for the page's narrow column).
  const nativeLeft = {
    model: buildDocOutlineNav({ outline }),
    onCommand: (cmd: { type: string; itemId?: string }) => {
      if (cmd.type !== "nav.activate" || !cmd.itemId) return;
      const i = parseHeadingId(cmd.itemId);
      if (i !== null && outline[i]) jumpTo(i);
    },
  };

  const failed = doc.isError || head.isError ? (
    <div className="mx-auto w-full max-w-[720px] p-6">
      <Banner tone="blocked" title="Couldn’t open this document">{errorText(doc.error ?? head.error)}</Banner>
    </div>
  ) : null;

  const main = !c ? (
    <div aria-busy="true" className="mx-auto flex w-full max-w-[820px] flex-col gap-3 p-6">
      <Skeleton className="h-7 w-1/2" />
      <Skeleton className="h-[320px]" />
    </div>
  ) : (
    <div data-testid="doc-page" className="relative flex min-h-0 min-w-0 flex-1">
      <div ref={page} className="min-h-0 min-w-0 flex-1 overflow-y-auto">
        {notice && (
          <p role="alert" className="mx-auto mt-3 max-w-[720px] px-8 text-12 text-pill-blocked-fg">
            {notice}
          </p>
        )}
        {saveState.s === "conflict" && (
          <div className="mx-auto mt-3 max-w-[720px] px-8">
            <Banner tone="blocked" title="This document changed while you were typing">
              <span className="flex flex-wrap items-center gap-2">
                Your last edits aren&apos;t saved yet.
                <Button variant="secondary" onClick={() => editor.current?.takeTheirs(c.seq, c.body)}>Use the latest version</Button>
                <Button variant="primary" onClick={() => void editor.current?.keepMine(c.seq)}>Keep mine</Button>
              </span>
            </Banner>
          </div>
        )}
        {reviewing ? (
          !suggesting ? (
            <div aria-busy="true" className="mx-auto max-w-[720px] p-8"><Skeleton className="h-[320px]" /></div>
          ) : (
            <DocReview review={review} busy={reviewBusy} error={reviewError} />
          )
        ) : editable ? (
          <DocEditor
            ref={editor}
            body={c.body}
            seq={c.seq}
            locked={live || readOnly}
            persona={persona}
            highlights={highlights}
            onSave={async (body, baseSeq) => {
              const v = await actions.save.mutateAsync({ base_seq: baseSeq, body, note: "Edited" });
              saved.current = { seq: v.seq, body };
              return v.seq;
            }}
            onState={(s, message) => setSaveState({ s, message })}
            onAsk={(instruction, after) => void mention(instruction, after)}
            onPick={(p, message) => void pick(p, message)}
          />
        ) : (
          <div className="flex min-h-full flex-col bg-surface-sunken">
            <p className="mx-auto mt-3 max-w-[720px] px-8 text-12 text-fg-tertiary">
              This document has HTML or footnotes the editor can&apos;t keep, so it opens as Markdown. Edit it under Edit.
            </p>
            <CanvasView chatId={chatId} canvasId={id} live={live} readOnly={readOnly} agent={persona} page />
          </div>
        )}
      </div>
      {showRail && (
        <Rail
          inline={false}
          threads={open}
          replies={replies}
          resolved={resolved}
          target={target?.t ?? null}
          activeId={activeId}
          setActive={setActiveId}
          agent={persona}
          readOnly={readOnly || live}
          actions={actions}
          seq={target?.seq ?? c.seq}
          onComposerDone={() => setTarget(null)}
          numberOf={(x) => [...open, ...resolved].findIndex((y) => y.id === x.id) + 1}
        />
      )}
    </div>
  );

  const docReviewInspector = useMemo(
    () =>
      suggesting
        ? buildDocReviewInspector({
            persona,
            segments: review.segments,
            changes: review.changes,
            decisions: review.decisions,
            left: review.left,
            busy: reviewBusy,
            error: reviewError,
          })
        : undefined,
    [suggesting, persona, review.segments, review.changes, review.decisions, review.left, reviewBusy, reviewError],
  );

  const dockTabs: DockTab[] = [
    {
      id: "chat",
      label: "Chat",
      icon: "msg",
      avatar: <PersonaAvatar persona={look} size={16} />,
      busy: live,
      unread,
      native: chatId
        ? {
            kind: "panel",
            panel: makePanelSpec("editor.chat", `doc.chat:${chatId}`, { tabId: "chat", chatId }),
          }
        : { kind: "native", sections: [], emptyText: "Loading chat…" },
    },
  ];
  if (suggesting)
    dockTabs.push({
      id: "review",
      label: "Review",
      icon: "check",
      badge: <span className="rounded-full bg-pill-review-bg px-1.5 text-11 text-pill-review-fg">{review.left}</span>,
      native: docReviewInspector
        ? {
            kind: "native",
            ...docReviewInspector,
            onAction: (actionId) => {
              if (actionId === "accept_all") review.everything("accept");
              else if (actionId === "reject_all") review.everything("reject");
              else if (actionId.startsWith("accept:")) review.decide(Number(actionId.slice(7)), "accept");
              else if (actionId.startsWith("reject:")) review.decide(Number(actionId.slice(7)), "reject");
              else if (actionId.startsWith("undo:")) review.undo(Number(actionId.slice(5)));
              else if (actionId.startsWith("jump:")) {
                document.getElementById(`doc-change-${actionId.slice(5)}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
              }
            },
          }
        : undefined,
    });

  return <EditorLayout app="docs" back={{ href: "/apps/docs", label: "Docs" }} header={header} nativeLeft={nativeLeft} main={failed ?? main} dock={dockTabs} show={show} onDockChange={setDock} />;
}
