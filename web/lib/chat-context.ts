// Pure logic for chat context chips and the Sources footer (LAZYAGENTS-13).
// Kept free of React so `npm run test:unit` covers it.

export const MAX_CONTEXT_REFS = 20;

/** Knowledge appends the page in view after this marker; the server cuts request text at it. */
export const KNOWLEDGE_CONTEXT_MARKER = "\n\n<!-- vesper:knowledge-context -->\n";
/** Custom App dock appends the open app after this marker (custom-app-screen.tsx); the server cuts request text at it. */
export const CUSTOM_APP_CONTEXT_MARKER = "\n\n<!-- vesper:custom-app-context -->\n";

/**
 * What the person typed, without the context a dock appended for the persona. Their bubble shows
 * this; the context still reaches the persona, and the chips under the bubble say what it carried.
 */
export function typedText(body: string): string {
  for (const marker of [KNOWLEDGE_CONTEXT_MARKER, CUSTOM_APP_CONTEXT_MARKER]) {
    const at = body.indexOf(marker);
    if (at >= 0) body = body.slice(0, at);
  }
  return body;
}

export type ContextRef = {
  kind: "artifact" | "section" | "ticket" | "page" | "canvas";
  id?: string;
  key?: string;
  anchor?: string;
};

export type Chip = { key: string; ref: ContextRef; label: string };

type TargetLike = {
  kind: string;
  id?: string;
  anchor?: string;
  title: string;
  artifact_type?: string;
  path?: string;
  display_id?: string;
};

/** Stable identity of a ref, used to dedupe. */
export function refKey(r: ContextRef): string {
  return [r.kind, r.id ?? r.key ?? "", r.anchor ?? ""].join(":");
}

/** The chip for a suggestion from the [[ picker; null for kinds a chat can't take. */
export function chipFromTarget(t: TargetLike): Chip | null {
  let ref: ContextRef;
  if (t.kind === "ticket" && t.display_id) ref = { kind: "ticket", key: t.display_id };
  else if (t.kind === "section" && t.id && t.anchor) ref = { kind: "section", id: t.id, anchor: t.anchor };
  else if (t.kind === "artifact" && t.id) ref = { kind: t.artifact_type === "note" ? "page" : "artifact", id: t.id };
  else return null;
  const label = t.kind === "artifact" && t.artifact_type === "note" && t.path ? t.path : (t.display_id ?? t.title);
  return { key: refKey(ref), ref, label };
}

/** Adds a chip unless it's already there or the list is full. */
export function addChip(chips: Chip[], chip: Chip): Chip[] {
  if (chips.length >= MAX_CONTEXT_REFS || chips.some((c) => c.key === chip.key)) return chips;
  return [...chips, chip];
}

export function removeChip(chips: Chip[], key: string): Chip[] {
  return chips.filter((c) => c.key !== key);
}

/** `context_refs` for the request, or undefined when nothing is attached. */
export function toContextRefs(chips: Chip[]): ContextRef[] | undefined {
  return chips.length ? chips.map((c) => c.ref) : undefined;
}

/** Read-only chip for a ref echoed back on a sent message. */
export function chipFromRef(r: ContextRef, names?: Map<string, string>): Chip {
  const label = names?.get(refKey(r)) ?? (r.kind === "canvas" ? "Canvas" : undefined) ?? r.key ?? (r.anchor ? `${r.kind} #${r.anchor}` : `${r.kind} ${(r.id ?? "").slice(0, 8)}`);
  return { key: refKey(r), ref: r, label };
}

const KINDS = ["artifact", "section", "ticket", "page"];

/** Parses `?attach=kind:id` (ticket: `ticket:KEY`; section: `section:id#anchor`). */
export function parseAttach(values: string[], title?: string | null): Chip[] {
  let out: Chip[] = [];
  for (const v of values) {
    const i = v.indexOf(":");
    const kind = v.slice(0, i);
    const rest = v.slice(i + 1);
    if (i < 1 || !rest || !KINDS.includes(kind)) continue;
    let ref: ContextRef;
    if (kind === "ticket") ref = { kind, key: rest };
    else if (kind === "section") {
      const [id, anchor] = rest.split("#");
      if (!id || !anchor) continue;
      ref = { kind, id, anchor };
    } else ref = { kind: kind as "artifact" | "page", id: rest };
    const chip = chipFromRef(ref);
    out = addChip(out, { ...chip, label: values.length === 1 && title ? title : chip.label });
  }
  return out;
}

/** `/chat?project=KEY&attach=kind:id` query for a "Start chat" link. */
export function attachQuery(project: string | undefined, ref: ContextRef, title?: string): string {
  const v = ref.kind === "ticket" ? `ticket:${ref.key}` : ref.kind === "section" ? `section:${ref.id}#${ref.anchor}` : `${ref.kind}:${ref.id}`;
  const q = new URLSearchParams({ ...(project ? { project } : {}), attach: v });
  if (title) q.set("attach_title", title);
  return q.toString();
}

// ---------------------------------------------------------------- sources

export type CitationLike = {
  target: TargetLike & { href?: string };
  artifact_id?: string;
  title?: string;
  path?: string;
  version_id?: string;
  version?: string;
  section?: string;
};

export type Source = { key: string; label: string; title: string; meta: string; wiki: boolean; href?: string; version?: string; section?: string; target: CitationLike["target"] };

const enc = encodeURIComponent;

/** Where a citation should link: the exact version and/or section when known. */
export function citationHref(c: CitationLike): string | undefined {
  const base = c.target.href;
  const id = c.artifact_id ?? c.target.id;
  let href = base;
  if (c.version_id && id) {
    // The artifact page shows a version with ?version=; notes need ?versions=1
    // to stay on the history view instead of redirecting to /wiki.
    href = `/artifacts/${id}?${c.target.artifact_type === "note" || c.path ? "versions=1&" : ""}version=${enc(c.version_id)}`;
  }
  if (!href) return undefined;
  const anchor = c.section ?? c.target.anchor;
  if (anchor && !href.includes("#")) href += `#${enc(anchor)}`;
  return href;
}

/** Citations as a deduplicated list of links; same document+version+section collapses. */
export function citationSources(citations: CitationLike[] | undefined): Source[] {
  const seen = new Set<string>();
  const out: Source[] = [];
  for (const c of citations ?? []) {
    const section = c.section ?? c.target.anchor;
    const id = c.artifact_id ?? c.target.id ?? c.target.display_id ?? c.path ?? c.target.title;
    const key = [c.target.kind, id, c.version_id ?? c.version ?? "", section ?? ""].join("|");
    if (seen.has(key)) continue;
    seen.add(key);
    const wiki = !!c.path || c.target.artifact_type === "note";
    const named = c.title ?? c.target.title;
    const place = [c.version, section && `› ${section}`].filter(Boolean).join(" ");
    const kind = c.target.kind === "ticket" ? "Ticket" : c.target.kind === "epic" ? "Epic" : wiki ? "Wiki" : "Artifact";
    out.push({
      key,
      label: c.target.display_id ? `${c.target.display_id} ${named}`.trim() : (c.path ?? named),
      title: c.path?.split("/").pop() || named,
      meta: [kind, c.target.display_id ?? place].filter(Boolean).join(" · "),
      wiki,
      href: citationHref(c),
      version: c.version,
      section,
      target: c.target,
    });
  }
  return out;
}

// ------------------------------------------------------------ save replies

/** Appends the back-link to the chat, so a saved reply can be traced to its source. */
export function withChatBacklink(md: string, chatId: string, title: string): string {
  return `${md.trimEnd()}\n\n---\n\nSaved from chat [${title.replace(/[[\]]/g, "")}](/chat/${chatId})\n`;
}

/** Default wiki path for a saved reply: Chats/<title>, without path separators. */
export function defaultSavePath(title: string): string {
  const t = title.replace(/[/\\]+/g, "-").replace(/\s+/g, " ").trim() || "Chat";
  return `Chats/${t}`;
}
