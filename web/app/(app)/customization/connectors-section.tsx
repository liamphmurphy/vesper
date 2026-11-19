"use client";

import Link from "next/link";
import { useState } from "react";
import { Dialog } from "radix-ui";
import type { Schemas } from "@/lib/api/client";
import { useAuthorizeConnector, useConnectors, useCreateConnector, useDeleteConnector, useProbeConnector, useTestConnector, useUpdateConnector, type Connector } from "@/lib/api/connector-hooks";
import { type Persona } from "@/lib/api/persona-hooks";
import { cx } from "@/lib/cx";
import { Button, IconButton } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Field, Skeleton, TextInput } from "@/components/ui/primitives";
import { PersonaAvatar } from "../chat/_components/persona";
import { confirmAction } from "@/components/ui/confirm";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
type Policy = Schemas["ConnectorTool"]["policy"];
type Auth = NewAuth;
type NewAuth = Schemas["NewConnector"]["auth_kind"];
type Preset = Schemas["ConnectorPreset"];

const trimSlash = (u: string) => u.trim().toLowerCase().replace(/\/+$/, "");
const splitScopes = (s: string) => s.split(/[\s,]+/).filter(Boolean);

const STATUS: Record<Connector["status"], { label: string; className: string }> = {
  connected: { label: "Connected", className: "bg-pill-done-bg text-pill-done-fg" },
  needs_sign_in: { label: "Sign in again", className: "bg-pill-human-bg text-pill-human-fg" },
  offline: { label: "Offline", className: "bg-pill-blocked-bg text-pill-blocked-fg" },
};

const POLICIES = [
  { value: "allow", label: "Allow" },
  { value: "ask", label: "Ask" },
  { value: "off", label: "Off" },
] as const;

const initials = (name: string) => name.split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();

/** Opened before any await, so the browser treats it as the person's click. */
function signInWindow() {
  return window.open("", "_blank", "width=560,height=720");
}

function finishSignIn(win: Window | null, link?: string) {
  if (!win) return;
  if (link && /^https?:/.test(link)) win.location.href = link;
  else win.close();
}

/** MCP servers the person's personas may use: the list, and the selected one's sign-in, access and tool permissions. */
export function ConnectorsSection({ personas }: { personas: Persona[] }) {
  const list = useConnectors();
  const [adding, setAdding] = useState<boolean | Preset>(false);
  const [selectedId, setSelectedId] = useState<string>();
  const rows = list.data?.connectors ?? [];
  const presets = list.data?.presets ?? [];
  const availablePresets = presets.filter((p) => !rows.some((c) => trimSlash(c.url) === trimSlash(p.url)));
  const selected = rows.find((c) => c.id === selectedId) ?? rows[0];
  return (
    <section aria-label="Connectors" className="flex flex-col gap-5">
      <header className="flex items-center gap-4">
        <span className="grid size-[72px] flex-none place-items-center rounded-full bg-selected text-fg-secondary"><Icon name="plug" size={28} /></span>
        <div className="min-w-0 flex-1">
          <h1 className="type-display text-fg">Connectors</h1>
          <p className="text-13 text-fg-secondary">MCP servers your personas can use.</p>
        </div>
        <Button variant="primary" icon="plus" onClick={() => setAdding(true)}>Add connector</Button>
      </header>
      {list.isError ? (
        <Banner tone="blocked" title="Couldn’t load connectors">{errorText(list.error)}</Banner>
      ) : !list.data ? (
        <Skeleton className="h-40" />
      ) : rows.length === 0 ? (
        <div className="flex flex-col gap-5">
          <EmptyState compact icon="plug" title="No connectors yet" className="rounded-lg border border-border bg-surface">Add an MCP server to give your personas new tools.</EmptyState>
          {availablePresets.length > 0 && <SuggestedConnectors presets={availablePresets} onPick={setAdding} />}
        </div>
      ) : (
        <div className="flex flex-col gap-5">
          <div className="flex gap-5 max-lg:flex-col">
            <ul className="flex min-w-0 flex-1 flex-col self-start overflow-hidden rounded-lg border border-border bg-surface max-lg:w-full">
              {rows.map((c) => (
                <li key={c.id} className="border-b border-border-row last:border-b-0">
                  <button type="button" data-testid="connector-row" aria-current={c.id === selected?.id} onClick={() => setSelectedId(c.id)} className={cx("flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-hover", c.id === selected?.id && "bg-selected")}>
                    <span className="grid size-[34px] flex-none place-items-center rounded-lg bg-border-strong text-13 font-semibold text-fg">{initials(c.name)}</span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-14 font-medium text-fg">{c.name}</span>
                      <span className="block truncate text-12 text-fg-secondary">{c.tools.length} tools · {c.persona_ids.length ? `${c.persona_ids.length} ${c.persona_ids.length === 1 ? "persona" : "personas"}` : "No personas yet"}</span>
                    </span>
                    <span className={cx("flex-none rounded-full px-2.5 py-0.5 text-11", STATUS[c.status].className)}>{STATUS[c.status].label}</span>
                  </button>
                </li>
              ))}
            </ul>
            {selected && <ConnectorDetail key={selected.id} connector={selected} personas={personas} />}
          </div>
          {availablePresets.length > 0 && <SuggestedConnectors presets={availablePresets} onPick={setAdding} />}
        </div>
      )}
      {adding && <AddConnectorDialog preset={typeof adding === "object" ? adding : undefined} presets={presets} onClose={() => setAdding(false)} />}
    </section>
  );
}

function SuggestedConnectors({ presets, onPick }: { presets: Preset[]; onPick: (preset: Preset) => void }) {
  return (
    <section aria-label="Suggested connectors" className="flex flex-col gap-2.5">
      <h3 className="text-14 font-medium text-fg">Suggested</h3>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {presets.map((p) => (
          <button
            key={p.id}
            type="button"
            data-testid={`preset-${p.id}`}
            onClick={() => onPick(p)}
            className="flex items-start gap-3 rounded-lg border border-border bg-surface p-3.5 text-left transition-colors hover:border-border-strong hover:bg-hover"
          >
            <span className="grid size-[34px] flex-none place-items-center rounded-lg bg-border-strong text-13 font-semibold text-fg">{initials(p.name)}</span>
            <span className="min-w-0 flex-1">
              <span className="flex items-center justify-between gap-2">
                <span className="truncate text-14 font-medium text-fg">{p.name}</span>
                <span className="flex-none rounded-full bg-selected px-2 py-0.5 text-11 font-medium text-fg-2">Add</span>
              </span>
              <span className="mt-0.5 line-clamp-2 block text-12 text-fg-secondary">{p.description}</span>
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}

function ConnectorDetail({ connector: c, personas }: { connector: Connector; personas: Persona[] }) {
  const update = useUpdateConnector();
  const test = useTestConnector();
  const authorize = useAuthorizeConnector();
  const remove = useDeleteConnector();
  const [token, setToken] = useState("");
  const [clientId, setClientId] = useState(c.oauth_client_id ?? "");
  const [clientSecret, setClientSecret] = useState("");
  const [scopes, setScopes] = useState((c.oauth_scopes ?? []).join(", "));
  const nextScopes = splitScopes(scopes);
  const prevScopes = c.oauth_scopes ?? [];
  const oauthUnchanged =
    clientId.trim() === (c.oauth_client_id ?? "") &&
    !clientSecret.trim() &&
    nextScopes.length === prevScopes.length &&
    nextScopes.every((s, i) => s === prevScopes[i]);
  const setPolicy = (policies: Record<string, Policy>) => update.mutate({ id: c.id, patch: { revision: c.revision, policies } });
  const setPersona = (id: string, on: boolean) => update.mutate({ id: c.id, patch: { revision: c.revision, persona_ids: on ? [...c.persona_ids, id] : c.persona_ids.filter((x) => x !== id) } });
  const reads = Object.fromEntries(c.tools.filter((t) => !t.write).map((t) => [t.name, "allow" as Policy]));
  async function signIn() {
    const win = signInWindow();
    try {
      const res = await authorize.mutateAsync(c.id);
      finishSignIn(win, res.authorize_url);
    } catch {
      win?.close();
    }
  }
  const error = update.error ?? test.error ?? authorize.error ?? remove.error;
  return (
    <aside aria-label={`${c.name} settings`} data-testid="connector-detail" className="flex w-[440px] flex-none flex-col gap-4 rounded-lg border border-border bg-panel p-4 max-lg:w-full">
      <h3 className="text-18 font-semibold text-fg">{c.name}</h3>
      {c.last_error && <p className="text-13 text-pill-human-fg">{c.last_error}</p>}
      <Field label="Server URL"><p className="break-all rounded-md border border-border-strong bg-surface px-3 py-2 font-mono text-13 text-fg-2">{c.url}</p></Field>
      <Field label="Sign-in">
        {c.auth_kind === "oauth" ? (
          <div className="flex flex-col gap-2.5">
            <div className="flex items-center justify-between rounded-md border border-border bg-surface px-3 py-2">
              <span className="text-12 text-fg-tertiary">OAuth · stored encrypted</span>
              <button type="button" className="text-13 text-accent hover:underline" disabled={authorize.isPending} onClick={signIn}>Reconnect</button>
            </div>
            <TextInput mono aria-label="OAuth client ID" placeholder="OAuth client ID (optional if server supports dynamic registration)" value={clientId} onChange={(e) => setClientId(e.target.value)} />
            <TextInput type="password" aria-label="OAuth client secret" autoComplete="off" placeholder={c.has_oauth_client_secret ? "Replace client secret" : "Client secret (optional)"} value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} />
            <div className="flex gap-2">
              <TextInput mono aria-label="OAuth scopes" placeholder="OAuth scopes (comma or space separated)" value={scopes} onChange={(e) => setScopes(e.target.value)} />
              <Button
                variant="outline"
                disabled={oauthUnchanged || update.isPending}
                onClick={() => update.mutate(
                  {
                    id: c.id,
                    patch: {
                      revision: c.revision,
                      oauth_client_id: clientId.trim(),
                      ...(clientSecret.trim() ? { oauth_client_secret: clientSecret.trim() } : {}),
                      oauth_scopes: nextScopes,
                    },
                  },
                  { onSuccess: () => setClientSecret("") },
                )}
              >
                Save
              </Button>
            </div>
          </div>
        ) : c.auth_kind === "token" ? (
          <div className="flex gap-2">
            <TextInput type="password" aria-label="New API token" autoComplete="off" placeholder="Replace API token" value={token} onChange={(e) => setToken(e.target.value)} />
            <Button variant="outline" disabled={!token.trim() || update.isPending} onClick={() => update.mutate({ id: c.id, patch: { revision: c.revision, token } }, { onSuccess: () => setToken("") })}>Save</Button>
          </div>
        ) : (
          <p className="text-12 text-fg-tertiary">None</p>
        )}
      </Field>
      <section className="flex flex-col gap-2">
        <h4 className="text-14 font-medium text-fg">Who can use it</h4>
        <ul className="rounded-lg border border-border bg-surface">
          {personas.map((p) => (
            <li key={p.id} className="flex items-center gap-2.5 border-b border-border-row px-3 py-2 last:border-b-0">
              <PersonaAvatar persona={p} size={20} />
              <span className="min-w-0 flex-1 truncate text-13 text-fg-2">{p.name}</span>
              <Toggle label={`${p.name} can use ${c.name}`} checked={c.persona_ids.includes(p.id)} disabled={update.isPending} onChange={(on) => setPersona(p.id, on)} />
            </li>
          ))}
          {personas.length === 0 && <li className="px-3 py-2 text-12 text-fg-secondary">Create a persona to give it access.</li>}
        </ul>
      </section>
      <section className="flex flex-col gap-2">
        <div className="flex items-center gap-2">
          <h4 className="text-14 font-medium text-fg">Tools</h4>
          <span className="flex-1 text-12 text-fg-tertiary">{c.tools.length}</span>
          {Object.keys(reads).length > 0 && <button type="button" className="text-12 text-accent hover:underline" onClick={() => setPolicy(reads)}>Set all reads to Allow</button>}
        </div>
        <ul className="max-h-[360px] overflow-y-auto rounded-lg border border-border bg-surface">
          {c.tools.map((t) => (
            <li key={t.name} title={t.description} data-testid="connector-tool" className="flex items-center gap-2 border-b border-border-row px-3 py-2 last:border-b-0">
              <span className="min-w-0 flex-1 truncate font-mono text-13 text-fg-2">{t.name}</span>
              <span className={cx("flex-none rounded-full px-2 py-0.5 text-11", t.write ? "bg-pill-human-bg text-pill-human-fg" : "bg-pill-neutral-bg text-pill-neutral-fg")}>{t.write ? "Write" : "Read"}</span>
              <Segmented small label={`Permission for ${t.name}`} options={POLICIES} value={t.policy} onChange={(v) => setPolicy({ [t.name]: v })} />
            </li>
          ))}
          {c.tools.length === 0 && <li className="px-3 py-2 text-12 text-fg-secondary">No tools found yet. Test the connection after signing in.</li>}
        </ul>
      </section>
      {error && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(error)}</p>}
      <div className="flex items-center justify-between border-t border-border-subtle pt-3">
        <button type="button" className="text-13 text-pill-blocked-fg hover:underline" disabled={remove.isPending} onClick={async () => { if (await confirmAction({ title: `Remove ${c.name}?`, body: "Personas lose its tools right away.", confirmLabel: "Remove connector" })) remove.mutate(c.id); }}>Remove connector</button>
        <Button variant="outline" disabled={test.isPending} onClick={() => test.mutate(c.id)}>{test.isPending ? "Testing…" : "Test connection"}</Button>
      </div>
    </aside>
  );
}

/** Adds an MCP server. With a proposal or preset, it's prefilled, and the person still reviews and signs in. */
export function AddConnectorDialog({ proposal, preset, presets, onClose }: { proposal?: Schemas["ConnectorProposal"]; preset?: Preset; presets?: Preset[]; onClose: () => void }) {
  const [name, setName] = useState(preset?.name ?? proposal?.name ?? "");
  const [url, setUrl] = useState(preset?.url ?? proposal?.url ?? "");
  const [auth, setAuth] = useState<Auth>(preset?.auth_kind ?? proposal?.auth_kind ?? "oauth");
  const [token, setToken] = useState("");
  const [clientId, setClientId] = useState("");
  const [clientSecret, setClientSecret] = useState("");
  const [scopes, setScopes] = useState((preset?.default_scopes ?? []).join(", "));
  const matchedPreset = preset?.url && trimSlash(preset.url) === trimSlash(url)
    ? preset
    : presets?.find((item) => trimSlash(item.url) === trimSlash(url));
  const callbackUrl = typeof window !== "undefined" ? `${window.location.origin}/api/v1/connector-oauth/callback` : "/api/v1/connector-oauth/callback";
  const probe = useProbeConnector();
  const create = useCreateConnector();
  const check = () => url.trim() && probe.mutate({ url, ...(auth === "token" && token ? { token } : {}) });
  const p = probe.data;
  async function connect() {
    const win = auth === "oauth" ? signInWindow() : null;
    const parsedScopes = splitScopes(scopes);
    try {
      const res = await create.mutateAsync({
        name,
        url,
        auth_kind: auth,
        ...(auth === "token" ? { token } : {}),
        ...(auth === "oauth" && clientId.trim() ? { oauth_client_id: clientId.trim() } : {}),
        ...(auth === "oauth" && clientSecret.trim() ? { oauth_client_secret: clientSecret.trim() } : {}),
        ...(auth === "oauth" && parsedScopes.length ? { oauth_scopes: parsedScopes } : {}),
        ...(proposal ? { proposal_id: proposal.id } : {}),
      });
      finishSignIn(win, res.authorize_url);
      onClose();
    } catch {
      win?.close();
    }
  }
  const ready = Boolean(
    name.trim() &&
    url.trim() &&
    (auth !== "token" || token.trim()) &&
    (auth !== "oauth" || !matchedPreset?.oauth_client_required || clientId.trim()) &&
    !create.isPending,
  );
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content aria-describedby={undefined} className="fixed left-1/2 top-[12vh] z-50 flex max-h-[82vh] w-[min(560px,calc(100%-32px))] -translate-x-1/2 flex-col gap-4 overflow-y-auto rounded-2xl border border-border-strong bg-surface-raised p-6 shadow-float">
          <div className="flex items-center justify-between">
            <Dialog.Title className="type-heading">Add connector</Dialog.Title>
            <Dialog.Close asChild><IconButton icon="x" label="Close" /></Dialog.Close>
          </div>
          <Field label="Name" htmlFor="connector-name"><TextInput id="connector-name" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="MCP server URL" htmlFor="connector-url">
            <TextInput
              id="connector-url"
              mono
              value={url}
              placeholder="https://example.com/mcp"
              onChange={(e) => {
                const nextUrl = e.target.value;
                setUrl(nextUrl);
                probe.reset();
                const nextPreset = presets?.find((item) => trimSlash(item.url) === trimSlash(nextUrl));
                if (nextPreset?.default_scopes.length && !scopes.trim()) {
                  setScopes(nextPreset.default_scopes.join(", "));
                }
              }}
              onBlur={check}
            />
          </Field>
          <Field label="Sign-in">
            <Segmented label="Sign-in" value={auth} onChange={setAuth} options={[{ value: "oauth", label: "OAuth" }, { value: "token", label: "API token" }, { value: "none", label: "None" }]} />
          </Field>
          {auth === "oauth" && (
            <>
              {matchedPreset?.setup_hint && (
                <div className="rounded-md border border-border bg-surface px-3 py-2.5 text-12 text-fg-secondary">
                  <p>{matchedPreset.setup_hint}</p>
                  <p className="mt-1.5 text-fg-tertiary">Callback URL: <code className="break-all font-mono text-fg-2">{callbackUrl}</code></p>
                </div>
              )}
              <Field label={matchedPreset?.oauth_client_required ? "OAuth client ID" : "OAuth client ID (optional)"} htmlFor="connector-client-id">
                <TextInput id="connector-client-id" mono value={clientId} placeholder="123456-abc.apps.googleusercontent.com" onChange={(e) => setClientId(e.target.value)} />
              </Field>
              <Field label="OAuth client secret (optional)" htmlFor="connector-client-secret">
                <TextInput id="connector-client-secret" type="password" autoComplete="off" value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} />
              </Field>
              <Field label="OAuth scopes (optional)" htmlFor="connector-scopes">
                <TextInput id="connector-scopes" mono value={scopes} placeholder="https://www.googleapis.com/auth/drive.readonly" onChange={(e) => setScopes(e.target.value)} />
              </Field>
            </>
          )}
          {auth === "token" && <Field label="API token" htmlFor="connector-token"><TextInput id="connector-token" type="password" autoComplete="off" value={token} onChange={(e) => setToken(e.target.value)} onBlur={check} /></Field>}
          <div className="rounded-md border border-border bg-surface px-3 py-2.5 text-13" aria-live="polite">
            {probe.isPending ? (
              <p className="text-fg-secondary">Checking the server…</p>
            ) : probe.isError ? (
              <p className="text-pill-blocked-fg">{errorText(probe.error)}</p>
            ) : p?.needs_auth ? (
              <p className="text-fg-2">Found the server. It needs you to sign in.</p>
            ) : p?.reachable && !p.error ? (
              <p className="text-fg-2">Found the server: {p.tools} tools</p>
            ) : p?.error ? (
              <p className="text-pill-blocked-fg">{p.error}</p>
            ) : null}
            <p className="mt-1 text-12 text-fg-tertiary">{proposal?.proposed_by ? `${proposal.proposed_by.name} gets access. Write tools start on Ask.` : "Personas get no access until you turn it on. Write tools start on Ask."}</p>
          </div>
          {create.isError && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(create.error)}</p>}
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button variant="primary" disabled={!ready} onClick={connect}>Connect</Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/** A persona's profile: which connectors it may use. The same setting as "Who can use it". */
export function PersonaConnectors({ personaId }: { personaId: string }) {
  const list = useConnectors();
  const update = useUpdateConnector();
  const rows = list.data?.connectors ?? [];
  if (!rows.length) return null;
  const flip = (c: Connector, on: boolean) => update.mutate({ id: c.id, patch: { revision: c.revision, persona_ids: on ? c.persona_ids.filter((x) => x !== personaId) : [...c.persona_ids, personaId] } });
  return (
    <section aria-label="Persona connectors" className="flex flex-col gap-3 rounded-xl border border-border bg-surface px-[18px] py-3.5">
      <div className="flex items-center justify-between">
        <h3 className="type-heading text-fg">Connectors</h3>
        <Link href="/settings?section=connectors" className="text-13 text-accent hover:underline">Manage connectors</Link>
      </div>
      <div className="flex flex-wrap gap-2">
        {rows.map((c) => {
          const on = c.persona_ids.includes(personaId);
          return (
            <button key={c.id} type="button" aria-pressed={on} disabled={update.isPending} onClick={() => flip(c, on)} className={cx("rounded-full border px-3 py-1 text-12", on ? "border-accent bg-accent-soft text-fg" : "border-border-strong bg-surface-raised text-fg-secondary hover:bg-hover")}>
              {c.name}
            </button>
          );
        })}
      </div>
    </section>
  );
}
