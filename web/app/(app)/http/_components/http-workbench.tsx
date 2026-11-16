"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { useClaimCompanion } from "@/components/shell/companion";
import { Button } from "@/components/ui/button";
import { confirmAction } from "@/components/ui/confirm";
import { CopyButton } from "@/components/ui/copy-button";
import { Icon } from "@/components/ui/icon";
import { EmptyState, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { toast } from "@/components/ui/toast";
import { cx } from "@/lib/cx";
import {
  useCreateHttpFolder,
  useCreateHttpRequest,
  useCreateHttpWorkspace,
  useDeleteHttpFolder,
  useDeleteHttpRequest,
  useDeleteHttpWorkspace,
  useHttpRequestExecutions,
  useHttpWorkspaceBundle,
  useHttpWorkspaces,
  useRunHttpRequest,
  useSetHttpActiveEnvironment,
  useUpdateHttpRequest,
  type AuthConfig,
  type BodyMode,
  type HttpExecution,
  type HttpFolder,
  type HttpRequest,
  type HttpWorkspaceBundle,
  type RequestDraftInput,
} from "@/lib/api/http-client-hooks";
import { AuthEditor, describeAuth } from "./auth-editor";
import { AuthEnvView, ENV_DOT } from "./auth-env-view";
import { ImportDialog, type ImportTab } from "./import-dialog";
import { KVEditor } from "./kv-editor";
import { TreeMenu, type TreeMenuEntry } from "./tree-menu";

const METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] as const;

const METHOD_COLOR: Record<string, string> = {
  GET: "text-state-done",
  POST: "text-accent",
  PUT: "text-state-human",
  PATCH: "text-state-human",
  DELETE: "text-state-blocked",
  HEAD: "text-fg-secondary",
  OPTIONS: "text-fg-secondary",
};

const STORAGE_WS_KEY = "vesper.http.workspace";

type ReqTab = "params" | "headers" | "auth" | "body" | "settings";
type RespTab = "body" | "headers" | "request" | "history";

function toDraft(r: HttpRequest): RequestDraftInput {
  return {
    folder_id: r.folder_id,
    name: r.name,
    method: r.method,
    url: r.url,
    params: r.params,
    headers: r.headers,
    auth: r.auth,
    body_mode: r.body_mode,
    body: r.body,
    body_form: r.body_form,
    timeout_ms: r.timeout_ms,
    follow_redirects: r.follow_redirects,
  };
}

function resolveInheritedSource(bundle: HttpWorkspaceBundle, folderId: string | null): { label: string; auth: AuthConfig } {
  const byId = new Map(bundle.folders.map((f) => [f.id, f]));
  const chain: HttpFolder[] = [];
  let cur = folderId;
  const seen = new Set<string>();
  while (cur && !seen.has(cur)) {
    seen.add(cur);
    const f = byId.get(cur);
    if (!f) break;
    chain.push(f);
    cur = f.parent_folder_id;
  }
  for (const f of chain) {
    if (f.default_auth.type && f.default_auth.type !== "inherit") {
      return { label: `Folder "${f.name}" (${describeAuth(f.default_auth)})`, auth: f.default_auth };
    }
  }
  return {
    label: `Workspace "${bundle.workspace.name}" (${describeAuth(bundle.workspace.default_auth)})`,
    auth: bundle.workspace.default_auth,
  };
}

function formatBodyPreview(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      return JSON.stringify(JSON.parse(trimmed), null, 2);
    } catch {
      return raw;
    }
  }
  return raw;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function subscribeStorage(cb: () => void) {
  window.addEventListener("storage", cb);
  return () => window.removeEventListener("storage", cb);
}

function readStoredWorkspaceId(): string | null {
  return typeof window !== "undefined" ? window.localStorage.getItem(STORAGE_WS_KEY) : null;
}

export function HttpWorkbench() {
  useClaimCompanion();
  const router = useRouter();

  const workspacesQuery = useHttpWorkspaces();
  const workspaces = useMemo(() => workspacesQuery.data ?? [], [workspacesQuery.data]);
  const storedWsId = useSyncExternalStore(subscribeStorage, readStoredWorkspaceId, () => null);

  const [selectedWsId, setSelectedWsId] = useState<string | null>(null);
  const effectiveWsId = useMemo(
    () =>
      workspaces.find((w) => w.id === selectedWsId)?.id ??
      workspaces.find((w) => w.id === storedWsId)?.id ??
      workspaces[0]?.id ??
      null,
    [workspaces, selectedWsId, storedWsId],
  );

  useEffect(() => {
    if (effectiveWsId && typeof window !== "undefined") {
      window.localStorage.setItem(STORAGE_WS_KEY, effectiveWsId);
    }
  }, [effectiveWsId]);

  const bundleQuery = useHttpWorkspaceBundle(effectiveWsId);
  const bundle = bundleQuery.data ?? null;

  const createWorkspace = useCreateHttpWorkspace();
  const deleteWorkspace = useDeleteHttpWorkspace();
  const setActiveEnv = useSetHttpActiveEnvironment();
  const createFolder = useCreateHttpFolder(effectiveWsId);
  const deleteFolder = useDeleteHttpFolder(effectiveWsId);
  const createRequest = useCreateHttpRequest(effectiveWsId);
  const updateRequest = useUpdateHttpRequest(effectiveWsId);
  const deleteRequest = useDeleteHttpRequest(effectiveWsId);
  const runRequest = useRunHttpRequest();

  const [viewMode, setViewMode] = useState<"requests" | "auth-env">("requests");
  const [showImport, setShowImport] = useState<{ folder: HttpFolder | null; tab: ImportTab } | null>(null);
  const [newWsOpen, setNewWsOpen] = useState(false);
  const [newWsName, setNewWsName] = useState("");
  const [newFolderOpen, setNewFolderOpen] = useState(false);
  const [newFolderName, setNewFolderName] = useState("");
  const [filter, setFilter] = useState("");
  const [collapsedFolders, setCollapsedFolders] = useState<Record<string, boolean>>({});
  const [selectedFolderId, setSelectedFolderId] = useState<string | null>(null);
  const [selectedReqId, setSelectedReqId] = useState<string | null>(null);
  const [draftState, setDraftState] = useState<{ reqId: string; draft: RequestDraftInput; dirty: boolean } | null>(null);
  const [reqTab, setReqTab] = useState<ReqTab>("params");
  const [respTab, setRespTab] = useState<RespTab>("body");
  const [latestExecution, setLatestExecution] = useState<{ reqId: string; exec: HttpExecution } | null>(null);

  const selectedRequest = useMemo(
    () => bundle?.requests.find((r) => r.id === selectedReqId) ?? bundle?.requests[0] ?? null,
    [bundle, selectedReqId],
  );
  const selectedFolder = useMemo(
    () => bundle?.folders.find((f) => f.id === selectedFolderId) ?? null,
    [bundle, selectedFolderId],
  );

  const draft = useMemo(
    () =>
      selectedRequest
        ? draftState && draftState.reqId === selectedRequest.id
          ? draftState.draft
          : toDraft(selectedRequest)
        : null,
    [selectedRequest, draftState],
  );
  const dirty = Boolean(selectedRequest && draftState && draftState.reqId === selectedRequest.id && draftState.dirty);

  const activeReqId = selectedRequest?.id ?? null;
  const execHistoryQuery = useHttpRequestExecutions(activeReqId);
  const activeExecution =
    (activeReqId && latestExecution?.reqId === activeReqId ? latestExecution.exec : null) ??
    execHistoryQuery.data?.[0] ??
    null;

  const selectRequest = (r: HttpRequest) => {
    setViewMode("requests");
    setSelectedReqId(r.id);
    setSelectedFolderId(r.folder_id);
    setDraftState({ reqId: r.id, draft: toDraft(r), dirty: false });
    setLatestExecution(null);
  };

  const patchDraft = (patch: Partial<RequestDraftInput>) => {
    if (!selectedRequest) return;
    const base = draft ?? toDraft(selectedRequest);
    setDraftState({ reqId: selectedRequest.id, draft: { ...base, ...patch }, dirty: true });
  };

  const handleSaveRequest = useCallback(async () => {
    if (!activeReqId || !draft) return;
    try {
      const saved = await updateRequest.mutateAsync({ id: activeReqId, ...draft });
      setDraftState({ reqId: saved.id, draft: toDraft(saved), dirty: false });
      toast({ title: "Request saved", tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to save request", tone: "error" });
    }
  }, [activeReqId, draft, updateRequest]);

  const activeEnvId = bundle?.workspace.active_environment_id ?? null;
  const handleSend = useCallback(async () => {
    if (!activeReqId || !draft) return;
    try {
      const exec = await runRequest.mutateAsync({
        requestId: activeReqId,
        environmentId: activeEnvId,
        override: draft,
      });
      setLatestExecution({ reqId: activeReqId, exec });
      setRespTab("body");
      if (exec.error) {
        toast({ title: exec.error, tone: "error" });
      }
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Request failed", tone: "error" });
    }
  }, [activeReqId, draft, activeEnvId, runRequest]);

  // Keyboard shortcuts: Cmd/Ctrl+S saves, Cmd/Ctrl+Enter sends.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key.toLowerCase() === "s") {
        e.preventDefault();
        void handleSaveRequest();
      } else if (e.key === "Enter") {
        e.preventDefault();
        void handleSend();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [handleSaveRequest, handleSend]);

  const handleCreateWorkspace = async () => {
    const name = newWsName.trim();
    if (!name) return;
    try {
      const created = await createWorkspace.mutateAsync({
        name,
        seed_environments: true,
        default_auth: { type: "none" },
      });
      setSelectedWsId(created.workspace.id);
      setNewWsName("");
      setNewWsOpen(false);
      toast({ title: `Workspace "${created.workspace.name}" created`, tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to create workspace", tone: "error" });
    }
  };

  const handleCreateFolder = async () => {
    if (!bundle) return;
    const name = newFolderName.trim();
    if (!name) return;
    try {
      const created = await createFolder.mutateAsync({
        parent_folder_id: selectedFolderId,
        name,
        default_auth: { type: "inherit" },
      });
      setSelectedFolderId(created.id);
      setNewFolderName("");
      setNewFolderOpen(false);
      toast({ title: `Folder "${created.name}" created`, tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to create folder", tone: "error" });
    }
  };

  const handleCreateRequest = async (folderId: string | null = selectedFolderId) => {
    if (!bundle) return;
    try {
      const created = await createRequest.mutateAsync({
        folder_id: folderId,
        name: "New Request",
        method: "GET",
        url: "{{base_url}}/",
        params: [],
        headers: [],
        auth: { type: "inherit" },
        body_mode: "none",
        body: "",
        body_form: [],
        timeout_ms: 30000,
        follow_redirects: true,
      });
      selectRequest(created);
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to create request", tone: "error" });
    }
  };

  const activeEnv = bundle?.environments.find((e) => e.id === bundle.workspace.active_environment_id) ?? null;
  const inherited = bundle ? resolveInheritedSource(bundle, draft?.folder_id ?? null) : null;

  const normalizedFilter = filter.trim().toLowerCase();
  const matchesFilter = (r: HttpRequest) =>
    !normalizedFilter ||
    r.name.toLowerCase().includes(normalizedFilter) ||
    r.url.toLowerCase().includes(normalizedFilter) ||
    r.method.toLowerCase().includes(normalizedFilter);

  const startNewFolder = (parentId: string | null) => {
    setSelectedFolderId(parentId);
    if (parentId) setCollapsedFolders((p) => ({ ...p, [parentId]: false }));
    setNewFolderOpen(true);
  };
  const handleDeleteFolder = async (folder: HttpFolder) => {
    const ok = await confirmAction({
      title: `Delete folder "${folder.name}"?`,
      body: "This removes the folder and any nested folders or requests inside it.",
      confirmLabel: "Delete",
    });
    if (ok) void deleteFolder.mutateAsync(folder.id);
  };
  const folderMenu = (folder: HttpFolder): TreeMenuEntry[] => [
    {
      icon: "plus",
      label: "New request",
      onSelect: () => {
        setCollapsedFolders((p) => ({ ...p, [folder.id]: false }));
        void handleCreateRequest(folder.id);
      },
    },
    { icon: "upload", label: "Import cURL…", onSelect: () => setShowImport({ folder, tab: "curl" }) },
    { icon: "upload", label: "Import collection…", onSelect: () => setShowImport({ folder, tab: "bru" }) },
    { icon: "folder", label: "New folder", onSelect: () => startNewFolder(folder.id) },
    "separator",
    { icon: "trash", label: "Delete folder", danger: true, onSelect: () => void handleDeleteFolder(folder) },
  ];
  const rootMenu: TreeMenuEntry[] = [
    { icon: "plus", label: "New request", onSelect: () => void handleCreateRequest(null) },
    { icon: "upload", label: "Import cURL…", onSelect: () => setShowImport({ folder: null, tab: "curl" }) },
    { icon: "upload", label: "Import collection…", onSelect: () => setShowImport({ folder: null, tab: "bru" }) },
    { icon: "folder", label: "New folder", onSelect: () => startNewFolder(null) },
  ];

  const renderTree = (parentId: string | null, depth = 0) => {
    if (!bundle) return null;
    const folders = bundle.folders.filter((f) => f.parent_folder_id === parentId);
    const reqs = bundle.requests.filter((r) => r.folder_id === parentId && matchesFilter(r));

    return (
      <>
        {folders.map((folder) => {
          const isCollapsed = collapsedFolders[folder.id] ?? false;
          const isFolderSelected = selectedFolderId === folder.id && !selectedReqId;
          return (
            <div key={folder.id}>
              <TreeMenu entries={folderMenu(folder)}>
              <div
                style={{ paddingLeft: `${8 + depth * 12}px` }}
                className={cx(
                  "group flex h-[28px] items-center gap-1.5 rounded-md pr-1.5 text-12",
                  isFolderSelected ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
                )}
              >
                <button
                  type="button"
                  aria-label={isCollapsed ? "Expand folder" : "Collapse folder"}
                  onClick={() => setCollapsedFolders((p) => ({ ...p, [folder.id]: !isCollapsed }))}
                  className="grid size-4 place-items-center text-fg-tertiary"
                >
                  <Icon name={isCollapsed ? "chevr" : "chev"} size={11} />
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setSelectedFolderId(folder.id);
                    setCollapsedFolders((p) => ({ ...p, [folder.id]: false }));
                  }}
                  className="flex min-w-0 flex-1 items-center gap-1.5 text-left font-medium"
                >
                  <Icon name="folder" size={13} className="flex-none text-fg-tertiary" />
                  <span className="truncate">{folder.name}</span>
                </button>
                <button
                  type="button"
                  title="New request in folder"
                  onClick={() => void handleCreateRequest(folder.id)}
                  className="hidden size-5 place-items-center rounded text-fg-tertiary hover:bg-surface hover:text-fg group-hover:grid"
                >
                  <Icon name="plus" size={12} />
                </button>
                <button
                  type="button"
                  title="Delete folder"
                  onClick={() => void handleDeleteFolder(folder)}
                  className="hidden size-5 place-items-center rounded text-fg-tertiary hover:bg-surface hover:text-state-blocked group-hover:grid"
                >
                  <Icon name="trash" size={12} />
                </button>
              </div>
              </TreeMenu>
              {!isCollapsed && renderTree(folder.id, depth + 1)}
            </div>
          );
        })}
        {reqs.map((r) => {
          const active = r.id === activeReqId && viewMode === "requests";
          return (
            <TreeMenu
              key={r.id}
              entries={[
                { icon: "plus", label: "New request here", onSelect: () => void handleCreateRequest(r.folder_id) },
                "separator",
                { icon: "trash", label: "Delete request", danger: true, onSelect: () => void deleteRequest.mutateAsync(r.id) },
              ]}
            >
            <div
              style={{ paddingLeft: `${12 + depth * 12}px` }}
              className={cx(
                "group flex h-[30px] items-center gap-2 rounded-md pr-1.5 text-12",
                active ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              <button
                type="button"
                onClick={() => selectRequest(r)}
                className="flex min-w-0 flex-1 items-center gap-2 text-left"
              >
                <span className={cx("w-8 flex-none font-mono text-10 font-bold", METHOD_COLOR[r.method] ?? "text-fg-secondary")}>
                  {r.method === "DELETE" ? "DEL" : r.method === "OPTIONS" ? "OPT" : r.method}
                </span>
                <span className="truncate">{r.name}</span>
              </button>
              <button
                type="button"
                title="Delete request"
                onClick={() => void deleteRequest.mutateAsync(r.id)}
                className="hidden size-5 place-items-center rounded text-fg-tertiary hover:bg-surface hover:text-state-blocked group-hover:grid"
              >
                <Icon name="trash" size={12} />
              </button>
            </div>
            </TreeMenu>
          );
        })}
      </>
    );
  };

  return (
    <div className="flex h-dvh min-h-0 flex-1 flex-col bg-bg text-fg">
      {/* Top utility bar */}
      <header className="flex h-[48px] flex-none items-center justify-between gap-3 border-b border-border-subtle bg-sidebar px-3">
        <div className="flex min-w-0 items-center gap-2">
          <Button
            variant="outline"
            onClick={() => {
              if (window.history.length > 1) router.back();
              else router.push("/");
            }}
          >
            ← Back
          </Button>

          {workspaces.length > 0 && (
            <select
              aria-label="HTTP Workspace"
              value={effectiveWsId ?? ""}
              onChange={(e) => {
                setSelectedWsId(e.target.value);
                setSelectedReqId(null);
                setSelectedFolderId(null);
              }}
              className="h-[30px] max-w-[220px] rounded-md border border-border-strong bg-surface px-2.5 text-13 font-medium text-fg focus:border-accent focus:outline-none"
            >
              {workspaces.map((w) => (
                <option key={w.id} value={w.id}>
                  {w.name}
                </option>
              ))}
            </select>
          )}

          <Button variant="outline" icon="plus" onClick={() => setNewWsOpen((v) => !v)}>
            Workspace
          </Button>
          {bundle && (
            <button
              type="button"
              title="Delete workspace"
              onClick={async () => {
                const ok = await confirmAction({
                  title: `Delete workspace "${bundle.workspace.name}"?`,
                  body: "This deletes all folders, requests, environments, and execution history in this workspace.",
                  confirmLabel: "Delete",
                });
                if (ok) {
                  void deleteWorkspace.mutateAsync(bundle.workspace.id).then(() => setSelectedWsId(null));
                }
              }}
              className="grid size-[30px] place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-state-blocked"
            >
              <Icon name="trash" size={14} />
            </button>
          )}
        </div>

        {bundle && (
          <div className="flex items-center gap-2">
            <div className="flex items-center gap-1.5 rounded-md border border-border-strong bg-surface px-2">
              <span className={cx("size-2 rounded-full", activeEnv ? ENV_DOT[activeEnv.color] : "bg-fg-tertiary")} />
              <select
                aria-label="Active environment"
                value={bundle.workspace.active_environment_id ?? ""}
                onChange={(e) =>
                  setActiveEnv.mutate({
                    workspaceId: bundle.workspace.id,
                    environmentId: e.target.value || null,
                  })
                }
                className="h-[28px] bg-transparent text-12 font-medium text-fg focus:outline-none"
              >
                <option value="">No environment</option>
                {bundle.environments.map((env) => (
                  <option key={env.id} value={env.id}>
                    {env.name}
                  </option>
                ))}
              </select>
            </div>

            <Button variant="outline" icon="upload" onClick={() => setShowImport({ folder: null, tab: "bru" })}>
              Import
            </Button>
            <Button
              variant={viewMode === "auth-env" ? "primary" : "outline"}
              icon="sliders"
              onClick={() => setViewMode((m) => (m === "auth-env" ? "requests" : "auth-env"))}
            >
              Auth & Env
            </Button>
          </div>
        )}
      </header>

      {newWsOpen && (
        <div className="flex items-center gap-2 border-b border-border-subtle bg-surface px-4 py-2.5">
          <TextInput
            value={newWsName}
            placeholder="Workspace name (e.g. Billing API)"
            onChange={(e) => setNewWsName(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void handleCreateWorkspace()}
            className="max-w-[300px]"
          />
          <Button variant="primary" disabled={createWorkspace.isPending} onClick={handleCreateWorkspace}>
            Create Workspace (with nonprod + prod)
          </Button>
          <Button variant="ghost" onClick={() => setNewWsOpen(false)}>
            Cancel
          </Button>
        </div>
      )}

      {/* Main body */}
      {!workspacesQuery.isLoading && workspaces.length === 0 ? (
        <div className="grid flex-1 place-items-center p-6">
          <EmptyState
            icon="plug"
            title="No HTTP workspaces yet"
            actions={
              <Button
                variant="primary"
                icon="plus"
                onClick={() => {
                  setNewWsName("Default API");
                  setNewWsOpen(true);
                }}
              >
                Create your first workspace
              </Button>
            }
          >
            Organize HTTP calls by app into Workspaces, switch between nonprod and prod environments, inherit auth, or import your Bruno .bru collections.
          </EmptyState>
        </div>
      ) : !bundle ? (
        <div className="flex flex-1 flex-col gap-3 p-6">
          <Skeleton className="h-8 w-64" />
          <Skeleton className="h-48 w-full" />
        </div>
      ) : viewMode === "auth-env" ? (
        <AuthEnvView bundle={bundle} selectedFolder={selectedFolder} onBack={() => setViewMode("requests")} />
      ) : (
        <div className="flex min-h-0 flex-1 overflow-hidden">
          {/* Left collection tree */}
          <aside className="flex w-[264px] flex-none flex-col border-r border-border-subtle bg-sidebar">
            <div className="flex items-center gap-1.5 border-b border-border-subtle p-2.5">
              <TextInput
                value={filter}
                placeholder="Filter calls…"
                onChange={(e) => setFilter(e.target.value)}
                className="min-w-0 flex-1"
              />
              <Button variant="primary" icon="plus" onClick={() => void handleCreateRequest(selectedFolderId)} title="New request" />
              <Button variant="outline" icon="folder" onClick={() => setNewFolderOpen((v) => !v)} title="New folder" />
            </div>
            {newFolderOpen && (
              <div className="flex items-center gap-1.5 border-b border-border-subtle p-2">
                <TextInput
                  value={newFolderName}
                  placeholder="Folder name"
                  onChange={(e) => setNewFolderName(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && void handleCreateFolder()}
                  className="min-w-0 flex-1"
                />
                <Button variant="primary" onClick={handleCreateFolder}>
                  Add
                </Button>
              </div>
            )}
            <TreeMenu entries={rootMenu} className="flex-1 overflow-y-auto p-2">
              {bundle.folders.length === 0 && bundle.requests.length === 0 ? (
                <div className="p-3 text-center text-12 text-fg-tertiary">
                  No requests yet. Click <strong>+</strong> or <strong>Import</strong> to add one.
                </div>
              ) : (
                renderTree(null, 0)
              )}
            </TreeMenu>
          </aside>

          {/* Request + Response workspace */}
          {!draft || !selectedRequest ? (
            <div className="grid flex-1 place-items-center p-6">
              <EmptyState
                icon="plug"
                title="Select or create a request"
                actions={
                  <>
                    <Button variant="primary" icon="plus" onClick={() => void handleCreateRequest(null)}>
                      New Request
                    </Button>
                    <Button variant="outline" icon="upload" onClick={() => setShowImport({ folder: null, tab: "bru" })}>
                      Import .bru / cURL / OpenAPI
                    </Button>
                  </>
                }
              >
                External hosts only in v1, with workspace auth inheritance and active environment substitution.
              </EmptyState>
            </div>
          ) : (
            <div className="flex min-w-0 flex-1 flex-col">
              {/* Name + URL strip */}
              <div className="flex flex-col gap-2 border-b border-border-subtle bg-surface px-4 py-3">
                <div className="flex items-center justify-between gap-2">
                  <input
                    aria-label="Request name"
                    value={draft.name}
                    onChange={(e) => patchDraft({ name: e.target.value })}
                    className="min-w-0 flex-1 bg-transparent text-14 font-semibold text-fg focus:outline-none"
                  />
                  {dirty && <span className="text-11 text-state-human">Unsaved changes</span>}
                  <Button
                    variant="outline"
                    disabled={!dirty || updateRequest.isPending}
                    onClick={handleSaveRequest}
                    hint="⌘S"
                  >
                    Save
                  </Button>
                </div>
                <div className="flex items-center gap-2">
                  <select
                    aria-label="HTTP method"
                    value={draft.method}
                    onChange={(e) => patchDraft({ method: e.target.value })}
                    className={cx(
                      "h-[34px] w-[104px] rounded-md border border-border-strong bg-bg px-2 font-mono text-13 font-bold focus:border-accent focus:outline-none",
                      METHOD_COLOR[draft.method] ?? "text-fg",
                    )}
                  >
                    {METHODS.map((m) => (
                      <option key={m} value={m}>
                        {m}
                      </option>
                    ))}
                  </select>
                  <TextInput
                    mono
                    value={draft.url}
                    placeholder="{{base_url}}/v1/resource"
                    onChange={(e) => patchDraft({ url: e.target.value })}
                    className="h-[34px] min-w-0 flex-1"
                  />
                  <Button
                    variant="primary"
                    icon="play"
                    disabled={runRequest.isPending}
                    onClick={handleSend}
                    hint="⌘↵"
                    className="h-[34px] px-4"
                  >
                    {runRequest.isPending ? "Sending…" : "Send"}
                  </Button>
                </div>
              </div>

              {/* Split Request / Response panes */}
              <div className="grid min-h-0 flex-1 grid-cols-1 divide-y divide-border-subtle lg:grid-cols-2 lg:divide-x lg:divide-y-0">
                {/* Left: Request configuration */}
                <section className="flex min-h-0 flex-col overflow-hidden">
                  <div className="flex items-center gap-1 border-b border-border-subtle px-3 py-2">
                    {(
                      [
                        ["params", `Params${draft.params.length ? ` (${draft.params.length})` : ""}`],
                        ["headers", `Headers${draft.headers.length ? ` (${draft.headers.length})` : ""}`],
                        ["auth", `Auth (${draft.auth.type === "inherit" ? "Inherited" : draft.auth.type})`],
                        ["body", "Body"],
                        ["settings", "Settings"],
                      ] as const
                    ).map(([id, label]) => (
                      <button
                        key={id}
                        type="button"
                        onClick={() => setReqTab(id)}
                        className={cx(
                          "rounded-md px-2.5 py-1 text-12 font-medium",
                          reqTab === id ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover",
                        )}
                      >
                        {label}
                      </button>
                    ))}
                  </div>

                  <div className="flex-1 overflow-y-auto p-4">
                    {reqTab === "params" && (
                      <KVEditor
                        items={draft.params}
                        onChange={(params) => patchDraft({ params })}
                        keyPlaceholder="query_param"
                        valuePlaceholder="value"
                        emptyLabel="No query parameters."
                      />
                    )}
                    {reqTab === "headers" && (
                      <div className="flex flex-col gap-3">
                        {bundle.workspace.default_headers.length > 0 && (
                          <div className="rounded-md border border-border-subtle bg-sidebar px-3 py-2 text-12 text-fg-secondary">
                            Inherits {bundle.workspace.default_headers.filter((h) => h.enabled).length} workspace header(s). Matching keys below override them.
                          </div>
                        )}
                        <KVEditor
                          items={draft.headers}
                          onChange={(headers) => patchDraft({ headers })}
                          keyPlaceholder="Header-Name"
                          valuePlaceholder="value"
                          emptyLabel="No request-specific headers."
                        />
                      </div>
                    )}
                    {reqTab === "auth" && (
                      <AuthEditor
                        value={draft.auth}
                        onChange={(auth) => patchDraft({ auth })}
                        allowInherit
                        inheritedSummary={inherited ? `Inheriting from ${inherited.label}` : undefined}
                      />
                    )}
                    {reqTab === "body" && (
                      <div className="flex flex-col gap-3">
                        <div className="flex items-center justify-between gap-2">
                          <select
                            aria-label="Body mode"
                            value={draft.body_mode}
                            onChange={(e) => patchDraft({ body_mode: e.target.value as BodyMode })}
                            className="h-[30px] rounded-md border border-border-strong bg-surface px-2.5 text-12 text-fg focus:border-accent focus:outline-none"
                          >
                            <option value="none">None</option>
                            <option value="json">JSON</option>
                            <option value="raw">Raw text</option>
                            <option value="form_urlencoded">Form URL-encoded</option>
                            <option value="multipart">Multipart form</option>
                          </select>
                          {draft.body_mode === "json" && (
                            <Button
                              variant="outline"
                              onClick={() => {
                                try {
                                  patchDraft({ body: JSON.stringify(JSON.parse(draft.body), null, 2) });
                                } catch {
                                  toast({ title: "Body is not valid JSON", tone: "error" });
                                }
                              }}
                            >
                              Format JSON
                            </Button>
                          )}
                        </div>
                        {(draft.body_mode === "json" || draft.body_mode === "raw") && (
                          <TextArea
                            mono
                            rows={16}
                            value={draft.body}
                            placeholder={draft.body_mode === "json" ? '{\n  "key": "value"\n}' : "Raw body…"}
                            onChange={(e) => patchDraft({ body: e.target.value })}
                          />
                        )}
                        {(draft.body_mode === "form_urlencoded" || draft.body_mode === "multipart") && (
                          <KVEditor
                            items={draft.body_form}
                            onChange={(body_form) => patchDraft({ body_form })}
                            keyPlaceholder="field"
                            valuePlaceholder="value"
                          />
                        )}
                      </div>
                    )}
                    {reqTab === "settings" && (
                      <div className="flex flex-col gap-3 text-13">
                        <label className="flex items-center gap-2">
                          <input
                            type="checkbox"
                            checked={draft.follow_redirects}
                            onChange={(e) => patchDraft({ follow_redirects: e.target.checked })}
                            className="size-4 accent-accent"
                          />
                          <span>Follow HTTP redirects (SSRF-checked per hop)</span>
                        </label>
                        <div className="flex items-center gap-2">
                          <span className="text-fg-2">Timeout (ms):</span>
                          <TextInput
                            mono
                            type="number"
                            value={String(draft.timeout_ms)}
                            onChange={(e) => patchDraft({ timeout_ms: Number(e.target.value) || 30000 })}
                            className="w-[120px]"
                          />
                        </div>
                      </div>
                    )}
                  </div>
                </section>

                {/* Right: Response viewer */}
                <section className="flex min-h-0 flex-col overflow-hidden bg-bg">
                  <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border-subtle px-4 py-2">
                    {activeExecution ? (
                      <div className="flex items-center gap-2 text-12">
                        <span
                          className={cx(
                            "rounded px-2 py-0.5 font-mono font-bold",
                            activeExecution.error
                              ? "bg-state-blocked/15 text-state-blocked"
                              : activeExecution.status_code < 300
                                ? "bg-state-done/15 text-state-done"
                                : activeExecution.status_code < 400
                                  ? "bg-state-human/15 text-state-human"
                                  : "bg-state-blocked/15 text-state-blocked",
                          )}
                        >
                          {activeExecution.error ? "ERROR" : activeExecution.status_text || activeExecution.status_code}
                        </span>
                        <span className="font-mono text-fg-secondary">{activeExecution.duration_ms} ms</span>
                        <span className="font-mono text-fg-tertiary">{formatBytes(activeExecution.size_bytes)}</span>
                        {activeExecution.environment_name && (
                          <span className="rounded bg-surface px-1.5 py-0.5 text-11 text-fg-secondary">
                            {activeExecution.environment_name}
                          </span>
                        )}
                      </div>
                    ) : (
                      <span className="text-12 text-fg-tertiary">No response yet — press Send (⌘↵)</span>
                    )}

                    <div className="flex items-center gap-1">
                      {(
                        [
                          ["body", "Body"],
                          ["headers", "Headers"],
                          ["request", "Request"],
                          ["history", `History (${execHistoryQuery.data?.length ?? 0})`],
                        ] as const
                      ).map(([id, label]) => (
                        <button
                          key={id}
                          type="button"
                          onClick={() => setRespTab(id)}
                          className={cx(
                            "rounded-md px-2 py-1 text-12 font-medium",
                            respTab === id ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover",
                          )}
                        >
                          {label}
                        </button>
                      ))}
                    </div>
                  </div>

                  <div className="flex-1 overflow-y-auto p-4">
                    {respTab === "history" ? (
                      <div className="flex flex-col gap-1.5">
                        {(execHistoryQuery.data ?? []).length === 0 ? (
                          <p className="text-12 text-fg-tertiary">No recorded runs for this request yet.</p>
                        ) : (
                          (execHistoryQuery.data ?? []).map((ex) => (
                            <button
                              key={ex.id}
                              type="button"
                              onClick={() => {
                                if (activeReqId) setLatestExecution({ reqId: activeReqId, exec: ex });
                                setRespTab("body");
                              }}
                              className="flex items-center justify-between rounded-md border border-border-subtle bg-surface px-3 py-2 text-left text-12 hover:bg-hover"
                            >
                              <div className="flex items-center gap-2">
                                <span className="font-mono font-bold">{ex.error ? "ERR" : ex.status_code}</span>
                                <span className="truncate font-mono text-fg-secondary">{ex.resolved_url}</span>
                              </div>
                              <div className="flex items-center gap-2 text-11 text-fg-tertiary">
                                {ex.environment_name && <span>{ex.environment_name}</span>}
                                <span>{ex.duration_ms} ms</span>
                              </div>
                            </button>
                          ))
                        )}
                      </div>
                    ) : !activeExecution ? (
                      <p className="text-12 text-fg-tertiary">Run the request to see headers, timing, and formatted body output.</p>
                    ) : activeExecution.error ? (
                      <div className="rounded-lg border border-state-blocked/40 bg-state-blocked/10 p-3 font-mono text-12 text-state-blocked">
                        {activeExecution.error}
                      </div>
                    ) : respTab === "body" ? (
                      <div className="flex flex-col gap-2">
                        <div className="flex items-center justify-between">
                          {activeExecution.response_truncated && (
                            <span className="text-11 text-state-human">Response truncated at 2 MiB</span>
                          )}
                          <div className="ml-auto">
                            <CopyButton text={activeExecution.response_body} label="Copy body" />
                          </div>
                        </div>
                        <pre className="overflow-x-auto rounded-lg border border-border-subtle bg-surface p-3 font-mono text-12 leading-relaxed text-fg">
                          {formatBodyPreview(activeExecution.response_body) || "(empty body)"}
                        </pre>
                      </div>
                    ) : respTab === "headers" ? (
                      <div className="flex flex-col gap-1 font-mono text-12">
                        {Object.entries(activeExecution.response_headers).map(([k, vals]) => (
                          <div key={k} className="grid grid-cols-[180px_1fr] gap-2 border-b border-border-subtle py-1">
                            <span className="font-semibold text-fg-secondary">{k}</span>
                            <span className="break-all text-fg">{vals.join(", ")}</span>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <div className="flex flex-col gap-3 font-mono text-12">
                        <div>
                          <div className="mb-1 text-11 font-semibold uppercase text-fg-tertiary">Resolved URL</div>
                          <div className="break-all rounded border border-border-subtle bg-surface p-2">
                            {activeExecution.method} {activeExecution.resolved_url}
                          </div>
                        </div>
                        <div>
                          <div className="mb-1 text-11 font-semibold uppercase text-fg-tertiary">Sent Headers (secrets redacted)</div>
                          <pre className="overflow-x-auto rounded border border-border-subtle bg-surface p-2">
                            {JSON.stringify(activeExecution.request_headers, null, 2)}
                          </pre>
                        </div>
                      </div>
                    )}
                  </div>
                </section>
              </div>
            </div>
          )}
        </div>
      )}

      {showImport && bundle && (
        <ImportDialog
          workspaceId={bundle.workspace.id}
          folder={showImport.folder}
          initialTab={showImport.tab}
          onClose={() => setShowImport(null)}
        />
      )}
    </div>
  );
}
