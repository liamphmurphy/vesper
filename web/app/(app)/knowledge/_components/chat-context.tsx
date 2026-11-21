"use client";

import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from "react";

export type PageContext = { id: string; title: string; path: string | null };
export type PageAttachment = PageContext & { kind?: "page"; key: string; quote?: string };
/** A folder from the explorer: its path and the pages under it, so "these files" has something to point at. */
export type FolderAttachment = { kind: "folder"; key: string; path: string; pages: string[]; count: number };
export type Attachment = PageAttachment | FolderAttachment;
export type PromptDraft = { text: string; key: number };

export const isFolder = (a: Attachment): a is FolderAttachment => a.kind === "folder";

function useContextState() {
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [request, setRequest] = useState(0);
  const [prompt, setPrompt] = useState<PromptDraft | null>(null);
  const promptKey = useRef(0);
  // A page's header asks the dock to show one of its side panels (History from the edit-mode pill).
  const [panel, setPanel] = useState<{ tab: string; n: number }>({ tab: "", n: 0 });
  const openPanel = useCallback((tab: string) => setPanel((p) => ({ tab, n: p.n + 1 })), []);
  const handled = useRef(0);
  const drafts = useRef(new Map<string, () => string | undefined>());
  const ask = useCallback((page: PageContext, quote?: string) => {
    const attachment: PageAttachment = { id: page.id, title: page.title, path: page.path, quote, key: crypto.randomUUID() };
    setAttachments((old) => old.some((a) => !isFolder(a) && a.id === page.id && a.quote === quote) ? old : [...old, attachment]);
    setRequest((n) => n + 1);
  }, []);
  const askWithPrompt = useCallback((_page: PageContext, text: string) => {
    const nextKey = ++promptKey.current;
    setPrompt({ text, key: nextKey });
    setRequest((n) => n + 1);
  }, []);
  const consumePrompt = useCallback((key: number) => {
    setPrompt((cur) => (cur && cur.key <= key ? null : cur));
  }, []);
  const askFolder = useCallback((folder: { path: string; pages: string[]; count: number }) => {
    const attachment: FolderAttachment = { kind: "folder", key: crypto.randomUUID(), ...folder };
    setAttachments((old) => old.some((a) => isFolder(a) && a.path === folder.path) ? old : [...old, attachment]);
    setRequest((n) => n + 1);
  }, []);
  const remove = useCallback((keys: string[]) => setAttachments((old) => old.filter((a) => !keys.includes(a.key))), []);
  const registerDraft = useCallback((id: string, read: () => string | undefined) => {
    drafts.current.set(id, read);
    return () => { if (drafts.current.get(id) === read) drafts.current.delete(id); };
  }, []);
  const readDraft = useCallback((id: string) => drafts.current.get(id)?.(), []);
  const claimRequest = useCallback((n: number) => {
    if (n <= handled.current) return false;
    handled.current = n;
    return true;
  }, []);
  return useMemo(() => ({ attachments, request, prompt, ask, askWithPrompt, consumePrompt, askFolder, remove, registerDraft, readDraft, claimRequest, panel, openPanel }), [attachments, request, prompt, ask, askWithPrompt, consumePrompt, askFolder, remove, registerDraft, readDraft, claimRequest, panel, openPanel]);
}

const Context = createContext<ReturnType<typeof useContextState> | null>(null);

export function KnowledgeChatProvider({ children }: { children: ReactNode }) {
  return <Context.Provider value={useContextState()}>{children}</Context.Provider>;
}

export function useKnowledgeChat() {
  const value = useContext(Context);
  if (!value) throw new Error("useKnowledgeChat outside KnowledgeChatProvider");
  return value;
}
