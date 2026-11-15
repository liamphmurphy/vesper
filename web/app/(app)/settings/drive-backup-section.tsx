"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Toggle } from "@/components/ui/controls";
import { LoadingLines } from "@/components/ui/loading";
import { Card, Field, TextInput } from "@/components/ui/primitives";
import { useDriveBackup, useRunDriveBackup, useSaveDriveBackup, type DriveBackup } from "@/lib/api/drive-backup-hooks";
import { useApiSecrets } from "@/lib/api/secret-hooks";
import { cx } from "@/lib/cx";
import { draftChanged, draftProblem, driveDraft, driveSecretChoices, driveStatus, folderIdFrom, type DriveBackupDraft } from "@/lib/drive-backup";
import { absoluteTime, ago, duration } from "@/lib/format";

const zones: string[] = typeof Intl.supportedValuesOf === "function" ? Intl.supportedValuesOf("timeZone") : [];

/**
 * Scheduled export to Google Drive: the same archive as "Export everything",
 * uploaded daily (or now) to a Drive folder with one of the person's OAuth
 * secrets, keeping the newest `retention` backups.
 */
export function DriveBackupSection() {
  const backup = useDriveBackup();
  if (backup.isPending) return <LoadingLines />;
  if (backup.error) return <p role="alert" className="text-14 text-pill-blocked-fg">{backup.error.message}</p>;
  return <DriveBackupForm backup={backup.data} />;
}

function DriveBackupForm({ backup }: { backup: DriveBackup }) {
  const localTz = useMemo(() => Intl.DateTimeFormat().resolvedOptions().timeZone, []);
  const saved = driveDraft(backup, localTz);
  const [edit, setEdit] = useState<DriveBackupDraft | null>(null);
  const draft = edit ?? saved;
  const set = (p: Partial<DriveBackupDraft>) => setEdit({ ...draft, ...p });
  const dirty = edit != null && draftChanged(edit, saved);

  const secrets = useApiSecrets();
  const choices = driveSecretChoices(secrets.data?.secrets ?? []);
  const unknownSecret = draft.secret_id != null && secrets.isSuccess && !choices.some((c) => c.id === draft.secret_id);

  const save = useSaveDriveBackup();
  const run = useRunDriveBackup();
  const problem = draftProblem(draft);
  const fieldError = (f: string) => (save.error && "field" in save.error && save.error.field === f ? save.error.message : "");

  const onSave = () =>
    save.mutate(
      { ...draft, folder_id: folderIdFrom(draft.folder_id), folder_name: draft.folder_name.trim(), timezone: draft.timezone.trim() },
      { onSuccess: () => setEdit(null) },
    );

  const runBlocked = backup.running
    ? "A backup is running."
    : dirty
      ? "Save your changes first."
      : !backup.secret_id || !backup.folder_id
        ? "Choose a sign-in and a folder, then save."
        : "";
  const status = driveStatus(backup);

  return (
    <Card as="div" bodyClassName="flex flex-col gap-4 p-[18px]">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex max-w-[520px] flex-col gap-1">
          <h3 className="text-14 font-medium text-fg">Back up to Google Drive</h3>
          <p className="text-13 text-fg-secondary">
            Uploads the same archive to a Drive folder every day and keeps the newest ones. Large instances stream straight to Drive.
          </p>
        </div>
        <Toggle label="Daily backup" checked={draft.enabled} onChange={(enabled) => set({ enabled })} disabled={save.isPending} />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Field
          label="Google sign-in"
          htmlFor="drive-secret"
          hint={
            <>
              An OAuth secret signed in with the <code className="font-mono">drive.file</code> scope.{" "}
              <Link href="/customization?who=secrets" className="text-accent hover:underline">Manage secrets</Link>
            </>
          }
        >
          <select
            id="drive-secret"
            value={draft.secret_id ?? ""}
            onChange={(e) => set({ secret_id: e.target.value || null })}
            className="h-[30px] w-full rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none"
          >
            <option value="">{choices.length ? "Choose a secret…" : "No OAuth secrets yet"}</option>
            {unknownSecret && <option value={draft.secret_id!}>Set up by someone else</option>}
            {choices.map((c) => (
              <option key={c.id} value={c.id}>
                {c.ready ? c.name : `${c.name} (${c.reason})`}
              </option>
            ))}
          </select>
          {fieldError("secret_id") && <span role="alert" className="text-12 text-pill-blocked-fg">{fieldError("secret_id")}</span>}
        </Field>

        <Field label="Drive folder ID" htmlFor="drive-folder" hint="The ID at the end of the folder's link; pasting the link works too.">
          <TextInput
            id="drive-folder"
            mono
            placeholder="1AbCdEf…"
            value={draft.folder_id}
            onChange={(e) => set({ folder_id: e.target.value })}
            onBlur={(e) => set({ folder_id: folderIdFrom(e.target.value) })}
          />
          {fieldError("folder_id") && <span role="alert" className="text-12 text-pill-blocked-fg">{fieldError("folder_id")}</span>}
        </Field>

        <Field label="Every day at" htmlFor="drive-time" hint={backup.next_run_at && !dirty ? `Next backup ${absoluteTime(backup.next_run_at)}` : undefined}>
          <div className="flex gap-2">
            <TextInput id="drive-time" type="time" className="w-32" value={draft.at_time} onChange={(e) => set({ at_time: e.target.value })} />
            <TextInput aria-label="Time zone" list="drive-zones" className="flex-1" value={draft.timezone} onChange={(e) => set({ timezone: e.target.value })} />
            <datalist id="drive-zones">
              {zones.map((z) => (
                <option key={z} value={z} />
              ))}
            </datalist>
          </div>
          {(fieldError("at_time") || fieldError("timezone")) && (
            <span role="alert" className="text-12 text-pill-blocked-fg">{fieldError("at_time") || fieldError("timezone")}</span>
          )}
        </Field>

        <Field label="Backups to keep" htmlFor="drive-retention" hint="Older backups in the folder are deleted after each upload. 0 keeps them all.">
          <TextInput
            id="drive-retention"
            type="number"
            min={0}
            max={1000}
            className="w-24"
            value={Number.isNaN(draft.retention) ? "" : draft.retention}
            onChange={(e) => set({ retention: e.target.value === "" ? NaN : Number(e.target.value) })}
          />
          {fieldError("retention") && <span role="alert" className="text-12 text-pill-blocked-fg">{fieldError("retention")}</span>}
        </Field>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button variant="primary" disabled={!dirty || !!problem || save.isPending} onClick={onSave}>
          {save.isPending ? "Saving…" : "Save"}
        </Button>
        {dirty && (
          <Button variant="ghost" disabled={save.isPending} onClick={() => { setEdit(null); save.reset(); }}>
            Discard
          </Button>
        )}
        {dirty && problem && <span className="text-12 text-fg-tertiary">{problem}</span>}
        {save.error && !["secret_id", "folder_id", "at_time", "timezone", "retention"].includes((save.error as { field?: string }).field ?? "") && (
          <span role="alert" className="text-12 text-pill-blocked-fg">{save.error.message}</span>
        )}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border-subtle pt-4">
        <div role="status" aria-label="Drive backup status" className="flex min-w-0 flex-col gap-0.5">
          <span
            className={cx(
              "text-13 font-medium",
              status.tone === "ok" && "text-pill-done-fg",
              status.tone === "failed" && "text-pill-blocked-fg",
              status.tone === "running" && "text-pill-review-fg",
              status.tone === "idle" && "text-fg-secondary",
            )}
          >
            {status.label}
            {backup.running && backup.running_since && <span className="font-normal text-fg-tertiary"> · {duration(backup.running_since)}</span>}
          </span>
          {backup.last_run_at && (
            <span className="text-12 text-fg-tertiary" title={absoluteTime(backup.last_run_at)}>
              Last run {ago(backup.last_run_at)} · {absoluteTime(backup.last_run_at)}
            </span>
          )}
          {!backup.running && backup.last_status === "failed" && backup.last_error && (
            <span className="text-12 text-pill-blocked-fg">{backup.last_error}</span>
          )}
        </div>
        <div className="flex flex-col items-end gap-1">
          <Button variant="outline" icon="upload" disabled={!!runBlocked || run.isPending} onClick={() => run.mutate()}>
            {backup.running ? "Exporting…" : "Export to Google Drive now"}
          </Button>
          {runBlocked && !backup.running && <span className="text-12 text-fg-tertiary">{runBlocked}</span>}
          {run.error && <span role="alert" className="text-12 text-pill-blocked-fg">{run.error.message}</span>}
        </div>
      </div>
    </Card>
  );
}
