// A Safari tab shared with a chat (docs/dev/safari-extension.md): the chat's
// banner says what's shared and how often the persona has read it.

import { ago } from "./format.ts";

export interface BrowserShareRead {
  persona: string;
  url: string;
  read_at: string;
}

export interface BrowserShare {
  id: string;
  chat_id: string;
  chat_title: string;
  url: string;
  title: string;
  until: "page" | "stop";
  include_screenshot: boolean;
  started_at: string;
  snapshot_at: string | null;
  stopped_at: string | null;
  stop_reason: string;
  reads: BrowserShareRead[];
}

/** The banner's title: the page's title, else its host and path. */
export function shareLabel(share: Pick<BrowserShare, "title" | "url">): string {
  if (share.title.trim()) return share.title.trim();
  try {
    const u = new URL(share.url);
    return u.host.replace(/^www\./, "") + u.pathname.replace(/\/$/, "");
  } catch {
    return share.url;
  }
}

/** One line on what the persona can see and has read, e.g. "Text and a screenshot · Meow read it 2 times, last 5m ago". */
export function shareDetail(share: BrowserShare, now = Date.now()): string {
  const what = share.include_screenshot ? "Text and a screenshot" : "Page text only";
  const until = share.until === "page" ? "until you leave the page" : "until you stop";
  const reads = share.reads;
  if (reads.length === 0) return `${what}, ${until} · not read yet`;
  const who = reads[0].persona || "The persona";
  // The server returns the latest 20 reads.
  const count = reads.length >= 20 ? "20+ times" : reads.length === 1 ? "once" : `${reads.length} times`;
  return `${what}, ${until} · ${who} read it ${count}, last ${ago(reads[0].read_at, now)}`;
}
