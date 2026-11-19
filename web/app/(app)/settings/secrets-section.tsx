"use client";

import { DropdownMenu } from "radix-ui";
import { useEffect, useRef, useState } from "react";
import { useBootstrap, useCancelSignIn, useDeleteSecret, useSecrets, useSetSecret, useSignIn, useStartSignIn, useSubmitSignInCode } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { CONNECTIONS, connectionState, missingConnections, otherSecrets, savedMessage, SIGN_IN_STEPS, signInView, type Connection, type SignInProvider } from "@/lib/settings";
import { Button, buttonClass, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Card, Field, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { MonoChip, SmallPill } from "@/components/domain/labels";
import { floatPanel } from "@/components/domain/pickers";
import { confirmAction } from "@/components/ui/confirm";

const buttonLinkClass = buttonClass("outline");

const sentence = (s: string) => (/[.!?]$/.test(s) ? s : `${s}.`);

type Target = { name: string; project: string; fixedName: boolean };
const targetKey = (t: Target) => `${t.name}|${t.project}|${t.fixedName}`;

/**
 * Provider credentials (LAZYAGENTS-44). Values are write-only: the API stores them
 * encrypted and returns names, scopes and timestamps only, never any part of a
 * value. The value input clears after saving and nothing is echoed back.
 */
export function SecretsSection({ hideKeyBanner = false }: { hideKeyBanner?: boolean } = {}) {
  const list = useSecrets();
  const del = useDeleteSecret();
  const [editing, setEditing] = useState<Target | null>(null);
  const [notice, setNotice] = useState("");
  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(""), 6000);
    return () => clearTimeout(t);
  }, [notice]);

  if (list.isPending) {
    return (
      <div aria-label="Loading provider credentials" className="space-y-3">
        <Skeleton className="h-14" />
        <Skeleton className="h-48" />
      </div>
    );
  }
  if (list.isError) {
    return (
      <Banner tone="blocked" title="Couldn’t load provider credentials" actions={<Button variant="outline" onClick={() => void list.refetch()}>Retry</Button>}>
        {sentence(list.error.message || "The API is unavailable")} Other sections keep working.
      </Banner>
    );
  }
  const d = list.data;
  const readOnly = !d.key_configured;
  const missing = missingConnections(d.secrets);
  const others = otherSecrets(d.secrets);
  const open = (t: Target) => {
    setNotice("");
    setEditing(t);
  };
  const saved = (name: string) => {
    setEditing(null);
    setNotice(savedMessage(name));
  };

  return (
    <div className="space-y-4">
      {!hideKeyBanner && readOnly && (
        <Banner tone="human" title="Credentials are read-only until SECRETS_KEY is set">
          Add <code>SECRETS_KEY=$(openssl rand -base64 32)</code> to <code>.env</code> and restart the API. Until then runs get no harness keys or git credentials.
        </Banner>
      )}
      {missing.map((c) => (
        <Banner key={c.name} tone="human" title={`${c.unlocks.join(" and ")} can’t run`}>
          <code>{c.name}</code> isn’t set. {c.without} The chat model picker marks those models unavailable. Runners on the local backend use the machine’s own CLI logins instead.
        </Banner>
      ))}
      {notice && (
        <p role="status" className="flex items-center gap-1.5 rounded-xl border border-border bg-surface px-3 py-2 text-13 text-pill-done-fg">
          <Icon name="check" size={13} /> {notice}
        </p>
      )}

      <Card title="Connections" bodyClassName="p-0">
        <ul>
          {CONNECTIONS.map((c, i) => (
            <ConnectionRow
              key={c.name}
              c={c}
              first={i === 0}
              state={connectionState(d.secrets, c.name)}
              readOnly={readOnly}
              signInAvailable={d.sign_in_available}
              editing={editing?.fixedName && editing.name === c.name && !editing.project ? editing : null}
              onEdit={() => open({ name: c.name, project: "", fixedName: true })}
              onDelete={async (id) => {
                if (await confirmAction({ title: `Delete ${c.name}?`, body: c.without, confirmLabel: "Delete" })) del.mutate(id);
              }}
              deleting={del.isPending}
              onCancel={() => setEditing(null)}
              onSaved={saved}
            />
          ))}
        </ul>
      </Card>

      <Card
        title="Other credentials"
        bodyClassName="p-0"
        action={
          <Button variant="outline" icon="plus" disabled={readOnly} onClick={() => open({ name: "", project: "", fixedName: false })}>
            Add credential
          </Button>
        }
      >
        {editing && !(editing.fixedName && !editing.project && CONNECTIONS.some((c) => c.name === editing.name)) && (
          <div className="border-b border-border-subtle px-[18px] py-3">
            <SecretForm key={targetKey(editing)} target={editing} known={d.known} onCancel={() => setEditing(null)} onSaved={saved} />
          </div>
        )}
        {others.length === 0 ? (
          <p className="px-[18px] py-4 text-13 text-fg-tertiary">
            No other secrets. Staging database URLs (db:migrate), deploy tokens and per-project overrides go here.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] border-collapse text-13">
              <thead>
                <tr className="text-left text-13 text-fg-tertiary">
                  <th className="px-[18px] py-2.5 font-normal">Name</th>
                  <th className="px-2 py-2.5 font-normal">Scope</th>
                  <th className="px-2 py-2.5 font-normal">Backs</th>
                  <th className="px-2 py-2.5 font-normal">Updated</th>
                  <th className="px-2 py-2.5 font-normal">Last used</th>
                  <th className="w-28" />
                </tr>
              </thead>
              <tbody>
                {others.map((s) => (
                  <tr key={s.id} className="border-t border-border-row">
                    <td className="px-[18px] py-2.5 font-mono text-13">{s.name}</td>
                    <td className="whitespace-nowrap px-2">
                      {s.project ? (
                        <span className="flex items-center gap-1.5 text-fg-secondary">
                          <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: s.project.color }} />
                          {s.project.name}
                        </span>
                      ) : (
                        <span className="text-fg-secondary">Workspace</span>
                      )}
                    </td>
                    <td className="px-2">{s.grants_scope ? <MonoChip>{s.grants_scope}</MonoChip> : <span className="text-fg-tertiary">–</span>}</td>
                    <td className="whitespace-nowrap px-2 text-12 text-fg-secondary">{ago(s.updated_at)}</td>
                    <td className="whitespace-nowrap px-2 text-12 text-fg-secondary">{s.last_used_at ? ago(s.last_used_at) : "Never"}</td>
                    <td className="pr-3">
                      <div className="flex items-center justify-end gap-1">
                      <Button variant="ghost" disabled={readOnly} aria-label={`Replace ${s.name}`} onClick={() => open({ name: s.name, project: s.project?.key ?? "", fixedName: true })}>
                        Replace
                      </Button>
                      <IconButton
                        icon="trash"
                        label={`Delete ${s.name}`}
                        disabled={del.isPending}
                        onClick={async () => {
                          if (await confirmAction({ title: `Delete ${s.name}?`, body: "Runs that need it will fail until it's set again.", confirmLabel: "Delete secret" })) del.mutate(s.id);
                        }}
                      />
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {del.isError && <p role="alert" className="px-[18px] pb-3 text-12 text-pill-blocked-fg">{del.error.message}</p>}
        <p className="border-t border-border-row px-[18px] py-2.5 text-12 text-fg-tertiary">
          No value column: the API returns names, scopes and timestamps only.
        </p>
      </Card>
    </div>
  );
}

function ConnectionRow({
  c,
  first,
  state,
  readOnly,
  signInAvailable,
  editing,
  onEdit,
  onDelete,
  deleting,
  onCancel,
  onSaved,
}: {
  c: Connection;
  first: boolean;
  state: ReturnType<typeof connectionState>;
  readOnly: boolean;
  signInAvailable: boolean;
  editing: Target | null;
  onEdit: () => void;
  onDelete: (id: string) => void;
  deleting: boolean;
  onCancel: () => void;
  onSaved: (name: string) => void;
}) {
  const on = state.state === "set";
  const start = useStartSignIn();
  const [signInId, setSignInId] = useState<string | null>(null);
  // Only for a key that isn't set yet: replacing one stays a paste.
  const canSignIn = !on && !!c.signIn && signInAvailable && !readOnly;
  const beginSignIn = () => {
    if (!c.signIn) return;
    start.mutate(c.signIn, { onSuccess: (s) => setSignInId(s.id) });
  };
  return (
    <li className={cx("px-[18px] py-3", !first && "border-t border-border-row", editing && "bg-hover/40")}>
      <div className="flex flex-wrap items-start gap-3">
        <span className="grid size-8 flex-none place-items-center rounded-md border border-border-strong bg-selected text-fg-secondary">
          <Icon name={c.icon} size={15} />
        </span>
        <span className="flex min-w-[150px] flex-1 flex-col">
          <span className="font-medium">{c.label}</span>
          <span className="font-mono text-12 text-fg-tertiary">{c.name}</span>
        </span>
        <span className="flex w-[130px] flex-col items-start gap-1">
          {on ? (
            <SmallPill tone="done">Set</SmallPill>
          ) : state.state === "projects" ? (
            <SmallPill tone="human">Set for {state.projects.length} space{state.projects.length === 1 ? "" : "s"}</SmallPill>
          ) : (
            <SmallPill tone={c.required ? "human" : "neutral"}>Not set</SmallPill>
          )}
          {on && <span className="text-12 text-fg-tertiary">Updated {ago(state.secret.updated_at)}</span>}
        </span>
        <span className="flex min-w-[200px] flex-[2] flex-col gap-1">
          <span className="flex flex-wrap gap-1.5" aria-label={`${on ? "Unlocks" : "Would unlock"}: ${c.unlocks.join(", ")}`}>
            {c.unlocks.map((u) => (
              <span
                key={u}
                className={cx(
                  "whitespace-nowrap rounded-[5px] border px-1.5 py-px text-12",
                  on ? "border-pill-done-bg bg-pill-done-bg/40 text-pill-done-fg" : "border-border text-fg-tertiary",
                )}
              >
                {on ? "✓" : "✕"} {u}
              </span>
            ))}
          </span>
          {on ? (
            <span className="text-12 text-fg-tertiary">{state.secret.last_used_at ? `Used ${ago(state.secret.last_used_at)}` : "Not used yet"}</span>
          ) : (
            !editing && <span className="text-12 text-fg-tertiary">{c.without}</span>
          )}
        </span>
        {!editing && !signInId && (
          <span className="flex items-center gap-1">
            {canSignIn && (
              <Button variant="primary" disabled={start.isPending} aria-label={`Sign in to ${c.label}`} onClick={beginSignIn}>
                {start.isPending ? "Starting…" : "Sign in"}
              </Button>
            )}
            <Button variant="outline" disabled={readOnly} aria-label={`${on ? "Replace" : "Add"} ${c.label} key`} onClick={onEdit}>
              {on ? "Replace" : "Add key"}
            </Button>
            {on && <IconButton icon="trash" label={`Delete ${c.name}`} disabled={deleting} onClick={() => onDelete(state.secret.id)} />}
          </span>
        )}
      </div>
      {editing && (
        <div className="mt-3 pl-11">
          <SecretForm key={targetKey(editing)} target={editing} onCancel={onCancel} onSaved={onSaved} hint={`Without it: ${c.without} Replacing a value takes effect on the next run.`} />
        </div>
      )}
      {start.isError && !signInId && (
        <p role="alert" className="mt-2 pl-11 text-12 text-pill-blocked-fg">{start.error.message}</p>
      )}
      {signInId && c.signIn && (
        <div className="mt-3 pl-11">
          <SignInPanel
            key={signInId}
            id={signInId}
            provider={c.signIn}
            label={c.label}
            onRetry={beginSignIn}
            onClose={() => {
              setSignInId(null);
              start.reset();
            }}
            onDone={() => {
              setSignInId(null);
              onSaved(c.name);
            }}
          />
        </div>
      )}
    </li>
  );
}

function SecretForm({
  target,
  known,
  hint,
  onCancel,
  onSaved,
}: {
  target: Target;
  known?: { name: string; description: string }[];
  hint?: string;
  onCancel: () => void;
  onSaved: (name: string) => void;
}) {
  const boot = useBootstrap();
  const set = useSetSecret();
  const [name, setName] = useState(target.name);
  const [value, setValue] = useState("");
  const [project, setProject] = useState(target.project);
  const valueRef = useRef<HTMLInputElement | HTMLTextAreaElement>(null);
  const nameRef = useRef<HTMLInputElement>(null);
  const id = `secret-${target.name || "new"}`.replace(/[^a-z0-9-]/gi, "-");
  const sshKey = name.trim().toLowerCase() === "git:ssh";
  useEffect(() => {
    (target.fixedName ? valueRef : nameRef).current?.focus();
  }, [target.fixedName]);
  const projects = boot.data?.projects.filter((p) => !p.archived) ?? [];
  // Replacing keeps the secret's scope; changing it would create a second secret.
  const lockedScope = target.fixedName ? (boot.data?.projects.find((p) => p.key === target.project)?.name ?? (target.project || "Workspace")) : null;

  return (
    <form
      className="flex flex-col gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        const n = name.trim();
        set.mutate(
          { name: n, value, project_key: project || undefined },
          {
            onSuccess: () => {
              setValue("");
              set.reset();
              onSaved(n);
            },
          },
        );
      }}
    >
      <div className="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] items-end gap-2">
        {!target.fixedName && (
          <Field label="Name" htmlFor={`${id}-name`}>
            <TextInput id={`${id}-name`} ref={nameRef} mono list={`${id}-known`} value={name} onChange={(e) => setName(e.target.value)} placeholder="db:staging" />
            <datalist id={`${id}-known`}>
              {known?.map((k) => <option key={k.name} value={k.name}>{k.description}</option>)}
            </datalist>
          </Field>
        )}
        <Field
          label={target.fixedName ? `New value for ${target.name}` : "Value"}
          htmlFor={`${id}-value`}
          hint={sshKey ? "Paste the complete private key, including BEGIN/END lines. Keep its line breaks. Passphrase-protected keys are not supported." : undefined}
        >
          {sshKey ? <TextArea
            id={`${id}-value`}
            ref={(el) => { valueRef.current = el; }}
            mono
            rows={5}
            autoComplete="off"
            autoCapitalize="none"
            spellCheck={false}
            aria-describedby={`${id}-value-hint`}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
          /> : <TextInput
            id={`${id}-value`}
            ref={(el) => { valueRef.current = el; }}
            type="password"
            autoComplete="off"
            spellCheck={false}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="Paste key. Stored encrypted, never shown again"
          />}
        </Field>
        <Field label="Scope" htmlFor={`${id}-project`}>
          {lockedScope !== null ? (
            <TextInput id={`${id}-project`} value={lockedScope} readOnly disabled />
          ) : (
            <DropdownMenu.Root>
              <DropdownMenu.Trigger asChild>
                <button id={`${id}-project`} type="button" className="flex h-[30px] items-center gap-2 rounded-md border border-border-strong bg-surface px-2.5 text-left text-13 hover:bg-hover">
                  <span className="flex-1 truncate">{projects.find((p) => p.key === project)?.name ?? "Workspace"}</span>
                  <Icon name="chev" size={12} className="text-fg-tertiary" />
                </button>
              </DropdownMenu.Trigger>
              <DropdownMenu.Portal>
                <DropdownMenu.Content align="start" sideOffset={4} className={cx(floatPanel, "w-56")}>
                  {[{ key: "", name: "Workspace", color: "" }, ...projects].map((p) => (
                    <DropdownMenu.Item key={p.key} onSelect={() => setProject(p.key)} className="flex h-8 items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover">
                      {p.color && <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: p.color }} />}
                      {p.name}
                    </DropdownMenu.Item>
                  ))}
                </DropdownMenu.Content>
              </DropdownMenu.Portal>
            </DropdownMenu.Root>
          )}
        </Field>
        <div className="flex gap-2">
          <Button type="submit" variant="primary" disabled={!name.trim() || !value || set.isPending}>
            {set.isPending ? "Saving…" : target.fixedName ? "Save key" : "Save credential"}
          </Button>
          <Button variant="ghost" disabled={set.isPending} onClick={onCancel}>
            Cancel
          </Button>
        </div>
      </div>
      {hint && <p className="text-12 text-fg-tertiary">{hint}</p>}
      {set.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{set.error.message}</p>}
    </form>
  );
}

/**
 * A sign-in the runner drives in a throwaway container: it shows the
 * provider's page and code, takes Claude's pasted code, and closes once the
 * login is stored. The login itself never reaches the browser.
 */
function SignInPanel({
  id,
  provider,
  label,
  onRetry,
  onClose,
  onDone,
}: {
  id: string;
  provider: SignInProvider;
  label: string;
  onRetry: () => void;
  onClose: () => void;
  onDone: () => void;
}) {
  const s = useSignIn(id);
  const submit = useSubmitSignInCode();
  const cancel = useCancelSignIn();
  const [code, setCode] = useState("");
  const [copied, setCopied] = useState(false);
  const status = s.data?.status;
  const finished = useRef(false);
  useEffect(() => {
    if (status === "done" && !finished.current) {
      finished.current = true;
      onDone();
    }
  }, [status, onDone]);

  const stop = () => {
    cancel.mutate(id);
    onClose();
  };
  if (s.isError) {
    return (
      <Banner tone="blocked" title="Couldn’t follow the sign-in" actions={<Button variant="outline" onClick={onClose}>Close</Button>}>
        {sentence(s.error.message || "The API is unavailable")}
      </Banner>
    );
  }
  const v = s.data ? signInView(s.data) : ({ step: "starting" } as const);
  if (v.step === "failed") {
    return (
      <Banner
        tone="blocked"
        title={`${label} sign-in didn’t finish`}
        actions={
          <>
            <Button variant="outline" onClick={onRetry}>Try again</Button>
            <Button variant="ghost" onClick={onClose}>Close</Button>
          </>
        }
      >
        {sentence(v.message)}
      </Banner>
    );
  }
  return (
    <div aria-label={`${label} sign-in`} className="flex flex-col gap-2.5 rounded-xl border border-border bg-surface px-3.5 py-3 text-13">
      {v.step === "starting" && <p className="text-fg-secondary">Starting a sign-in container…</p>}
      {v.step === "verifying" && <p className="text-fg-secondary">Checking the code and saving the login…</p>}
      {v.step === "open" && (
        <>
          <p className="text-fg-secondary">{SIGN_IN_STEPS[provider]}</p>
          <div className="flex flex-wrap items-center gap-2">
            {v.url.startsWith("https://") && (
              <a href={v.url} target="_blank" rel="noopener noreferrer" className={buttonLinkClass}>
                <Icon name="link" size={13} /> Open the {label} sign-in page
              </a>
            )}
            {v.code && (
              <>
                <code aria-label="One-time code" className="rounded-md border border-border-strong bg-selected px-2.5 py-1 font-mono text-15 tracking-wider">
                  {v.code}
                </code>
                <Button
                  variant="ghost"
                  onClick={() => {
                    void navigator.clipboard?.writeText(v.code).then(() => setCopied(true));
                  }}
                >
                  {copied ? "Copied" : "Copy code"}
                </Button>
              </>
            )}
          </div>
          {v.pasteBack && (
            <form
              className="flex flex-wrap items-end gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                const c = code.trim();
                if (!c) return;
                submit.mutate({ id, code: c }, { onSuccess: () => setCode("") });
              }}
            >
              <Field
                label={provider === "antigravity" ? "Code or callback URL from the sign-in page" : "Code from the Claude page"}
                htmlFor={`signin-${id}-code`}
              >
                <TextInput
                  id={`signin-${id}-code`}
                  mono
                  autoComplete="off"
                  spellCheck={false}
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  placeholder={provider === "antigravity" ? "Paste the code or callback URL" : "Paste the code"}
                />
              </Field>
              <Button variant="primary" type="submit" disabled={!code.trim() || submit.isPending}>
                Continue
              </Button>
            </form>
          )}
          {submit.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{submit.error.message}</p>}
        </>
      )}
      <div className="flex items-center justify-between gap-2">
        <span className="text-12 text-fg-tertiary">Runs in a throwaway container. The login is stored encrypted and never shown here.</span>
        <Button variant="ghost" onClick={stop}>Cancel</Button>
      </div>
    </div>
  );
}
