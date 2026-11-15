/**
 * Scheduled export to Google Drive: the rules the Settings section uses.
 * Pure so they're unit-tested; the section only renders them.
 */

/** Scopes that let Vesper create files in Drive (server: drivebackup.WriteScopes). */
export const DRIVE_WRITE_SCOPES = ["https://www.googleapis.com/auth/drive.file", "https://www.googleapis.com/auth/drive"];

export type DriveBackupDraft = {
  enabled: boolean;
  secret_id: string | null;
  folder_id: string;
  folder_name: string;
  at_time: string;
  timezone: string;
  retention: number;
  revision: number;
};

type DriveBackupLike = Omit<DriveBackupDraft, "secret_id" | "folder_name"> & { secret_id?: string | null; folder_name?: string };

type SecretLike = { id: string; name: string; kind: string; oauth?: { scopes: string[]; signed_in_at?: string; error: string } };

/** The editable part of the settings, with a local time zone before anyone saved one. */
export function driveDraft(b: DriveBackupLike, localTz: string): DriveBackupDraft {
  return {
    enabled: b.enabled,
    secret_id: b.secret_id ?? null,
    folder_id: b.folder_id,
    folder_name: b.folder_name ?? "",
    at_time: b.at_time || "03:00",
    timezone: b.revision === 0 && !b.timezone ? localTz : b.timezone,
    retention: b.retention,
    revision: b.revision,
  };
}

export function draftChanged(a: DriveBackupDraft, b: DriveBackupDraft) {
  return (Object.keys(a) as (keyof DriveBackupDraft)[]).some((k) => a[k] !== b[k]);
}

export type SecretChoice = { id: string; name: string; ready: boolean; reason: string };

/**
 * The person's OAuth secrets, each saying whether it can upload to Drive now.
 * Static secrets can't: Vesper has to refresh the token.
 */
export function driveSecretChoices(secrets: SecretLike[]): SecretChoice[] {
  return secrets
    .filter((s) => s.kind === "oauth")
    .map((s) => {
      const o = s.oauth;
      let reason = "";
      if (!o?.signed_in_at) reason = "not signed in";
      else if (o.error) reason = "sign in again";
      else if (!o.scopes.some((sc) => DRIVE_WRITE_SCOPES.includes(sc))) reason = "needs drive.file scope";
      return { id: s.id, name: s.name, ready: reason === "", reason };
    })
    .sort((a, b) => Number(b.ready) - Number(a.ready) || a.name.localeCompare(b.name));
}

/** Why the draft can't be saved, or "" when it can. Mirrors the server so the button says it up front. */
export function draftProblem(d: DriveBackupDraft): string {
  if (d.at_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(d.at_time)) return "Pick a time of day.";
  if (!Number.isInteger(d.retention) || d.retention < 0 || d.retention > 1000) return "Keep between 0 and 1000 backups.";
  if (d.enabled && !d.secret_id) return "Choose a Google sign-in to upload with.";
  if (d.enabled && !d.folder_id.trim()) return "Enter the Drive folder ID.";
  if (d.enabled && !d.timezone.trim()) return "Enter a time zone.";
  return "";
}

/**
 * Accepts a folder ID or a pasted Drive folder link
 * (https://drive.google.com/drive/folders/<id>?usp=sharing) and returns the ID.
 */
export function folderIdFrom(input: string): string {
  const s = input.trim();
  const m = s.match(/\/folders\/([A-Za-z0-9_-]+)/) ?? s.match(/[?&]id=([A-Za-z0-9_-]+)/);
  return m ? m[1] : s;
}

export type DriveStatus = { tone: "running" | "ok" | "failed" | "idle"; label: string };

/** One line for the last run: running, succeeded, failed or never. */
export function driveStatus(b: { running: boolean; last_status: string; last_run_at?: string | null; running_since?: string | null }): DriveStatus {
  if (b.running) return { tone: "running", label: "Exporting to Google Drive…" };
  if (b.last_status === "succeeded") return { tone: "ok", label: "Last backup succeeded" };
  if (b.last_status === "failed") return { tone: "failed", label: "Last backup failed" };
  return { tone: "idle", label: "No backup yet" };
}
