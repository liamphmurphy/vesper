"use client";

import { CopyButton } from "./reply-tools";
import { Fragment, useId, useMemo, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { changeTotals, filesStartOpen, langFromPath, parsePatch, STATUS_BADGE, type DiffRow } from "@/lib/code-diff";
import { useHighlighted, type Tok } from "@/lib/highlight";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";

type Change = Schemas["ChatCodeChange"];

export function Counts({ additions, deletions }: { additions: number; deletions: number }) {
  return (
    <span className="flex flex-none items-center gap-1.5 font-mono text-12 tabular-nums">
      <span className="text-state-done">+{additions}</span>
      <span className="text-state-blocked">−{deletions}</span>
    </span>
  );
}

const ROW_CLASS = {
  add: "bg-state-done/10",
  del: "bg-state-blocked/10",
  ctx: "",
  hunk: "bg-selected text-fg-tertiary",
  meta: "text-fg-tertiary",
} as const;

function Code({ text, toks }: { text: string; toks?: Tok[] }) {
  if (!toks) return <>{text || " "}</>;
  return (
    <>
      {toks.map((t, i) => (
        <span key={i} className="shiki-tok" style={t.style}>
          {t.content}
        </span>
      ))}
      {text === "" && " "}
    </>
  );
}

type LineRow = Extract<DiffRow, { kind: "add" | "del" | "ctx" }>;

/**
 * A file's highlighted diff. With `onLine`, each line gets a button to comment on it (the Code
 * dock), and `below` renders what sits under a line (its comment).
 */
export function Diff({ patch, path, active, onLine, below, tall }: { patch: string; path: string; active: boolean; onLine?: (row: LineRow) => void; below?: (row: LineRow) => ReactNode; tall?: boolean }) {
  const rows = useMemo(() => parsePatch(patch), [patch]);
  // One snippet per hunk, so multi-line constructs tokenize together; `index` maps tokens back to rows.
  const hunks = useMemo(() => {
    const groups: { index: number[]; lines: string[] }[] = [];
    rows.forEach((r: DiffRow, i) => {
      if (r.kind === "hunk") groups.push({ index: [], lines: [] });
      else if (r.kind !== "meta") {
        if (!groups.length) groups.push({ index: [], lines: [] });
        groups.at(-1)!.index.push(i);
        groups.at(-1)!.lines.push(r.text);
      }
    });
    return groups;
  }, [rows]);
  const lang = langFromPath(path);
  const toks = useHighlighted(hunks.map((h) => h.lines), lang, active);
  const byRow = new Map<number, Tok[]>();
  hunks.forEach((h, hi) => h.index.forEach((ri, li) => toks?.[hi]?.[li] && byRow.set(ri, toks[hi][li])));
  return (
    <div className={cx("overflow-auto", !tall && "max-h-[480px]")} tabIndex={0} role="region" aria-label={`Diff of ${path}`}>
      <div className="min-w-max font-mono text-12 leading-[1.55]">
        {rows.map((r, i) => (
          <Fragment key={i}>
            <div className={cx("group/line flex", ROW_CLASS[r.kind])} data-diff-row={r.kind}>
              {r.kind === "hunk" || r.kind === "meta" ? (
                <span className="whitespace-pre px-3 py-px">{r.text}</span>
              ) : (
                <>
                  {onLine && (
                    <button
                      type="button"
                      aria-label={`Comment on line ${r.newNo ?? r.oldNo}`}
                      title="Comment on this line"
                      onClick={() => onLine(r)}
                      className="w-5 flex-none select-none text-center text-accent opacity-0 hover:opacity-100 focus-visible:opacity-100 group-hover/line:opacity-100"
                    >
                      +
                    </button>
                  )}
                  <span aria-hidden className="w-10 flex-none select-none pr-2 text-right text-fg-tertiary">{r.oldNo}</span>
                  <span aria-hidden className="w-10 flex-none select-none pr-2 text-right text-fg-tertiary">{r.newNo}</span>
                  <span aria-hidden className="w-4 flex-none select-none text-center text-fg-tertiary">{r.kind === "add" ? "+" : r.kind === "del" ? "−" : ""}</span>
                  <span className="whitespace-pre pr-3 text-fg-2">
                    <Code text={r.text} toks={byRow.get(i)} />
                  </span>
                </>
              )}
            </div>
            {below && r.kind !== "hunk" && r.kind !== "meta" && below(r)}
          </Fragment>
        ))}
      </div>
    </div>
  );
}

/** Read-only highlighted contents of a branch file (for unchanged tracked files in CodePanel). */
export function CodeFileView({ content, path, active, tall }: { content: string; path: string; active: boolean; tall?: boolean }) {
  const lines = useMemo(() => {
    const raw = content.split("\n");
    if (raw.length > 1 && raw.at(-1) === "") raw.pop();
    return raw;
  }, [content]);
  const lang = langFromPath(path);
  const highlighted = useHighlighted([lines], lang, active);
  const toks = highlighted?.[0];
  return (
    <div className={cx("overflow-auto", !tall && "max-h-[480px]")} tabIndex={0} role="region" aria-label={`Contents of ${path}`} data-testid="code-file-content">
      <div className="min-w-max font-mono text-12 leading-[1.55]">
        {lines.map((line, i) => (
          <div key={i} className="flex" data-file-line={i + 1}>
            <span aria-hidden className="w-12 flex-none select-none pr-3 text-right text-fg-tertiary">{i + 1}</span>
            <span className="whitespace-pre pr-4 text-fg-2">
              <Code text={line} toks={toks?.[i]} />
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function FileBody({ c, active }: { c: Change; active: boolean }) {
  const note = (t: string) => <p className="px-3 py-2 text-12 text-fg-tertiary">{t}</p>;
  if (c.binary) return note("Binary file changed");
  if (!c.patch) return note("Diff not shown (too large).");
  return (
    <>
      <Diff patch={c.patch} path={c.path} active={active} />
      {c.truncated && note("Diff truncated.")}
    </>
  );
}

function FileRow({ c, open, onToggle, active }: { c: Change; open: boolean; onToggle: () => void; active: boolean }) {
  const id = useId();
  const badge = STATUS_BADGE[c.status];
  const [copied, setCopied] = useState(false);
  return (
    <li className="border-t border-border-row first:border-t-0" data-testid="code-change-file">
      <div className="flex items-center gap-1 pr-2">
        <button
          type="button"
          aria-expanded={open}
          aria-controls={id}
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-center gap-2 px-3 py-1.5 text-left hover:bg-row-hover"
        >
          <Icon name={open ? "chev" : "chevr"} size={13} className="flex-none text-fg-tertiary" />
          <span title={badge.label} aria-label={badge.label} className="flex-none rounded bg-selected px-1 font-mono text-10 font-semibold text-fg-secondary">
            {badge.letter}
          </span>
          <span className="min-w-0 truncate font-mono text-12 text-fg" dir="ltr">
            {c.repository && <span className="text-fg-tertiary">{c.repository.replace("https://github.com/", "").replace(/\.git$/, "")} / </span>}
            {c.status === "renamed" && c.old_path ? `${c.old_path} → ${c.path}` : c.path}
          </span>
          <span className="ml-auto">
            <Counts additions={c.additions} deletions={c.deletions} />
          </span>
        </button>
        <button
          type="button"
          aria-label={`Copy path ${c.path}`}
          title={copied ? "Copied" : "Copy path"}
          className="flex-none rounded p-1 text-fg-tertiary hover:bg-hover hover:text-fg"
          onClick={() => {
            void navigator.clipboard?.writeText(c.path).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            });
          }}
        >
          <Icon name={copied ? "check" : "link"} size={13} />
        </button>
      </div>
      {open && (
        <div id={id} className="border-t border-border-row bg-surface-sunken">
          <FileBody c={c} active={active} />
        </div>
      )}
    </li>
  );
}

/** Files an assistant reply changed in the persona's repo: collapsed by default, a highlighted diff per file. */
export function CodeChanges({ changes, onReview }: { changes?: Change[]; onReview?: () => void }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  // Per-file overrides of the default (few files start open).
  const [overrides, setOverrides] = useState<Record<string, boolean>>({});
  if (!changes?.length) return null;
  const totals = changeTotals(changes);
  const start = filesStartOpen(changes.length);
  const n = changes.length;
  return (
    <div className="w-full max-w-[min(720px,100%)] overflow-hidden rounded-xl border border-border bg-surface" data-testid="code-changes">
      <button
        type="button"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center gap-2 px-3 py-2 text-left text-13 hover:bg-row-hover"
      >
        <Icon name={open ? "chev" : "chevr"} size={14} className="flex-none text-fg-tertiary" />
        <Icon name="terminal" size={14} className="flex-none text-fg-secondary" />
        <span className="font-medium text-fg">Changed {n} {n === 1 ? "file" : "files"}</span>
        <span className="ml-1">
          <Counts {...totals} />
        </span>
      </button>
      {open && (changes.some((c) => c.patch) || onReview) && (
        <div className="flex justify-end gap-1 border-t border-border-subtle px-2 py-1">
          {onReview && (
            <button type="button" onClick={onReview} className="rounded px-2 py-0.5 text-12 text-accent hover:bg-hover" data-testid="review-branch">
              Review branch
            </button>
          )}
          {changes.some((c) => c.patch) && (
            <CopyButton label="Copy diff" text={changes.flatMap((c) => (c.patch ? [`--- ${c.path}\n+++ ${c.path}\n${c.patch}`] : [])).join("\n")} />
          )}
        </div>
      )}
      {open && (
        <ul id={id} className="border-t border-border">
          {changes.map((c) => (
            <FileRow
              key={`${c.repository ?? ""}/${c.path}`}
              c={c}
              open={overrides[`${c.repository ?? ""}/${c.path}`] ?? start}
              active={open}
              onToggle={() => setOverrides((o) => ({ ...o, [`${c.repository ?? ""}/${c.path}`]: !(o[`${c.repository ?? ""}/${c.path}`] ?? start) }))}
            />
          ))}
        </ul>
      )}
    </div>
  );
}
