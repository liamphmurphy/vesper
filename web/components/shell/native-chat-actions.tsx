"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useDeleteChat, useUpdateChat } from "@/lib/api/hooks";
import { chatTitle } from "@/lib/chat-ui";
import { CHAT_MENU } from "@/lib/native-shell/chats-model";
import { toast } from "@/lib/toast";
import { Modal } from "@/app/(app)/knowledge/_components/kit";
import { Button } from "@/components/ui/button";
import { confirmAction } from "@/components/ui/confirm";

type Chat = Schemas["ChatSession"];
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** Rename as a dialog, for the native sidebar where a row can't turn into a text field. Saves as the web row does. */
function RenameChatDialog({ chat, pending, error, onCommit, onCancel }: { chat: Chat; pending: boolean; error?: string; onCommit: (title: string) => void; onCancel: () => void }) {
  const [title, setTitle] = useState(chat.title);
  const save = () => {
    const next = title.trim();
    if (!next || next === chat.title) return onCancel();
    onCommit(next);
  };
  return (
    <Modal open onOpenChange={(o) => !o && onCancel()} title={`Rename “${chatTitle(chat)}”`} className="top-[24vh] w-[min(440px,calc(100vw-32px))]">
      <div className="px-5 pt-3">
        <input
          autoFocus
          aria-label="Conversation title"
          value={title}
          placeholder="New conversation"
          disabled={pending}
          onFocus={(e) => e.currentTarget.select()}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && save()}
          className="h-8 w-full rounded-md border border-border-subtle bg-surface-sunken px-2.5 text-13 text-fg outline-none focus:border-accent"
        />
      </div>
      {error && <p role="alert" className="px-5 pt-2 text-12 text-pill-blocked-fg">{error}</p>}
      <div className="flex justify-end gap-2 px-5 pb-4 pt-3">
        <Button variant="ghost" onClick={onCancel}>Cancel</Button>
        <Button variant="primary" disabled={pending || !title.trim()} onClick={save}>{pending ? "Renaming…" : "Rename"}</Button>
      </div>
    </Modal>
  );
}

/**
 * The web chat row's actions (rename, archive, restore, delete) for the native sidebar's row menu,
 * with the same mutations and revision check. `find` looks a chat up by id in the lists on screen;
 * leaving the open chat (archive, delete) goes back to /chat, which resumes the newest one.
 */
export function useNativeChatActions(find: (id: string) => Chat | undefined, openChatId: string | null) {
  const router = useRouter();
  const update = useUpdateChat();
  const del = useDeleteChat();
  const [renaming, setRenaming] = useState<Chat | null>(null);
  const leave = (id: string) => id === openChatId && router.push("/chat");
  const fail = (title: string) => (e: unknown) => toast({ title, description: errorText(e), tone: "error" });

  const run = async (menuId: string, id: string) => {
    const chat = find(id);
    if (!chat) return;
    if (menuId === CHAT_MENU.rename) setRenaming(chat);
    else if (menuId === CHAT_MENU.archive) {
      // mutateAsync: the row unmounts when the list refetches.
      await update.mutateAsync({ id, patch: { revision: chat.revision, archived: true } }).then(() => leave(id), fail("Couldn’t archive"));
    } else if (menuId === CHAT_MENU.restore) {
      await update.mutateAsync({ id, patch: { revision: chat.revision, archived: false } }).then(() => undefined, fail("Couldn’t restore"));
    } else if (menuId === CHAT_MENU.delete) {
      const ok = await confirmAction({ title: `Delete “${chatTitle(chat)}”?`, body: "Delete this conversation? This can’t be undone.", confirmLabel: "Delete" });
      if (ok) await del.mutateAsync(id).then(() => leave(id), fail("Couldn’t delete"));
    }
  };
  const dialog = renaming && (
    <RenameChatDialog
      chat={renaming}
      pending={update.isPending}
      error={update.isError ? errorText(update.error) : undefined}
      onCancel={() => { update.reset(); setRenaming(null); }}
      onCommit={(title) => update.mutateAsync({ id: renaming.id, patch: { revision: renaming.revision, title } }).then(() => setRenaming(null), () => undefined)}
    />
  );
  return { run, dialog };
}
