"use client";

// Components, tokens and Inspect in the editor (ADR-designs
// §3.3, §3.5, §3.9). Every change goes through onEdit, so it is one
// undoable user version like any other edit.
import { useMemo, useState } from "react";
import { cx } from "@/lib/cx";
import { createComponent, detach, instantiate, overridable, setOverride } from "@/lib/designs/components";
import { find } from "@/lib/designs/edit";
import { INSPECT_TARGETS, inspect, type InspectTarget } from "@/lib/designs/inspect";
import type { Design, DesignNode, InstanceNode } from "@/lib/designs/schema";
import { DUSK, missingAfterSync, syncTokens, tokensChanged } from "@/lib/designs/tokens";
import { Button } from "@/components/ui/button";

type Edit = (fn: (d: Design) => Design, key?: string) => void;

const section = "border-b border-border-subtle px-4 py-3";
const label = "mb-2 text-11 font-semibold uppercase tracking-[0.08em] text-fg-tertiary";
const field = "flex h-[28px] min-w-0 items-center gap-1.5 rounded-md border border-border bg-surface-sunken px-2 text-13 text-fg focus-within:border-accent";
const small = "h-[28px] rounded-md border border-border px-2.5 text-13 text-fg hover:bg-hover disabled:opacity-50";

// ---------- components ----------

/** Create component (frames), Insert instance (components), overrides and Detach (instances). */
export function ComponentSection({ design, node, readOnly, onEdit, onSelect }: { design: Design; node: DesignNode; readOnly: boolean; onEdit: Edit; onSelect: (ids: string[]) => void }) {
  if (node.type === "frame")
    return (
      <section className={section} aria-label="Component">
        <h3 className={label}>Component</h3>
        <button type="button" className={small} disabled={readOnly} onClick={() => onEdit((d) => createComponent(d, node.id) ?? d)}>
          ◇ Create component
        </button>
        <p className="mt-2 text-12 text-fg-tertiary">Instances follow every edit to it, and keep their own text, fill and visibility.</p>
      </section>
    );
  if (node.type === "component") {
    const count = countInstances(design, node.id);
    return (
      <section className={section} aria-label="Component">
        <h3 className={label}>Component</h3>
        <p className="mb-2 text-12 text-fg-secondary">{count === 1 ? "1 instance" : `${count} instances`}</p>
        <button
          type="button"
          className={small}
          disabled={readOnly}
          onClick={() => {
            const page = find(design, node.id)?.page;
            if (!page) return;
            let made: string | undefined;
            onEdit((d) => {
              const r = instantiate(d, node.id, page.id, node.x + node.w + 40, node.y);
              made = r?.id;
              return r?.design ?? d;
            });
            if (made) onSelect([made]);
          }}
        >
          Insert instance
        </button>
      </section>
    );
  }
  if (node.type === "instance") return <InstanceSection design={design} node={node} readOnly={readOnly} onEdit={onEdit} onSelect={onSelect} />;
  return null;
}

function countInstances(d: Design, id: string) {
  let n = 0;
  const walk = (list: DesignNode[]) => {
    for (const c of list) {
      if (c.type === "instance" && c.component === id) n++;
      if ("children" in c) walk(c.children);
    }
  };
  for (const p of d.pages) walk(p.children);
  return n;
}

function InstanceSection({ design, node, readOnly, onEdit, onSelect }: { design: Design; node: InstanceNode; readOnly: boolean; onEdit: Edit; onSelect: (ids: string[]) => void }) {
  const main = find(design, node.component)?.node;
  const kids = overridable(design, node.id);
  const textOf = (id: string) => {
    const n = find(design, id)?.node;
    return n?.type === "text" ? n.paragraphs[0]?.runs[0]?.text ?? "" : "";
  };
  return (
    <section className={section} aria-label="Instance">
      <div className="flex items-center justify-between">
        <h3 className={label}>Instance</h3>
        <button type="button" className="mb-2 text-12 text-accent hover:underline" onClick={() => onSelect([node.component])}>
          Go to {main?.name ?? "component"}
        </button>
      </div>
      <div className="flex flex-col gap-2">
        {kids.map((k) => {
          const ov = node.overrides?.[k.id] ?? {};
          return (
            <div key={k.id} className="flex flex-col gap-1">
              <div className="flex items-center justify-between gap-2 text-12 text-fg-2">
                <span className="truncate">{k.name}</span>
                <label className="flex items-center gap-1 text-12 text-fg-tertiary">
                  <input type="checkbox" aria-label={`Show ${k.name}`} disabled={readOnly} checked={ov.visible !== false} onChange={(e) => onEdit((d) => setOverride(d, node.id, k.id, { visible: e.target.checked ? undefined : false }), `${node.id}:${k.id}:visible`)} />
                  Show
                </label>
              </div>
              {k.type === "text" && (
                <label className={field}>
                  <input
                    aria-label={`${k.name} text`}
                    disabled={readOnly}
                    className="w-full bg-transparent outline-none"
                    placeholder={textOf(k.id)}
                    value={ov.text ?? ""}
                    onChange={(e) => onEdit((d) => setOverride(d, node.id, k.id, { text: e.target.value || undefined }), `${node.id}:${k.id}:text`)}
                  />
                </label>
              )}
              {k.type !== "text" && k.type !== "group" && (
                <label className={field}>
                  <span className="text-11 text-fg-tertiary">Fill</span>
                  <input
                    aria-label={`${k.name} fill`}
                    disabled={readOnly}
                    className="w-full bg-transparent outline-none"
                    placeholder="$token or #RRGGBB"
                    defaultValue={typeof ov.fill === "string" ? ov.fill : ""}
                    onBlur={(e) => {
                      const v = e.target.value.trim();
                      const ok = !v || /^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\$[a-z0-9][a-z0-9-]{0,63})$/.test(v);
                      if (ok) onEdit((d) => setOverride(d, node.id, k.id, { fill: v ? (v.startsWith("#") ? v.toUpperCase() : v) : undefined }), `${node.id}:${k.id}:fill`);
                    }}
                  />
                </label>
              )}
            </div>
          );
        })}
        {!kids.length && <p className="text-12 text-fg-tertiary">The component has no layers to override.</p>}
        <button type="button" className={cx(small, "self-start")} disabled={readOnly} onClick={() => onEdit((d) => detach(d, node.id) ?? d)}>
          Detach instance
        </button>
      </div>
    </section>
  );
}

// ---------- Inspect ----------

const TARGET_LABEL: Record<InspectTarget, string> = { css: "CSS", tailwind: "Tailwind", react: "React" };

/** The inspector's Inspect tab: the selected node as code, with spacing, type, tokens and images. */
export function InspectPanel({ design, selected }: { design: Design; selected: string[] }) {
  const [target, setTarget] = useState<InspectTarget>("react");
  const [copied, setCopied] = useState(false);
  const id = selected.length === 1 ? selected[0] : undefined;
  const result = useMemo(() => {
    if (!id) return undefined;
    try {
      return inspect(design, id, target);
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [design, id, target]);
  if (!result) return <p className="px-4 py-6 text-13 text-fg-tertiary">Select one layer, usually a frame, to see it as code.</p>;
  if ("error" in result) return <p className="px-4 py-6 text-13 text-fg-tertiary">{result.error}</p>;
  return (
    <div className="pb-6" data-testid="design-inspect">
      <div className={section}>
        <div className="flex gap-1 rounded-md border border-border p-0.5" role="radiogroup" aria-label="Code">
          {INSPECT_TARGETS.map((t) => (
            <button key={t} type="button" role="radio" aria-checked={t === target} className={cx("h-[26px] flex-1 rounded-md px-1.5 text-12", t === target ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover")} onClick={() => setTarget(t)}>
              {TARGET_LABEL[t]}
            </button>
          ))}
        </div>
        <div className="relative mt-2">
          <pre data-testid="design-inspect-code" className="max-h-[320px] overflow-auto rounded-md bg-surface-sunken p-2 font-mono text-11 leading-[1.5] text-fg-2">{result.code}</pre>
          <button
            type="button"
            className="absolute right-1.5 top-1.5 rounded bg-surface-raised px-1.5 py-0.5 text-11 text-fg-secondary shadow hover:text-fg"
            onClick={() => void navigator.clipboard?.writeText(result.code).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            })}
          >
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
        {result.truncated && <p className="mt-1 text-12 text-fg-tertiary">Large selection: only the first layers are written out.</p>}
      </div>
      <section className={section} aria-label="Box and spacing">
        <h3 className={label}>Box and spacing</h3>
        <p className="text-12 text-fg-2">
          {result.box.w} × {result.box.h} px · {result.mode}
        </p>
        {result.spacing && (
          <p className="mt-1 text-12 text-fg-secondary">
            {result.spacing.direction}, gap {result.spacing.gap}, padding {result.spacing.padding.join(" ")}, align {result.spacing.align}, justify {result.spacing.justify}
          </p>
        )}
      </section>
      {result.tokens.length > 0 && (
        <section className={section} aria-label="Tokens">
          <h3 className={label}>Tokens</h3>
          <ul className="flex flex-col gap-1">
            {result.tokens.map((t) => (
              <li key={t.name} className="flex items-center gap-2 text-12" title={t.used_for.join(", ")}>
                <span aria-hidden className="size-3 flex-none rounded-sm border border-border" style={{ background: t.value ?? "transparent" }} />
                <span className="min-w-0 flex-1 truncate font-mono text-fg-2">--{t.name}</span>
                <span className="font-mono text-fg-tertiary">{t.value ?? "missing"}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
      {result.type.length > 0 && (
        <section className={section} aria-label="Type">
          <h3 className={label}>Type</h3>
          <ul className="flex flex-col gap-1 text-12 text-fg-2">
            {result.type.map((t, i) => (
              <li key={i} className="truncate" title={t.text}>
                Inter {t.size}/{t.line_height} · {t.weight}
                {t.italic ? " italic" : ""} · {t.token ? `--${t.token}` : t.color}
              </li>
            ))}
          </ul>
        </section>
      )}
      {result.assets.length > 0 && (
        <section className={section} aria-label="Images">
          <h3 className={label}>Images</h3>
          <ul className="flex flex-col gap-1 text-12 text-fg-2">
            {result.assets.map((a) => (
              <li key={a.id}>
                {a.id} · {a.w}×{a.h} {a.mime.replace("image/", "")}
                {a.alt ? ` · “${a.alt}”` : ""}
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

// ---------- tokens.css sync ----------

/** "tokens.css changed, sync?": shown while the design's snapshot is stale; nothing recolours until the person syncs. */
export function TokensSyncBadge({ design, readOnly, onEdit }: { design: Design; readOnly: boolean; onEdit: Edit }) {
  const [open, setOpen] = useState(false);
  const [choice, setChoice] = useState<Record<string, string>>({});
  if (!tokensChanged(design)) return null;
  const missing = missingAfterSync(design);
  const sync = () => {
    onEdit((d) => syncTokens(d, new Date().toISOString(), choice));
    setOpen(false);
  };
  return (
    <div className="relative">
      <button
        type="button"
        data-testid="tokens-sync-badge"
        disabled={readOnly}
        className="h-[26px] rounded-full border border-pill-human-fg/40 bg-pill-human-bg px-2.5 text-12 text-pill-human-fg disabled:opacity-50"
        title="The Dusk tokens in tokens.css changed since this design's copy was taken. The design keeps its colours until you sync."
        onClick={() => (missing.length ? setOpen((o) => !o) : sync())}
      >
        tokens.css changed, sync?
      </button>
      {open && (
        <div role="dialog" aria-label="Sync tokens" className="absolute right-0 top-8 z-40 w-[300px] rounded-lg border border-border-float bg-surface-raised p-3 text-13 shadow-[var(--shadow-float)]">
          <p className="mb-2 text-fg">These tokens are gone from tokens.css. Pick a replacement, or keep the colour as it is.</p>
          <ul className="mb-3 flex flex-col gap-2">
            {missing.map((m) => (
              <li key={m.token} className="flex flex-col gap-1">
                <span className="font-mono text-12 text-fg-2">
                  --{m.token} <span className="text-fg-tertiary">({m.nodes.length} {m.nodes.length === 1 ? "layer" : "layers"})</span>
                </span>
                <select aria-label={`Replace ${m.token}`} className={field} value={choice[m.token] ?? ""} onChange={(e) => setChoice((c) => ({ ...c, [m.token]: e.target.value }))}>
                  <option value="">Keep {m.value ?? "the colour"}</option>
                  {replacementOptions().map((t) => (
                    <option key={t} value={`$${t}`}>
                      --{t}
                    </option>
                  ))}
                </select>
              </li>
            ))}
          </ul>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button variant="primary" onClick={sync}>
              Sync
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

const COLOUR_TOKENS = Object.entries(DUSK.modes.dark)
  .filter(([, t]) => t.kind === "color")
  .map(([k]) => k)
  .sort();
const replacementOptions = () => COLOUR_TOKENS;
