"use client";

import { useEffect, useId, useState, type FormEvent } from "react";
import { useBackupEncryption, useClearBackupEncryption, useSetBackupEncryption } from "@/lib/api/hooks";
import { ago } from "@/lib/format";
import { SmallPill } from "@/components/domain/labels";
import { Button, ButtonLink } from "@/components/ui/button";
import { confirmAction } from "@/components/ui/confirm";
import { Icon } from "@/components/ui/icon";
import { Banner, Card, Field, Skeleton, TextInput } from "@/components/ui/primitives";

const MIN_PASSWORD_LEN = 8;
const MAX_PASSWORD_LEN = 256;

/**
 * Export everything to move Vesper to another machine, and configure the
 * optional backup encryption password applied to both manual downloads and
 * scheduled backups.
 */
export function BackupSection() {
  const status = useBackupEncryption();
  const set = useSetBackupEncryption();
  const clear = useClearBackupEncryption();

  const [editing, setEditing] = useState(false);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const formId = useId();

  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(""), 6000);
    return () => clearTimeout(t);
  }, [notice]);

  const encrypted = status.data?.enabled ?? false;
  const busy = set.isPending || clear.isPending;

  function openForm() {
    setNotice("");
    setFormError(null);
    setPassword("");
    setConfirm("");
    setEditing(true);
  }

  function closeForm() {
    setPassword("");
    setConfirm("");
    setFormError(null);
    setEditing(false);
  }

  function submitPassword(e: FormEvent) {
    e.preventDefault();
    const chars = Array.from(password).length;
    if (chars < MIN_PASSWORD_LEN || chars > MAX_PASSWORD_LEN) {
      setFormError(`Use ${MIN_PASSWORD_LEN} to ${MAX_PASSWORD_LEN} characters.`);
      return;
    }
    if (password !== confirm) {
      setFormError("The passwords don't match.");
      return;
    }
    setFormError(null);
    const wasEnabled = status.data?.enabled ?? false;
    set.mutate(password, {
      onSuccess: () => {
        setPassword("");
        setConfirm("");
        setFormError(null);
        setEditing(false);
        set.reset();
        setNotice(wasEnabled ? "Backup password updated." : "Backup encryption enabled.");
      },
      onError: (err) => {
        setFormError(err instanceof Error ? err.message : "Couldn't save backup password.");
      },
    });
  }

  return (
    <div className="space-y-4">
      <Card
        title="Export everything"
        action={encrypted ? <SmallPill tone="done">Encrypted</SmallPill> : undefined}
        bodyClassName="flex flex-col gap-4 p-[18px]"
      >
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="max-w-[520px] text-13 text-fg-secondary">
            {encrypted
              ? "Downloads an encrypted .vesper.enc archive with every table and stored file: tickets, chats, wiki, artifacts, library, secrets and settings. Large instances take a while to prepare, and the download starts straight away."
              : "One zip with every table and every stored file: tickets, chats, wiki, artifacts, library, secrets (still encrypted) and settings. Large instances take a while to prepare, and the download starts straight away."}
          </p>
          <ButtonLink href="/api/v1/instance/export" variant="outline" icon="download" prefetch={false}>
            Export everything
          </ButtonLink>
        </div>
        <ul className="flex list-disc flex-col gap-1.5 pl-5 text-13 text-fg-tertiary">
          <li>The archive holds all your data. Keep it like a database backup.</li>
          <li>
            Sign-in sessions, runner registrations, live playgrounds and downloaded custom-app media stay behind: you sign in again on the new machine, and apps can re-download videos on demand.
          </li>
          <li>
            {encrypted ? (
              <>
                To load it, set the same <code className="font-mono">SECRETS_KEY</code> and{" "}
                <code className="font-mono">VESPER_BACKUP_PASSWORD</code> on a fresh instance and run{" "}
                <code className="font-mono">docker compose run --rm -T api import - &lt; vesper-export.vesper.enc</code> before starting the API.
              </>
            ) : (
              <>
                To load it, set the same <code className="font-mono">SECRETS_KEY</code> on a fresh instance and run{" "}
                <code className="font-mono">docker compose run --rm -T api import - &lt; vesper-export.zip</code> before starting the API.
                See “Move Vesper to another machine” in the guide.
              </>
            )}
          </li>
        </ul>
      </Card>

      {notice && (
        <p role="status" className="flex items-center gap-1.5 rounded-xl border border-border bg-surface px-3 py-2 text-13 text-pill-done-fg">
          <Icon name="check" size={13} /> {notice}
        </p>
      )}

      <Card title="Backup encryption" bodyClassName="flex flex-col gap-4 p-[18px]">
        {status.isPending ? (
          <Skeleton className="h-20" />
        ) : status.isError ? (
          <Banner
            tone="blocked"
            title="Couldn’t load backup encryption settings"
            actions={
              <Button variant="outline" onClick={() => void status.refetch()}>
                Retry
              </Button>
            }
          >
            {status.error instanceof Error ? status.error.message : "The API is unavailable."}
          </Banner>
        ) : (
          <>
            {!status.data.key_configured && (
              <Banner tone="human" title="Backup encryption requires SECRETS_KEY">
                Add <code className="font-mono">SECRETS_KEY=$(openssl rand -base64 32)</code> to{" "}
                <code className="font-mono">.env</code> and restart the API before setting a backup password.
              </Banner>
            )}

            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="min-w-[240px] max-w-[520px] space-y-1">
                <p className="text-13 text-fg-secondary">
                  {status.data.enabled
                    ? "Both manual downloads and scheduled exports are encrypted with your backup password (.vesper.enc)."
                    : "Exports currently save as unencrypted .zip archives (secrets inside remain sealed with SECRETS_KEY)."}
                </p>
                {status.data.enabled && status.data.updated_at && (
                  <p className="text-12 text-fg-tertiary">Password updated {ago(status.data.updated_at)}</p>
                )}
              </div>

              {!editing && (
                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    variant="outline"
                    icon="lock"
                    disabled={!status.data.key_configured || busy}
                    onClick={openForm}
                  >
                    {status.data.enabled ? "Change password" : "Set backup password"}
                  </Button>
                  {status.data.enabled && (
                    <Button
                      variant="ghost"
                      disabled={busy}
                      onClick={async () => {
                        setNotice("");
                        if (
                          await confirmAction({
                            title: "Turn off backup encryption?",
                            body: "Future manual and scheduled exports will save as unencrypted .zip archives. Existing encrypted backups stay encrypted.",
                            confirmLabel: "Turn off",
                          })
                        ) {
                          clear.mutate(undefined, {
                            onSuccess: () => {
                              closeForm();
                              setNotice("Backup encryption turned off.");
                            },
                            onError: (err) => {
                              setFormError(err instanceof Error ? err.message : "Couldn't turn off backup encryption.");
                            },
                          });
                        }
                      }}
                    >
                      Turn off
                    </Button>
                  )}
                </div>
              )}
            </div>

            {editing && (
              <form onSubmit={submitPassword} className="flex max-w-[420px] flex-col gap-3 border-t border-border-subtle pt-3" noValidate>
                <Field label="Backup password" htmlFor={`${formId}-pw`} hint={`At least ${MIN_PASSWORD_LEN} characters.`}>
                  <TextInput
                    id={`${formId}-pw`}
                    type="password"
                    autoComplete="new-password"
                    minLength={MIN_PASSWORD_LEN}
                    maxLength={MAX_PASSWORD_LEN}
                    required
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                </Field>
                <Field label="Confirm password" htmlFor={`${formId}-confirm`}>
                  <TextInput
                    id={`${formId}-confirm`}
                    type="password"
                    autoComplete="new-password"
                    minLength={MIN_PASSWORD_LEN}
                    maxLength={MAX_PASSWORD_LEN}
                    required
                    value={confirm}
                    onChange={(e) => setConfirm(e.target.value)}
                  />
                </Field>
                <p className="text-12 text-fg-tertiary">
                  Applies to both manual downloads and scheduled exports. If you lose this password, encrypted backups cannot be recovered.
                </p>
                {formError && (
                  <p role="alert" className="text-13 text-pill-blocked-fg">
                    {formError}
                  </p>
                )}
                <div className="flex flex-wrap gap-2">
                  <Button type="submit" variant="primary" disabled={busy || !password || !confirm}>
                    {set.isPending ? "Saving…" : "Save password"}
                  </Button>
                  <Button variant="ghost" disabled={busy} onClick={closeForm}>
                    Cancel
                  </Button>
                </div>
              </form>
            )}

            {!editing && formError && (
              <p role="alert" className="text-13 text-pill-blocked-fg">
                {formError}
              </p>
            )}
          </>
        )}
      </Card>
    </div>
  );
}
