// Helpers for /inspector-panel specs, opaque JSON props, and binary-safe panel events
// (such as forwarding screenshots & markdown reports from Playground to the main chat composer).
// Kept React- and DOM-free so `node --experimental-strip-types --test` tests it directly.

import type { ComposerDrop } from "../playground-report.ts";
import type { InspectorPanelSpec } from "./protocol.ts";

const BASE64_CHUNK = 0x8000;

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += BASE64_CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + BASE64_CHUNK));
  }
  return btoa(binary);
}

function base64ToBytes(base64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(base64);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export function makePanelSpec(kind: string, key: string, props: Record<string, unknown>): InspectorPanelSpec {
  return { kind, key, propsJson: JSON.stringify(props) };
}

export function parsePanelProps<T extends Record<string, unknown>>(propsJson: string): T | null {
  try {
    const parsed: unknown = JSON.parse(propsJson);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed as T;
  } catch {
    return null;
  }
}

export interface SerializedComposerFile {
  name: string;
  type: string;
  base64: string;
}

export interface SerializedComposerDrop {
  chatId: string;
  text?: string;
  files?: SerializedComposerFile[];
}

/** Encodes a `ComposerDrop` (text + `File[]`) into JSON suitable for `panel.event` bridge delivery. */
export async function encodeComposerDrop(chatId: string, drop: ComposerDrop): Promise<string> {
  const files = drop.files?.length
    ? await Promise.all(
        drop.files.map(async (f): Promise<SerializedComposerFile> => ({
          name: f.name,
          type: f.type,
          base64: bytesToBase64(new Uint8Array(await f.arrayBuffer())),
        })),
      )
    : undefined;
  const payload: SerializedComposerDrop = {
    chatId,
    ...(drop.text !== undefined ? { text: drop.text } : {}),
    ...(files ? { files } : {}),
  };
  return JSON.stringify(payload);
}

/** Decodes a `"composerDrop"` `panel.event` payload back into `{ chatId, drop }`, or `null` if invalid. */
export function decodeComposerDrop(payloadJson: string | undefined): { chatId: string; drop: ComposerDrop } | null {
  if (!payloadJson) return null;
  try {
    const parsed: unknown = JSON.parse(payloadJson);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const obj = parsed as Partial<SerializedComposerDrop>;
    if (typeof obj.chatId !== "string" || !obj.chatId) return null;
    const drop: ComposerDrop = {};
    if (typeof obj.text === "string") drop.text = obj.text;
    if (Array.isArray(obj.files) && obj.files.length > 0) {
      const reconstructed: File[] = [];
      for (const f of obj.files) {
        if (!f || typeof f.name !== "string" || typeof f.base64 !== "string") continue;
        const type = typeof f.type === "string" ? f.type : "";
        reconstructed.push(new File([base64ToBytes(f.base64)], f.name, { type }));
      }
      if (reconstructed.length > 0) drop.files = reconstructed;
    }
    return { chatId: obj.chatId, drop };
  } catch {
    return null;
  }
}
