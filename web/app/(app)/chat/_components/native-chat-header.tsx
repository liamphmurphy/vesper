"use client";

import { Dialog } from "radix-ui";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useUpdateChat } from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useChatPlayground, useCanStartSavedPlayground, usePlaygroundAction } from "@/lib/api/playground-hooks";
import { useRepositories } from "@/lib/api/repository-hooks";
import { canOpenWorkspaceFolder, openWorkspaceFolder } from "@/lib/desktop-bridge";
import { buildChatTitleMenu, buildChatToolbar, parseChatAction, parseTitleAction } from "@/lib/native-shell/chat-toolbar";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { inChatList, repoShortName, repositoryChoices, sameRepo } from "@/lib/persona-ui";
import { usePlaygroundPanel } from "@/lib/use-playground-panel";
import { toast } from "@/lib/toast";
import { Button } from "@/components/ui/button";
import { TextInput } from "@/components/ui/primitives";
import { useCanvasEntry } from "@/components/domain/canvas-view";
import { useChatLiveRuns } from "@/components/domain/dispatch-cards";
import { useChatSpace } from "./chat-space";
import { useOpenPersonaManager, type PersonaLook } from "./persona";
import { SecretsList, useChatSecrets } from "./secrets";

type Chat = Schemas["ChatSession"];

/**
 * The chat page's header in the Mac app. It draws no row: the persona, space, repository,
 * playground, canvas and runs go to the window's toolbar, and the title's menu (rename, workspace
 * folder, secrets, commit email) to the chevron beside the window title. What a menu opens that
 * can't be a menu item (rename, the secrets list, the repository search box) opens here, in a dialog
 * or in the web picker. Not rendered in a browser.
 */
export function NativeChatHeader({ chat: c, participants, fresh, running, personaDisabled, onSwitchPersona, repo, commitEmail, onCommitEmail, onRestored }: {
  chat: Chat;
  participants: PersonaLook[];
  fresh: boolean;
  running: boolean;
  personaDisabled: boolean;
  onSwitchPersona: (id: string) => void;
  /** Set when the persona can code; `picker` is the web's repository chip, kept (unseen) to open its search box. */
  repo?: { onPick: (url: string) => void; onSearch: () => void; disabled: boolean; personaRepos?: string[]; picker: ReactNode };
  commitEmail?: string;
  onCommitEmail: () => void;
  onRestored: () => void;
}) {
  const router = useRouter();
  const personas = usePersonas();
  const managePersonas = useOpenPersonaManager();
  const space = useChatSpace(c, running);
  const secrets = useChatSecrets(c.id);
  const saved = useRepositories();
  const update = useUpdateChat();
  const panel = usePlaygroundPanel();
  const pg = useChatPlayground(c.id).data;
  const canStart = useCanStartSavedPlayground(c.id);
  const playground = usePlaygroundAction(c.id);
  const canvas = useCanvasEntry(c.id, running);
  const runs = useChatLiveRuns(c.id);
  const [renaming, setRenaming] = useState(false);
  const [showSecrets, setShowSecrets] = useState(false);

  const repoChoices = useMemo(() => {
    if (!repo) return [];
    const ch = repositoryChoices(repo.personaRepos ?? [], saved.data ?? [], c.repo_url);
    return [...(ch.current ? [ch.current] : []), ...ch.persona, ...ch.saved];
  }, [repo, saved.data, c.repo_url]);

  const items = useMemo(
    () =>
      buildChatToolbar({
        origin: typeof window === "undefined" ? undefined : window.location.origin,
        archived: c.archived,
        participants: participants.length ? participants : [{ name: "Assistant", color: "" }],
        personas: inChatList(personas.data?.personas ?? [], c.persona?.id).map((p) => ({ id: p.id, name: p.name })),
        currentPersonaId: c.persona?.id,
        fresh,
        personaDisabled,
        space: { current: space.current ? { id: space.current.id, name: space.current.name } : undefined, spaces: space.spaces.map((s) => ({ id: s.id, name: s.name })), locked: space.locked },
        repo: repo ? { value: c.repo_url, pending: c.pending_repo_url, choices: repoChoices, shortName: repoShortName, same: sameRepo, disabled: repo.disabled } : undefined,
        playground: !pg && canStart
          ? { phase: "start", pending: playground.isPending }
          : pg
            ? { phase: "panel", state: pg.state as "running" | "starting" | "failed" | "stopped", open: panel.open }
            : undefined,
        canvasCount: canvas.count,
        runsActive: runs.length,
      }),
    [c.archived, c.persona?.id, c.repo_url, c.pending_repo_url, participants, personas.data, fresh, personaDisabled, space.current, space.spaces, space.locked, repo, repoChoices, pg, canStart, playground.isPending, panel.open, canvas.count, runs.length],
  );
  const titleMenu = useMemo(
    () =>
      buildChatTitleMenu({
        archived: c.archived,
        workspacePath: c.workspace_path ?? undefined,
        canOpenWorkspace: canOpenWorkspaceFolder(),
        secrets: secrets.any ? { label: secrets.label } : undefined,
        commitEmail,
        participants: participants.map((p) => p.name),
      }),
    [c.archived, c.workspace_path, secrets.any, secrets.label, commitEmail, participants],
  );

  // The toolbar's title is the chat's own title, as the web header shows it (not the page's "Chat").
  const titleToken = useRef(Symbol("chat-title"));
  const chatTitle = c.title?.trim() || "New chat";
  useEffect(() => {
    const token = titleToken.current;
    setTopBarTitle(token, { title: chatTitle });
    return () => setTopBarTitle(token, null);
  }, [chatTitle]);

  useNativeToolbar({
    items,
    onAction: (itemId, menuItemId) => {
      const a = parseChatAction(itemId, menuItemId);
      if (!a) return;
      switch (a.type) {
        case "persona":
          return a.id === c.persona?.id ? undefined : fresh ? onSwitchPersona(a.id) : router.push(`/chat?new&persona=${encodeURIComponent(a.id)}`);
        case "managePersonas":
          return managePersonas();
        case "space":
          return space.pick(a.id);
        case "repo":
          return repo?.onPick(a.url);
        case "searchRepos":
          return repo?.onSearch();
        case "playground":
          if (!pg && canStart) return playground.mutate("start", { onSuccess: panel.show, onError: (e) => toast({ title: e instanceof Error ? e.message : "Couldn’t start the playground.", tone: "error" }) });
          return panel.open ? panel.close() : panel.show();
        case "canvas":
          return canvas.go();
        case "runs":
          return router.push(runs.length === 1 ? `/runs/${runs[0].run_id}` : "/runs");
        case "restore":
          return void update.mutateAsync({ id: c.id, patch: { revision: c.revision, archived: false } }).then(onRestored, () => toast({ title: "Couldn’t restore the chat.", tone: "error" }));
      }
    },
    titleMenu,
    onTitleAction: (menuItemId) => {
      switch (parseTitleAction(menuItemId)) {
        case "rename":
          return setRenaming(true);
        case "copyWorkspace":
          return void navigator.clipboard?.writeText(c.workspace_path ?? "");
        case "openWorkspace":
          return void openWorkspaceFolder(c.workspace_path ?? "").then((error) => {
            if (error) toast({ title: error, tone: "error" });
          });
        case "secrets":
          return setShowSecrets(true);
        case "commitEmail":
          return onCommitEmail();
      }
    },
  });

  return (
    <>
      {/* The web's repository chip, unseen: "Search repos…" opens its name box, which anchors here. */}
      {repo && <span inert className="invisible fixed left-1/3 top-2 w-40">{repo.picker}</span>}
      <RenameDialog chat={c} open={renaming} onOpenChange={setRenaming} />
      <Dialog.Root open={showSecrets} onOpenChange={setShowSecrets}>
        <Dialog.Portal>
          <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
          <Dialog.Content aria-describedby={undefined} className="motion-dialog fixed left-1/2 top-[12vh] z-50 w-[min(420px,calc(100%-32px))] -translate-x-1/2 rounded-2xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none">
            <Dialog.Title className="sr-only">Secrets in this chat</Dialog.Title>
            <SecretsList chatId={c.id} secrets={secrets} />
            <div className="flex justify-end pt-2"><Dialog.Close asChild><Button variant="secondary">Done</Button></Dialog.Close></div>
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </>
  );
}

/** The title menu's Rename…: the web header's inline rename box, as a dialog. */
function RenameDialog({ chat: c, open, onOpenChange }: { chat: Chat; open: boolean; onOpenChange: (open: boolean) => void }) {
  const update = useUpdateChat();
  const [title, setTitle] = useState(c.title);
  function save(e: FormEvent) {
    e.preventDefault();
    const t = title.trim();
    if (!t || t === c.title) return onOpenChange(false);
    update.mutateAsync({ id: c.id, patch: { revision: c.revision, title: t } }).then(() => onOpenChange(false), () => undefined);
  }
  return (
    <Dialog.Root open={open} onOpenChange={(o) => { if (o) { setTitle(c.title); update.reset(); } onOpenChange(o); }}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content aria-describedby={undefined} className="motion-dialog fixed left-1/2 top-[16vh] z-50 w-[min(420px,calc(100%-32px))] -translate-x-1/2 rounded-2xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none">
          <form onSubmit={save} className="flex flex-col gap-3">
            <Dialog.Title className="text-16 font-semibold text-fg">Rename conversation</Dialog.Title>
            <TextInput aria-label="Conversation title" value={title} placeholder="New conversation" autoFocus onChange={(e) => setTitle(e.target.value)} />
            {update.isError && <p role="alert" className="text-12 text-pill-blocked-fg">Couldn’t rename. Try again.</p>}
            <div className="flex justify-end gap-2">
              <Dialog.Close asChild><Button variant="secondary" type="button">Cancel</Button></Dialog.Close>
              <Button variant="primary" type="submit" disabled={update.isPending}>Save</Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
