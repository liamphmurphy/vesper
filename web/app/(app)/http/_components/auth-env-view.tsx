"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, Field, TextInput } from "@/components/ui/primitives";
import { toast } from "@/components/ui/toast";
import { cx } from "@/lib/cx";
import {
  useCreateHttpEnvironment,
  useDeleteHttpEnvironment,
  useSetHttpActiveEnvironment,
  useUpdateHttpEnvironment,
  useUpdateHttpFolder,
  useUpdateHttpWorkspace,
  type AuthConfig,
  type EnvColor,
  type EnvVar,
  type HttpEnvironment,
  type HttpFolder,
  type HttpWorkspaceBundle,
  type KeyValue,
} from "@/lib/api/http-client-hooks";
import { useApiSecrets } from "@/lib/api/secret-hooks";
import { AuthEditor } from "./auth-editor";
import { EnvVarEditor, KVEditor } from "./kv-editor";

export const ENV_DOT: Record<EnvColor, string> = {
  green: "bg-state-done",
  amber: "bg-state-human",
  red: "bg-state-blocked",
  blue: "bg-accent",
  purple: "bg-accent",
  gray: "bg-fg-tertiary",
};

export function AuthEnvView({
  bundle,
  selectedFolder,
  onBack,
}: {
  bundle: HttpWorkspaceBundle;
  selectedFolder: HttpFolder | null;
  onBack: () => void;
}) {
  const ws = bundle.workspace;
  const secretsQuery = useApiSecrets();
  const secrets = secretsQuery.data?.secrets ?? [];

  const updateWorkspace = useUpdateHttpWorkspace();
  const setActiveEnv = useSetHttpActiveEnvironment();
  const createEnv = useCreateHttpEnvironment(ws.id);
  const updateEnv = useUpdateHttpEnvironment(ws.id);
  const deleteEnv = useDeleteHttpEnvironment(ws.id);
  const updateFolder = useUpdateHttpFolder(ws.id);

  // Workspace defaults state.
  const [wsName, setWsName] = useState(ws.name);
  const [wsAuth, setWsAuth] = useState<AuthConfig>(ws.default_auth);
  const [wsHeaders, setWsHeaders] = useState<KeyValue[]>(ws.default_headers);
  const [wsVars, setWsVars] = useState<EnvVar[]>(ws.default_vars);

  // Selected folder override state (when a folder is selected).
  const [folderAuth, setFolderAuth] = useState<AuthConfig>(selectedFolder?.default_auth ?? { type: "inherit" });
  const [folderHeaders, setFolderHeaders] = useState<KeyValue[]>(selectedFolder?.default_headers ?? []);

  // Selected environment state.
  const initialEnv =
    bundle.environments.find((e) => e.id === ws.active_environment_id) ??
    bundle.environments[0] ??
    null;
  const [editingEnvId, setEditingEnvId] = useState<string | null>(initialEnv?.id ?? null);
  const activeEditingEnv: HttpEnvironment | null =
    bundle.environments.find((e) => e.id === editingEnvId) ?? bundle.environments[0] ?? null;

  const [envName, setEnvName] = useState(activeEditingEnv?.name ?? "");
  const [envColor, setEnvColor] = useState<EnvColor>(activeEditingEnv?.color ?? "green");
  const [envVars, setEnvVars] = useState<EnvVar[]>(activeEditingEnv?.variables ?? []);
  const [newEnvName, setNewEnvName] = useState("");
  const [addingEnv, setAddingEnv] = useState(false);

  const selectEnvToEdit = (env: HttpEnvironment) => {
    setEditingEnvId(env.id);
    setEnvName(env.name);
    setEnvColor(env.color);
    setEnvVars(env.variables);
  };

  const saveWorkspaceDefaults = async () => {
    try {
      await updateWorkspace.mutateAsync({
        id: ws.id,
        name: wsName,
        description: ws.description,
        active_environment_id: ws.active_environment_id,
        default_auth: wsAuth,
        default_headers: wsHeaders,
        default_vars: wsVars,
      });
      toast({ title: "Workspace defaults saved", tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to save workspace defaults", tone: "error" });
    }
  };

  const saveFolderDefaults = async () => {
    if (!selectedFolder) return;
    try {
      await updateFolder.mutateAsync({
        id: selectedFolder.id,
        parent_folder_id: selectedFolder.parent_folder_id,
        name: selectedFolder.name,
        default_auth: folderAuth,
        default_headers: folderHeaders,
        sort_order: selectedFolder.sort_order,
      });
      toast({ title: `Folder "${selectedFolder.name}" defaults saved`, tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to save folder defaults", tone: "error" });
    }
  };

  const saveEnvironment = async () => {
    if (!activeEditingEnv) return;
    try {
      await updateEnv.mutateAsync({
        id: activeEditingEnv.id,
        name: envName,
        color: envColor,
        variables: envVars,
        sort_order: activeEditingEnv.sort_order,
      });
      toast({ title: `Environment "${envName}" saved`, tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to save environment", tone: "error" });
    }
  };

  const handleCreateEnv = async () => {
    const trimmed = newEnvName.trim();
    if (!trimmed) return;
    const color: EnvColor = trimmed.toLowerCase().includes("prod") && !trimmed.toLowerCase().includes("non") ? "red" : "green";
    try {
      const created = await createEnv.mutateAsync({
        name: trimmed,
        color,
        variables: [{ key: "base_url", value: "https://api.example.com", enabled: true }],
        sort_order: bundle.environments.length,
      });
      setAddingEnv(false);
      setNewEnvName("");
      selectEnvToEdit(created);
      await setActiveEnv.mutateAsync({ workspaceId: ws.id, environmentId: created.id });
      toast({ title: `Environment "${created.name}" created`, tone: "success" });
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Failed to create environment", tone: "error" });
    }
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-auto p-5">
      <div className="mb-4 flex items-center justify-between gap-3">
        <div>
          <h1 className="type-heading text-fg">
            {ws.name} — Auth Inheritance & Environments
          </h1>
          <p className="text-12 text-fg-secondary">
            Inheritance chain: Workspace → Folder → Request. Any level can inherit or override.
          </p>
        </div>
        <Button variant="outline" onClick={onBack}>
          ← Back to Requests
        </Button>
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
        <div className="flex flex-col gap-5">
          <Card
            title="Workspace Default Auth & Headers"
            action={
              <Button variant="primary" disabled={updateWorkspace.isPending} onClick={saveWorkspaceDefaults}>
                Save Defaults
              </Button>
            }
          >
            <div className="flex flex-col gap-4">
              <Field label="Workspace name">
                <TextInput value={wsName} onChange={(e) => setWsName(e.target.value)} />
              </Field>
              <AuthEditor value={wsAuth} onChange={setWsAuth} allowInherit={false} />
              <div className="flex flex-col gap-1.5">
                <span className="text-13 font-medium text-fg-2">Inherited headers</span>
                <KVEditor
                  items={wsHeaders}
                  onChange={setWsHeaders}
                  keyPlaceholder="X-Client-Id"
                  valuePlaceholder="{{client_id}}"
                  emptyLabel="No workspace-wide headers."
                />
              </div>
              <div className="flex flex-col gap-1.5">
                <span className="text-13 font-medium text-fg-2">Shared workspace variables (base defaults)</span>
                <EnvVarEditor
                  items={wsVars}
                  secrets={secrets}
                  onChange={setWsVars}
                  emptyLabel="No shared workspace variables. Active environment variables override these."
                />
              </div>
            </div>
          </Card>

          {selectedFolder && (
            <Card
              title={`Folder Override: ${selectedFolder.name}`}
              action={
                <Button variant="secondary" disabled={updateFolder.isPending} onClick={saveFolderDefaults}>
                  Save Folder
                </Button>
              }
            >
              <div className="flex flex-col gap-4">
                <AuthEditor value={folderAuth} onChange={setFolderAuth} allowInherit />
                <div className="flex flex-col gap-1.5">
                  <span className="text-13 font-medium text-fg-2">Folder headers</span>
                  <KVEditor
                    items={folderHeaders}
                    onChange={setFolderHeaders}
                    emptyLabel="No folder-level header overrides."
                  />
                </div>
              </div>
            </Card>
          )}
        </div>

        <Card
          title="Environments & Variables"
          action={
            <div className="flex items-center gap-2">
              {activeEditingEnv && (
                <Button
                  variant="outline"
                  onClick={async () => {
                    await deleteEnv.mutateAsync(activeEditingEnv.id);
                    const next = bundle.environments.find((e) => e.id !== activeEditingEnv.id) ?? null;
                    if (next) selectEnvToEdit(next);
                    else setEditingEnvId(null);
                    toast({ title: "Environment deleted", tone: "success" });
                  }}
                >
                  Delete
                </Button>
              )}
              {activeEditingEnv && (
                <Button variant="primary" disabled={updateEnv.isPending} onClick={saveEnvironment}>
                  Save Env
                </Button>
              )}
            </div>
          }
        >
          <div className="flex flex-col gap-4">
            <div className="flex flex-wrap items-center gap-2">
              {bundle.environments.map((env) => {
                const selected = env.id === activeEditingEnv?.id;
                const isActive = env.id === ws.active_environment_id;
                return (
                  <button
                    key={env.id}
                    type="button"
                    onClick={() => selectEnvToEdit(env)}
                    className={cx(
                      "inline-flex h-[30px] items-center gap-2 rounded-md border px-2.5 text-12 font-medium transition-colors",
                      selected ? "border-accent bg-selected text-fg" : "border-border-strong bg-surface text-fg-secondary hover:bg-hover",
                    )}
                  >
                    <span className={cx("size-2 rounded-full", ENV_DOT[env.color])} />
                    <span>{env.name}</span>
                    {isActive && <span className="text-10 text-fg-tertiary">(active)</span>}
                  </button>
                );
              })}
              <Button variant="outline" icon="plus" onClick={() => setAddingEnv((v) => !v)}>
                New Env
              </Button>
            </div>

            {addingEnv && (
              <div className="flex items-center gap-2 rounded-lg border border-border-subtle bg-sidebar p-2.5">
                <TextInput
                  value={newEnvName}
                  placeholder="staging"
                  onChange={(e) => setNewEnvName(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && handleCreateEnv()}
                />
                <Button variant="primary" onClick={handleCreateEnv}>
                  Add
                </Button>
              </div>
            )}

            {activeEditingEnv ? (
              <div className="flex flex-col gap-4">
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                  <Field label="Environment name">
                    <TextInput value={envName} onChange={(e) => setEnvName(e.target.value)} />
                  </Field>
                  <Field label="Badge color">
                    <select
                      aria-label="Environment color"
                      value={envColor}
                      onChange={(e) => setEnvColor(e.target.value as EnvColor)}
                      className="h-[30px] w-full rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none"
                    >
                      <option value="green">Green (nonprod/dev)</option>
                      <option value="amber">Amber (staging)</option>
                      <option value="red">Red (prod)</option>
                      <option value="blue">Blue</option>
                      <option value="purple">Purple</option>
                      <option value="gray">Gray</option>
                    </select>
                  </Field>
                  <div className="flex items-end">
                    <Button
                      variant={activeEditingEnv.id === ws.active_environment_id ? "secondary" : "outline"}
                      onClick={() => setActiveEnv.mutate({ workspaceId: ws.id, environmentId: activeEditingEnv.id })}
                    >
                      {activeEditingEnv.id === ws.active_environment_id ? "Active Environment" : "Set Active"}
                    </Button>
                  </div>
                </div>

                <div className="flex flex-col gap-1.5">
                  <span className="text-13 font-medium text-fg-2">Variables & Vesper Secrets</span>
                  <EnvVarEditor items={envVars} secrets={secrets} onChange={setEnvVars} />
                </div>
              </div>
            ) : (
              <p className="text-13 text-fg-secondary">Create an environment (like nonprod or prod) to manage environment variables.</p>
            )}
          </div>
        </Card>
      </div>
    </div>
  );
}
