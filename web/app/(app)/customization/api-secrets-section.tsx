"use client";

import { useState, type KeyboardEvent } from "react";
import { Dialog } from "radix-ui";
import type { Schemas } from "@/lib/api/client";
import { type Persona } from "@/lib/api/persona-hooks";
import { useApiSecretCalls, useApiSecrets, useCreateApiSecret, useDeleteApiSecret, useSignInApiSecret, useUpdateApiSecret, type ApiSecret } from "@/lib/api/secret-hooks";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { expiryPill, expiryText, handleFor, hostOf, jwtExpiry, OAUTH_PRESETS, oauthStatus, PLACEMENTS, POLICIES, READ_METHODS, SECRET_KINDS, sentAs, splitScopes, WRITE_METHODS, type Placement, type Policy, type SecretKind } from "@/lib/secrets-ui";
import { Button, IconButton } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, Field, Skeleton, TextInput } from "@/components/ui/primitives";
import { PersonaAvatar } from "../chat/_components/persona";
import { confirmAction } from "@/components/ui/confirm";
import { LoadingLines } from "@/components/ui/loading";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** Opened before any await, so the browser treats it as the person's click (as Connectors does). */
function signInWindow() {
  return window.open("", "_blank", "width=560,height=720");
}

function finishSignIn(win: Window | null, link?: string) {
  if (!win) return;
  if (link && /^https?:/.test(link)) win.location.href = link;
  else win.close();
}

const PILL = { done: "bg-pill-done-bg text-pill-done-fg", human: "bg-pill-human-bg text-pill-human-fg", blocked: "bg-pill-blocked-bg text-pill-blocked-fg" } as const;

function KeyTile({ muted }: { muted?: boolean }) {
  return (
    <span className={cx("grid size-[34px] flex-none place-items-center rounded-lg", muted ? "bg-selected text-fg-secondary" : "bg-pill-human-bg text-pill-human-fg")}>
      <Icon name="key" size={16} />
    </span>
  );
}

/** Secrets the person's personas may use in API calls: the list, and the selected one's hosts, access, permissions and activity. */
export function ApiSecretsSection({ personas, initialId }: { personas: Persona[]; initialId?: string }) {
  const list = useApiSecrets();
  const [adding, setAdding] = useState(false);
  const [selectedId, setSelectedId] = useState<string | undefined>(initialId);
  const rows = list.data?.secrets ?? [];
  const selected = rows.find((s) => s.id === selectedId) ?? rows[0];
  const readOnly = list.data ? !list.data.key_configured : false;
  return (
    <section aria-label="Secrets" className="flex flex-col gap-5">
      <header className="flex items-center gap-4">
        <span className="grid size-[72px] flex-none place-items-center rounded-full bg-selected text-fg-secondary"><Icon name="key" size={28} /></span>
        <div className="min-w-0 flex-1">
          <h2 className="type-heading">Secrets</h2>
          <p className="text-13 text-fg-secondary">Tokens and keys your personas can use in API calls without ever seeing them.</p>
        </div>
        <Button variant="primary" icon="plus" disabled={readOnly} onClick={() => setAdding(true)}>Add secret</Button>
      </header>
      {readOnly && (
        <Banner tone="human" title="Secrets can’t be stored until SECRETS_KEY is set">
          Add <code>SECRETS_KEY=$(openssl rand -base64 32)</code> to <code>.env</code> and restart the API.
        </Banner>
      )}
      {list.isError ? (
        <Banner tone="blocked" title="Couldn’t load secrets">{errorText(list.error)}</Banner>
      ) : !list.data ? (
        <Skeleton className="h-40" />
      ) : rows.length === 0 ? (
        <p className="rounded-lg border border-border bg-surface px-4 py-6 text-center text-13 text-fg-secondary">
          No secrets yet. Add a token or API key, choose the hosts it may be sent to, then turn it on for a persona.
        </p>
      ) : (
        <div className="flex gap-5 max-lg:flex-col">
          <ul className="flex min-w-0 flex-1 flex-col self-start overflow-hidden rounded-lg border border-border bg-surface max-lg:w-full">
            {rows.map((s) => {
              const pill = oauthStatus(s.oauth) ?? expiryPill(s.expires_at);
              return (
                <li key={s.id} className="border-b border-border-row last:border-b-0">
                  <button type="button" data-testid="secret-row" aria-current={s.id === selected?.id} onClick={() => setSelectedId(s.id)} className={cx("flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-hover", s.id === selected?.id && "bg-selected")}>
                    <KeyTile muted={!pill || pill.tone === "done"} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-14 font-medium text-fg">{s.name}</span>
                      <span className="block truncate text-12 text-fg-secondary">
                        {s.allowed_hosts[0]}{s.allowed_hosts.length > 1 && ` +${s.allowed_hosts.length - 1}`} · {s.persona_ids.length ? `${s.persona_ids.length} ${s.persona_ids.length === 1 ? "persona" : "personas"}` : "No personas yet"}
                      </span>
                    </span>
                    {pill && <span className={cx("flex-none rounded-full px-2.5 py-0.5 text-11", PILL[pill.tone])}>{pill.label}</span>}
                  </button>
                </li>
              );
            })}
          </ul>
          {selected && <SecretDetail key={selected.id} secret={selected} personas={personas} />}
        </div>
      )}
      {adding && <AddSecretDialog onClose={() => setAdding(false)} />}
    </section>
  );
}

function SecretDetail({ secret: s, personas }: { secret: ApiSecret; personas: Persona[] }) {
  const update = useUpdateApiSecret();
  const remove = useDeleteApiSecret();
  const [value, setValue] = useState("");
  const [replacing, setReplacing] = useState(false);
  const [host, setHost] = useState("");
  const [hostError, setHostError] = useState("");
  const patch = (p: Omit<Schemas["ApiSecretPatch"], "revision">, onSuccess?: () => void) => update.mutate({ id: s.id, patch: { revision: s.revision, ...p } }, { onSuccess });
  const setPersona = (id: string, on: boolean) => patch({ persona_ids: on ? [...s.persona_ids, id] : s.persona_ids.filter((x) => x !== id) });
  const addHost = () => {
    const h = hostOf(host);
    if (!h) return setHostError("Enter a hostname like api.example.com (no wildcards).");
    setHostError("");
    if (!s.allowed_hosts.includes(h)) patch({ allowed_hosts: [...s.allowed_hosts, h] }, () => setHost(""));
    else setHost("");
  };
  const error = update.error ?? remove.error;
  return (
    <aside aria-label={`${s.name} settings`} data-testid="secret-detail" className="flex w-[440px] flex-none flex-col gap-4 rounded-lg border border-border bg-panel p-4 max-lg:w-full">
      <div>
        <h3 className="text-18 font-semibold text-fg">{s.name}</h3>
        <p className="text-12 text-fg-secondary">Handle <code className="font-mono text-fg">{s.handle}</code>, the only name personas see</p>
      </div>
      {s.kind === "oauth" ? <SignInField secret={s} /> : <Field label="Value">
        {replacing ? (
          <div className="flex gap-2">
            <TextInput type="password" aria-label="New value" autoComplete="off" spellCheck={false} placeholder="Paste the new value" value={value} onChange={(e) => setValue(e.target.value)} />
            <Button variant="outline" disabled={!value || update.isPending} onClick={() => patch({ value }, () => { setValue(""); setReplacing(false); })}>Save</Button>
          </div>
        ) : (
          <div className="flex items-center justify-between rounded-md border border-border bg-surface px-3 py-2">
            <span className="text-12 text-fg-tertiary">Stored encrypted · {expiryText(s.expires_at)}</span>
            <button type="button" className="text-13 text-accent hover:underline" onClick={() => setReplacing(true)}>Replace</button>
          </div>
        )}
      </Field>}
      <Field label="Sent as"><p className="rounded-md border border-border-strong bg-surface px-3 py-2 font-mono text-13 text-fg-2">{sentAs(s.placement, s.placement_key, s.handle)}</p></Field>
      <Field label="Allowed hosts" hint="HTTPS only. Exact hosts: a subdomain needs its own entry.">
        <div className="flex flex-wrap items-center gap-1.5" data-testid="secret-hosts">
          {s.allowed_hosts.map((h) => (
            <span key={h} className="flex items-center gap-1 rounded-full border border-border bg-surface py-0.5 pl-2.5 pr-1 font-mono text-12 text-fg">
              {h}
              {s.allowed_hosts.length > 1 && <IconButton icon="x" label={`Remove ${h}`} size={12} onClick={() => patch({ allowed_hosts: s.allowed_hosts.filter((x) => x !== h) })} />}
            </span>
          ))}
        </div>
        <div className="mt-2 flex gap-2">
          <TextInput mono aria-label="Add a host" placeholder="staging.example.com" value={host} onChange={(e) => { setHost(e.target.value); setHostError(""); }} onKeyDown={(e) => e.key === "Enter" && addHost()} />
          <Button variant="outline" disabled={!host.trim() || update.isPending} onClick={addHost}>Add</Button>
        </div>
        {hostError && <p className="mt-1 text-12 text-pill-blocked-fg">{hostError}</p>}
      </Field>
      <section className="flex flex-col gap-2">
        <h4 className="text-14 font-medium text-fg">Who can use it</h4>
        <ul className="rounded-lg border border-border bg-surface">
          {personas.map((p) => (
            <li key={p.id} className="flex items-center gap-2.5 border-b border-border-row px-3 py-2 last:border-b-0">
              <PersonaAvatar persona={p} size={20} />
              <span className="min-w-0 flex-1 truncate text-13 text-fg-2">{p.name}</span>
              <Toggle label={`${p.name} can use ${s.name}`} checked={s.persona_ids.includes(p.id)} disabled={update.isPending} onChange={(on) => setPersona(p.id, on)} />
            </li>
          ))}
          {personas.length === 0 && <li className="px-3 py-2 text-12 text-fg-secondary">Create a persona to give it access.</li>}
        </ul>
      </section>
      <section className="flex flex-col gap-2">
        <h4 className="text-14 font-medium text-fg">Requests</h4>
        <ul className="rounded-lg border border-border bg-surface">
          {([["Reads", READ_METHODS, "read_policy"], ["Writes", WRITE_METHODS, "write_policy"]] as const).map(([label, methods, field]) => (
            <li key={field} className="flex items-center gap-2 border-b border-border-row px-3 py-2 last:border-b-0">
              <span className="text-13 font-medium text-fg">{label}</span>
              <span className="min-w-0 flex-1 truncate font-mono text-11 text-fg-tertiary">{methods}</span>
              <Segmented small label={`${label} with ${s.name}`} options={POLICIES} value={s[field]} onChange={(v: Policy) => patch({ [field]: v })} />
            </li>
          ))}
        </ul>
      </section>
      <SecretActivity id={s.id} />
      {error && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(error)}</p>}
      <div className="border-t border-border-subtle pt-3">
        <button type="button" className="text-13 text-pill-blocked-fg hover:underline" disabled={remove.isPending} onClick={async () => { if (await confirmAction({ title: `Remove ${s.name}?`, body: "Personas lose access right away.", confirmLabel: "Remove secret" })) remove.mutate(s.id); }}>Remove secret</button>
      </div>
    </aside>
  );
}

/** An OAuth secret's sign-in: whether Vesper can get a token for it, and the button that (re)starts it. */
function SignInField({ secret: s }: { secret: ApiSecret }) {
  const signIn = useSignInApiSecret();
  const status = oauthStatus(s.oauth);
  if (!s.oauth || !status) return null;
  const start = async () => {
    const win = signInWindow();
    try {
      const res = await signIn.mutateAsync(s.id);
      finishSignIn(win, res.authorize_url);
    } catch {
      finishSignIn(win);
    }
  };
  return (
    <Field label="Sign-in" hint="Vesper refreshes the access token itself; personas and apps never see it.">
      <div className="flex items-center justify-between gap-2 rounded-md border border-border bg-surface px-3 py-2" data-testid="secret-sign-in">
        <span className="min-w-0 text-12 text-fg-tertiary">
          <span className={cx("mr-1.5 rounded-full px-2 py-0.5 text-11", PILL[status.tone])}>{status.label}</span>
          {s.oauth.error ? s.oauth.error : s.oauth.signed_in_at ? `since ${ago(s.oauth.signed_in_at)}` : "Requests are refused until you sign in."}
        </span>
        <button type="button" className="flex-none text-13 text-accent hover:underline" disabled={signIn.isPending} onClick={start}>{status.action}</button>
      </div>
      <p className="mt-1 truncate font-mono text-11 text-fg-tertiary" title={s.oauth.scopes.join(" ")}>
        {s.oauth.client_id}{s.oauth.scopes.length > 0 && ` · ${s.oauth.scopes.join(" ")}`}
      </p>
      {signIn.isError && <p role="alert" className="mt-1 text-12 text-pill-blocked-fg">{errorText(signIn.error)}</p>}
    </Field>
  );
}

const DECISION: Record<Schemas["ApiSecretCall"]["decision"], { label: string; className: string }> = {
  auto: { label: "Auto", className: "text-fg-2" },
  approved: { label: "Approved", className: "text-fg-2" },
  denied: { label: "Denied", className: "text-pill-blocked-fg" },
  blocked: { label: "Blocked", className: "text-pill-blocked-fg" },
};

/** The latest requests made with a secret, sent or not. Never the value, and no query strings. */
function SecretActivity({ id }: { id: string }) {
  const calls = useApiSecretCalls(id);
  const rows = calls.data?.calls ?? [];
  return (
    <section className="flex flex-col gap-2" aria-label="Activity">
      <h4 className="text-14 font-medium text-fg">Activity</h4>
      {rows.length === 0 ? (
        calls.isPending ? <LoadingLines /> : <p className="text-12 text-fg-secondary">Not used yet.</p>
      ) : (
        <ul className="max-h-[260px] overflow-y-auto rounded-lg border border-border bg-surface" data-testid="secret-activity">
          {rows.map((c) => (
            <li key={c.id} title={c.error || undefined} className="flex items-center gap-2 border-b border-border-row px-3 py-2 text-12 last:border-b-0">
              <span className="w-[68px] flex-none text-fg-tertiary">{ago(c.created_at)}</span>
              <span className="w-[72px] flex-none truncate text-fg-secondary">{c.persona_name || "—"}</span>
              <span className="min-w-0 flex-1 truncate font-mono text-12 text-fg">{c.method} {c.host}{c.path}</span>
              <span className={cx("flex-none tabular-nums", c.status && c.status < 400 ? "text-pill-done-fg" : c.status ? "text-pill-human-fg" : "text-fg-tertiary")}>{c.status ?? "—"}</span>
              <span className={cx("w-[64px] flex-none text-right", DECISION[c.decision].className)}>{DECISION[c.decision].label}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/** Adds a secret. With a proposal it's prefilled from what the persona asked for; the person still enters the value and confirms. */
export function AddSecretDialog({ proposal, onClose }: { proposal?: Schemas["ApiSecretProposal"]; onClose: () => void }) {
  const [name, setName] = useState(proposal?.name ?? "");
  const [kind, setKind] = useState<SecretKind>("static");
  const [preset, setPreset] = useState(OAUTH_PRESETS[0].value);
  const [authorizeUrl, setAuthorizeUrl] = useState("");
  const [tokenUrl, setTokenUrl] = useState("");
  const [clientId, setClientId] = useState("");
  const [clientSecret, setClientSecret] = useState("");
  const [scopes, setScopes] = useState("");
  const [value, setValue] = useState("");
  const [placement, setPlacement] = useState<Placement>(proposal?.placement ?? "bearer");
  const [key, setKey] = useState(proposal?.placement_key ?? "");
  const [hosts, setHosts] = useState<string[]>(proposal ? [proposal.host] : []);
  const [host, setHost] = useState("");
  const [hostError, setHostError] = useState("");
  const create = useCreateApiSecret();
  const signIn = useSignInApiSecret();
  const redirectUri = useApiSecrets().data?.oauth_redirect_uri;
  const oauth = kind === "oauth";
  const p = OAUTH_PRESETS.find((x) => x.value === preset) ?? OAUTH_PRESETS[0];
  const endpoints = p.value === "custom" ? { authorize_url: authorizeUrl.trim(), token_url: tokenUrl.trim() } : { authorize_url: p.authorize_url, token_url: p.token_url };
  const pickPreset = (v: string) => {
    setPreset(v);
    const next = OAUTH_PRESETS.find((x) => x.value === v);
    if (next?.hosts.length && hosts.length === 0) setHosts(next.hosts);
  };
  const pickKind = (k: SecretKind) => {
    setKind(k);
    if (k === "oauth") {
      setPlacement("bearer");
      if (p.hosts.length && hosts.length === 0) setHosts(p.hosts);
    }
  };
  const exp = jwtExpiry(value);
  const handle = handleFor(name);
  const addHost = () => {
    if (!host.trim()) return;
    const h = hostOf(host);
    if (!h) return setHostError("Enter a hostname like api.example.com (no wildcards).");
    setHostError("");
    setHosts((hs) => (hs.includes(h) ? hs : [...hs, h]));
    setHost("");
  };
  const onHostKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter" || e.key === ",") {
      e.preventDefault();
      addHost();
    }
  };
  // A typed-but-not-added host counts, so Save doesn't silently drop it.
  const pendingHost = host.trim() ? hostOf(host) : null;
  const allHosts = pendingHost && !hosts.includes(pendingHost) ? [...hosts, pendingHost] : hosts;
  const needsKey = placement === "header" || placement === "query";
  const credsReady = oauth ? Boolean(clientId.trim() && endpoints.authorize_url && endpoints.token_url && (!p.scopes_required || splitScopes(scopes).length > 0)) : Boolean(value);
  const busy = create.isPending || signIn.isPending;
  const ready = name.trim() && credsReady && allHosts.length > 0 && (!needsKey || key.trim()) && !busy && (!host.trim() || pendingHost);
  const save = async () => {
    if (!oauth) {
      create.mutate(
        { name, value, placement, ...(needsKey ? { placement_key: key } : {}), allowed_hosts: allHosts, ...(proposal ? { proposal_id: proposal.id } : {}) },
        { onSuccess: onClose },
      );
      return;
    }
    // Saved first, then signed in: a sign-in that's abandoned leaves a secret to retry from its detail.
    const win = signInWindow();
    try {
      const made = await create.mutateAsync({
        name, placement: "bearer", allowed_hosts: allHosts,
        oauth: { ...endpoints, client_id: clientId.trim(), ...(clientSecret.trim() ? { client_secret: clientSecret.trim() } : {}), scopes: splitScopes(scopes) },
        ...(proposal ? { proposal_id: proposal.id } : {}),
      });
      const res = await signIn.mutateAsync(made.id);
      finishSignIn(win, res.authorize_url);
      onClose();
    } catch {
      finishSignIn(win);
    }
  };
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content aria-describedby={undefined} className="fixed left-1/2 top-[8vh] z-50 flex max-h-[84vh] w-[min(560px,calc(100%-32px))] -translate-x-1/2 flex-col gap-4 overflow-y-auto rounded-2xl border border-border-strong bg-surface-raised p-6 shadow-float">
          <div className="flex items-center justify-between">
            <Dialog.Title className="type-heading">Add secret</Dialog.Title>
            <Dialog.Close asChild><IconButton icon="x" label="Close" /></Dialog.Close>
          </div>
          <Field label="Name" htmlFor="secret-name" hint={handle ? `Personas see it as ${handle}` : undefined}>
            <TextInput id="secret-name" value={name} maxLength={60} placeholder="Acme API JWT" onChange={(e) => setName(e.target.value)} />
          </Field>
          {!proposal && (
            <Field label="Type">
              <Segmented label="Type" value={kind} onChange={pickKind} options={SECRET_KINDS} />
            </Field>
          )}
          {oauth ? (
            <>
              <Field label="Provider">
                <Segmented label="Provider" value={preset} onChange={pickPreset} options={OAUTH_PRESETS} />
              </Field>
              {p.value === "custom" && (
                <>
                  <Field label="Authorization URL" htmlFor="secret-authorize-url">
                    <TextInput id="secret-authorize-url" mono value={authorizeUrl} placeholder="https://auth.example.com/oauth/authorize" onChange={(e) => setAuthorizeUrl(e.target.value)} />
                  </Field>
                  <Field label="Token URL" htmlFor="secret-token-url">
                    <TextInput id="secret-token-url" mono value={tokenUrl} placeholder="https://auth.example.com/oauth/token" onChange={(e) => setTokenUrl(e.target.value)} />
                  </Field>
                </>
              )}
              <Field label="Client ID" htmlFor="secret-client-id" hint="From the OAuth client you registered with the provider.">
                <TextInput id="secret-client-id" mono value={clientId} autoComplete="off" spellCheck={false} onChange={(e) => setClientId(e.target.value)} />
              </Field>
              <Field label="Client secret" htmlFor="secret-client-secret" hint="Stored encrypted and never shown again.">
                <TextInput id="secret-client-secret" type="password" autoComplete="off" spellCheck={false} value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} />
              </Field>
              <Field label="Scopes" htmlFor="secret-scopes" hint={p.scopes_required ? `Separate with spaces or commas. ${p.label} needs at least one.` : "Separate with spaces or commas."}>
                <TextInput id="secret-scopes" mono value={scopes} placeholder={p.scopes_hint} onChange={(e) => setScopes(e.target.value)} />
              </Field>
              {redirectUri && (
                <div className="-mt-1 rounded-md border border-border bg-surface px-3 py-2 text-12 text-fg-secondary" data-testid="oauth-redirect">
                  Add this redirect URI to the OAuth client:
                  <code className="mt-1 block select-all break-all font-mono text-fg">{redirectUri}</code>
                </div>
              )}
            </>
          ) : (
            <Field label="Value" htmlFor="secret-value" hint="Stored encrypted. Vesper never shows it again, and personas never see it.">
              <TextInput id="secret-value" type="password" autoComplete="off" spellCheck={false} value={value} onChange={(e) => setValue(e.target.value)} />
            </Field>
          )}
          {!oauth && exp && (
            <p className="-mt-2 flex items-center gap-1.5 text-12 text-pill-done-fg" data-testid="jwt-expiry">
              <Icon name="check" size={13} /> Looks like a JWT · {expiryText(exp).toLowerCase()}
            </p>
          )}
          {!oauth && (
            <Field label="Send it as">
              <Segmented label="Send it as" value={placement} onChange={setPlacement} options={PLACEMENTS} />
            </Field>
          )}
          {needsKey && (
            <Field label={placement === "header" ? "Header name" : "Query parameter"} htmlFor="secret-key">
              <TextInput id="secret-key" mono value={key} placeholder={placement === "header" ? "X-Api-Key" : "api_key"} onChange={(e) => setKey(e.target.value)} />
            </Field>
          )}
          {placement === "basic" && <p className="-mt-2 text-12 text-fg-tertiary">Enter the value as username:password.</p>}
          <p className="-mt-2 font-mono text-12 text-fg-secondary" data-testid="secret-preview">→ {sentAs(placement, key, handle)}</p>
          <Field label="Allowed hosts" htmlFor="secret-host">
            <div className="flex flex-wrap items-center gap-1.5 rounded-md border border-border-strong bg-surface px-2 py-1.5">
              {hosts.map((h) => (
                <span key={h} className="flex items-center gap-1 rounded-full bg-accent-soft py-0.5 pl-2.5 pr-1 font-mono text-12 text-fg">
                  {h}
                  <IconButton icon="x" label={`Remove ${h}`} size={12} onClick={() => setHosts((hs) => hs.filter((x) => x !== h))} />
                </span>
              ))}
              <input id="secret-host" className="min-w-[160px] flex-1 bg-transparent py-0.5 font-mono text-13 text-fg outline-none placeholder:text-fg-tertiary" placeholder={hosts.length ? "Add another host" : "api.example.com"}
                value={host} onChange={(e) => { setHost(e.target.value); setHostError(""); }} onKeyDown={onHostKey} onBlur={addHost} />
            </div>
          </Field>
          {hostError && <p className="-mt-2 text-12 text-pill-blocked-fg">{hostError}</p>}
          <div className="rounded-md border border-border bg-surface px-3 py-2.5 text-13 text-fg-secondary">
            Vesper adds the value on the server, and only to HTTPS requests to these hosts. Copies of it in a response are masked as far as Vesper can recognise them.
            <span className="mt-1 block text-12 text-fg-tertiary">{proposal?.proposed_by ? `${proposal.proposed_by.name} gets access. Reads run on their own; writes ask you first.` : "Personas get no access until you turn it on. Reads run on their own; writes ask you first."}</span>
          </div>
          {(create.isError || signIn.isError) && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(create.error ?? signIn.error)}</p>}
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button variant="primary" disabled={!ready} onClick={save}>{oauth ? "Save and sign in" : "Save"}</Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
