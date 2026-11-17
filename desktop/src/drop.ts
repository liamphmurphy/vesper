import crypto from "node:crypto";
import path from "node:path";

/**
 * Files dropped on the Dock icon or opened with Vesper (LAZYAGENTS-247).
 * Mirrors the server's POST /api/v1/chat-attachments rules so the person
 * hears about a file the server would refuse before anything uploads; the
 * server still checks every upload (the client check is only a courtesy).
 */

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
/** POST /chats/{id}/messages takes at most 5 attachment ids. */
export const MAX_ATTACHMENTS_PER_MESSAGE = 5;

/** Extensions the server accepts, with the MIME type sent in the multipart part. */
export const ATTACHMENT_TYPES: Record<string, string> = {
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".markdown": "text/markdown",
  ".csv": "text/csv",
  ".json": "application/json",
  ".zip": "application/zip",
};

export interface DroppedFile {
  path: string;
  size: number;
  isFile: boolean;
}

export interface AcceptedFile {
  path: string;
  name: string;
  size: number;
  mime: string;
}

export interface RejectedFile {
  name: string;
  reason: string;
}

export function classifyDroppedFiles(files: readonly DroppedFile[]): { accepted: AcceptedFile[]; rejected: RejectedFile[] } {
  const accepted: AcceptedFile[] = [];
  const rejected: RejectedFile[] = [];
  const seen = new Set<string>();
  for (const f of files) {
    const name = path.basename(f.path);
    if (seen.has(f.path)) continue;
    seen.add(f.path);
    if (!f.isFile) {
      rejected.push({ name, reason: "Folders can't be attached; zip it first." });
      continue;
    }
    const mime = ATTACHMENT_TYPES[path.extname(name).toLowerCase()];
    if (!mime) {
      rejected.push({ name, reason: "Unsupported type (PDF, images, text, Markdown, CSV, JSON or zip)." });
      continue;
    }
    if (f.size <= 0) {
      rejected.push({ name, reason: "The file is empty." });
      continue;
    }
    if (f.size > MAX_ATTACHMENT_BYTES) {
      rejected.push({ name, reason: "Over the 25 MB limit." });
      continue;
    }
    if (accepted.length >= MAX_ATTACHMENTS_PER_MESSAGE) {
      rejected.push({ name, reason: `A message takes at most ${MAX_ATTACHMENTS_PER_MESSAGE} files.` });
      continue;
    }
    accepted.push({ path: f.path, name, size: f.size, mime });
  }
  return { accepted, rejected };
}

/** A filename safe inside a multipart Content-Disposition header. */
export function safeMultipartFilename(name: string): string {
  const cleaned = name.replace(/[\u0000-\u001f\u007f"\\\r\n]/g, "_").slice(0, 200);
  return cleaned || "file";
}

/**
 * Encodes one file as multipart/form-data with a single `file` field, built by
 * hand so the upload doesn't depend on FormData support in Electron's net.fetch.
 */
export function buildMultipartBody(fileName: string, mime: string, data: Buffer, boundary = `----vesper${crypto.randomBytes(12).toString("hex")}`): { body: Buffer; contentType: string } {
  const head = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${safeMultipartFilename(fileName)}"\r\nContent-Type: ${mime}\r\n\r\n`,
    "utf8",
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`, "utf8");
  return { body: Buffer.concat([head, data, tail]), contentType: `multipart/form-data; boundary=${boundary}` };
}

export interface SendFilesInput {
  /** "new" for a new chat (with personaId, or the default persona), or an existing chat id. */
  target: string;
  personaId?: string;
  message?: string;
  attachmentIds: string[];
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The API call that posts the uploaded files to a chat. Ids are validated; the person's text goes only in the JSON body. */
export function buildSendFilesRequest(input: SendFilesInput): { ok: true; path: string; body: Record<string, unknown> } | { ok: false; error: string } {
  const ids = input.attachmentIds.filter((id) => UUID_RE.test(id));
  if (ids.length === 0 || ids.length !== input.attachmentIds.length) return { ok: false, error: "No files were uploaded." };
  if (ids.length > MAX_ATTACHMENTS_PER_MESSAGE) return { ok: false, error: "Too many files for one message." };
  const names = ids.length === 1 ? "this file" : "these files";
  const body = (input.message ?? "").trim() || `Here's ${names}.`;
  const message = { body, attachment_ids: ids };
  if (input.target === "new") {
    const persona = (input.personaId ?? "").trim();
    if (persona && !UUID_RE.test(persona)) return { ok: false, error: "Pick a persona from the list." };
    return { ok: true, path: "/api/v1/chats", body: { ...(persona ? { persona_id: persona } : {}), message } };
  }
  if (!UUID_RE.test(input.target)) return { ok: false, error: "Pick a chat from the list." };
  return { ok: true, path: `/api/v1/chats/${input.target}/messages`, body: message };
}
