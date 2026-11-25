// Token snapshots and the sync badge (ADR-designs §3.5). A design keeps its
// own copy of the Dusk tokens; nothing recolours until the person syncs, which
// replaces the copy with the current tokens.css snapshot as one version.
import generated from "./tokens.generated.json" with { type: "json" };
import { TOKENS_SOURCE, type Snapshot } from "./tokens-gen.ts";
import type { Design, DesignNode, Paint } from "./schema.ts";

export { TOKENS_SOURCE };
export const DUSK = generated as Snapshot;
/** The key a synced Dusk set has in token_sets when the design has none yet. */
export const DUSK_KEY = "dusk-web";

/** Whether the "tokens.css changed, sync?" badge shows: the design's set is a snapshot of tokens.css taken at another hash. */
export function tokensChanged(d: Design, snap: Snapshot = DUSK): boolean {
  return d.tokens_ref?.source === snap.source && d.tokens_ref.hash !== snap.hash;
}

type Visit = (c: string, set: (v: string) => void, owner: string) => void;

/** Calls f with every colour in the design that names a token, and a setter for it. */
function eachColor(d: Design, f: Visit) {
  const paint = (o: object, k: string, owner: string) => {
    const r = o as Record<string, unknown>;
    const p = r[k] as Paint | undefined;
    if (typeof p === "string") f(p, (v) => (r[k] = v), owner);
    else if (p && typeof p === "object" && Array.isArray(p.stops)) p.stops.forEach((s, i) => f(s, (v) => (p.stops[i] = v), owner));
  };
  const node = (n: DesignNode) => {
    paint(n, "fill", n.id);
    paint(n, "stroke", n.id);
    const paras = n.type === "text" ? n.paragraphs : n.type === "shape" ? n.text?.paragraphs : undefined;
    for (const p of paras ?? []) for (const r of p.runs) for (const k of ["color", "highlight"]) paint(r, k, n.id);
    if (n.type === "instance") for (const ov of Object.values(n.overrides ?? {})) paint(ov, "fill", n.id);
    if ("children" in n) n.children.forEach(node);
  };
  for (const p of d.pages) {
    paint(p, "background", p.id);
    p.children.forEach(node);
  }
}

/** Which nodes (or pages) use each token. */
export function tokenUsage(d: Design): Map<string, Set<string>> {
  const out = new Map<string, Set<string>>();
  eachColor(d, (c, _set, owner) => {
    if (c.startsWith("$")) out.set(c.slice(1), (out.get(c.slice(1)) ?? new Set()).add(owner));
  });
  return out;
}

/** Tokens the design uses that the snapshot no longer has, with the nodes that use them. */
export function missingAfterSync(d: Design, snap: Snapshot = DUSK): { token: string; value?: string; nodes: string[] }[] {
  const key = d.tokens_ref?.set ?? DUSK_KEY;
  const old = d.token_sets[key];
  const out = [];
  for (const [token, nodes] of tokenUsage(d)) {
    if (snap.modes.dark[token]?.kind === "color") continue;
    const v = old?.modes.dark[token];
    out.push({ token, value: v?.kind === "color" ? v.value : undefined, nodes: [...nodes] });
  }
  return out.sort((a, b) => a.token.localeCompare(b.token));
}

/**
 * The design with its tokens.css set replaced by the current snapshot and
 * tokens_ref stamped. A used token the snapshot lost becomes `replace[token]`
 * (another "$token"), or keeps its old literal colour when there's no choice.
 */
export function syncTokens(d: Design, now: string, replace: Record<string, string> = {}, snap: Snapshot = DUSK): Design {
  const key = d.tokens_ref?.set ?? DUSK_KEY;
  const prev = d.token_sets[key];
  const lost = new Map(missingAfterSync(d, snap).map((m) => [m.token, m.value]));
  const next = structuredClone(d);
  if (lost.size)
    eachColor(next, (c, set) => {
      const t = c.slice(1);
      if (!c.startsWith("$") || !lost.has(t)) return;
      const r = replace[t];
      set(r && snap.modes.dark[r.slice(1)]?.kind === "color" ? r : (lost.get(t) ?? "#000000"));
    });
  next.token_sets = { ...next.token_sets, [key]: { name: prev?.name ?? "Dusk (web)", source: snap.source, modes: structuredClone(snap.modes) } };
  next.tokens_ref = { set: key, source: snap.source, hash: snap.hash, synced_at: now };
  return next;
}

/** A token's value in a mode (light falls back to dark), or undefined. */
export function tokenValue(d: Design, name: string, mode: "dark" | "light"): string | undefined {
  const set = d.tokens_ref ? d.token_sets[d.tokens_ref.set] : undefined;
  const t = (mode === "light" && set?.modes.light?.[name]) || set?.modes.dark[name];
  return t?.value;
}
