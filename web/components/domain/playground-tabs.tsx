"use client";

import { useEffect, useMemo, useRef, useState, type Ref } from "react";
import { useQuery } from "@tanstack/react-query";
import type { Playground } from "@/lib/api/playground-hooks";
import { cx } from "@/lib/cx";
import { curlFor, exampleFor, filterOps, parseOpenAPI, requestPath, validate, type ApiDoc, type Operation } from "@/lib/openapi";
import { appendLogs, inferredIsStale, isErrorLine, linesForRequest, logSources, mapApiPrompt, normalizePath, parseSpecSource, type LogLine, type SpecSource } from "@/lib/playground";
import { sendToComposer, type ComposerDrop } from "@/lib/playground-report";
import { Button, IconButton } from "@/components/ui/button";

// The Playground's tabs. Everything here talks to the playground's own origin
// (the runner's gateway), never to Vesper's API: the browser sends the Vesper
// session there and the gateway lets this page read the answers.

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

// Source colours, assigned in first-seen order.
const SOURCE_TONES = ["text-accent", "text-pill-done-fg", "text-pill-review-fg", "text-pill-human-fg", "text-fg-secondary"];

function sourceTone(sources: string[], s: string) {
  const i = sources.indexOf(s);
  return SOURCE_TONES[(i < 0 ? 0 : i) % SOURCE_TONES.length];
}

const clock = (iso: string) => (iso ? new Date(iso).toLocaleTimeString([], { hour12: false }) : "");

/** The playground's merged container output, streamed from its gateway. */
export function usePlaygroundLogs(origin: string | null) {
  const [lines, setLines] = useState<LogLine[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!origin) return;
    const stream = new EventSource(`${origin}/__vesper/logs?tail=500`, { withCredentials: true });
    let batch: LogLine[] = [];
    let timer: ReturnType<typeof setTimeout> | undefined;
    const flush = () => {
      timer = undefined;
      const more = batch;
      batch = [];
      setLines((l) => appendLogs(l, more));
    };
    stream.onopen = () => {
      setError(null);
      setLines([]); // a reconnect starts again from the tail
    };
    stream.onmessage = (e) => {
      try {
        batch.push(JSON.parse(e.data) as LogLine);
      } catch {
        return;
      }
      timer ??= setTimeout(flush, 100);
    };
    stream.addEventListener("error", (e) => {
      const data = (e as MessageEvent).data;
      if (typeof data === "string" && data) setError(data);
    });
    return () => {
      stream.close();
      if (timer) clearTimeout(timer);
    };
  }, [origin]);
  return { lines, error, clear: () => setLines([]) };
}

/**
 * The running app in a frame. livePath is where the app says it is (the
 * gateway's probe): the address bar follows it, since the frame's own
 * location can't be read across origins. onReload fires when the frame is
 * loaded afresh from here.
 */
export function PreviewTab({ origin, frameRef, livePath, onReload }: { origin: string; frameRef?: Ref<HTMLIFrameElement>; livePath?: string | null; onReload?: () => void }) {
  const [path, setPath] = useState("/");
  const [draft, setDraft] = useState("/");
  const [reloads, setReloads] = useState(0);
  const [shownLive, setShownLive] = useState(livePath);
  if (livePath !== shownLive) {
    setShownLive(livePath);
    if (livePath) setDraft(livePath);
  }
  const reload = () => {
    setReloads((n) => n + 1);
    onReload?.();
  };
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <form
        className="flex items-center gap-2 border-b border-border-subtle px-3 py-2"
        onSubmit={(e) => {
          e.preventDefault();
          const p = normalizePath(draft);
          setDraft(p);
          setPath(p);
          reload();
        }}
      >
        <IconButton icon="refresh" label="Reload" onClick={reload} />
        <label className="flex min-w-0 flex-1 items-center rounded-md border border-border-strong bg-surface-sunken px-2 font-mono text-12">
          <span className="flex-none text-fg-tertiary">{origin.replace(/^https?:\/\//, "")}</span>
          <input aria-label="Path" value={draft} onChange={(e) => setDraft(e.target.value)} className="min-w-0 flex-1 bg-transparent py-1.5 text-fg focus:outline-none" />
        </label>
      </form>
      <div className="min-h-0 flex-1 bg-white">
        {/* Its own origin; no allow-top-navigation, so the app can't navigate Vesper away. */}
        <iframe
          key={reloads}
          ref={frameRef}
          title="Playground preview"
          data-testid="playground-preview"
          src={origin + path}
          sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals allow-downloads"
          className="h-full w-full border-0"
        />
      </div>
    </div>
  );
}

/** The playground's logs, filterable by where they came from. */
export function LogsTab({ logs }: { logs: ReturnType<typeof usePlaygroundLogs> }) {
  const [source, setSource] = useState<string | null>(null);
  const [follow, setFollow] = useState(true);
  const end = useRef<HTMLDivElement>(null);
  const sources = logSources(logs.lines);
  const shown = source ? logs.lines.filter((l) => l.source === source) : logs.lines;
  useEffect(() => {
    if (follow) end.current?.scrollIntoView({ block: "end" });
  }, [follow, shown.length]);
  const chip = (label: string, value: string | null) => (
    <button key={label} type="button" aria-pressed={source === value} onClick={() => setSource(value)} className={cx("rounded-full border px-2.5 py-0.5 text-12", source === value ? "border-accent bg-accent-soft text-fg" : "border-border-strong text-fg-secondary hover:text-fg")}>
      {label}
    </button>
  );
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex flex-wrap items-center gap-1.5 border-b border-border-subtle px-3 py-2">
        {chip("all", null)}
        {sources.map((s) => chip(s, s))}
        <span className="ml-auto flex items-center gap-3 text-12 text-fg-secondary">
          <label className="flex items-center gap-1"><input type="checkbox" checked={follow} onChange={(e) => setFollow(e.target.checked)} /> Follow</label>
          <button type="button" className="hover:text-fg" onClick={logs.clear}>Clear</button>
        </span>
      </div>
      {logs.error && <p role="alert" className="px-3 py-1 text-12 text-pill-blocked-fg">{logs.error}</p>}
      <div data-testid="playground-logs" className="min-h-0 flex-1 overflow-auto bg-surface-sunken px-3 py-2 font-mono text-12 leading-relaxed">
        {shown.length === 0 && <p className="text-fg-tertiary">No output yet.</p>}
        {shown.map((l, i) => (
          <div key={i} className="flex gap-3 whitespace-pre-wrap">
            <span className="flex-none text-fg-tertiary">{clock(l.t)}</span>
            <span className={cx("w-16 flex-none truncate", sourceTone(sources, l.source))}>{l.source}</span>
            <span className={cx("min-w-0 flex-1 break-words", isErrorLine(l) ? "text-pill-blocked-fg" : "text-fg-2")}>{l.text}</span>
          </div>
        ))}
        <div ref={end} />
      </div>
    </div>
  );
}

type Sent = {
  op: Operation;
  url: string;
  status: number;
  statusText: string;
  ms: number;
  bytes: number;
  contentType: string;
  headers: [string, string][];
  body: string;
  sentAt: number;
  doneAt: number;
};

const methodTone: Record<string, string> = { GET: "text-pill-done-fg", POST: "text-accent", PUT: "text-pill-review-fg", PATCH: "text-pill-review-fg", DELETE: "text-pill-blocked-fg" };

function pretty(body: string, contentType: string) {
  if (!/json/i.test(contentType)) return body;
  try {
    return JSON.stringify(JSON.parse(body), null, 2);
  } catch {
    return body;
  }
}

/** The app's API from its OpenAPI document: pick an operation, send it, read the answer. */
type SpecAnswer =
  | { found: true; doc: unknown; source: SpecSource }
  | { found: false; message: string; checked: string[] };

export function ApiTab({
  chatId,
  pg,
  origin,
  logs,
  wide,
  onOpenLogs,
  onSendToComposer,
}: {
  chatId: string;
  pg: Playground;
  origin: string;
  logs: LogLine[];
  wide: boolean;
  onOpenLogs: () => void;
  onSendToComposer?: (drop: ComposerDrop) => Promise<boolean> | boolean;
}) {
  // Always asked: the gateway prefers the document the running app serves,
  // which the playground's spec may not name.
  const spec = useQuery({
    queryKey: ["playground-openapi", origin, pg.openapi, pg.openapi_commit, pg.started_at ?? ""],
    retry: false,
    queryFn: async (): Promise<SpecAnswer> => {
      const res = await fetch(`${origin}/__vesper/openapi`, { credentials: "include", cache: "no-store" });
      const data = (await res.json().catch(() => null)) as { message?: string; checked?: unknown } | null;
      if (res.status === 404 && Array.isArray(data?.checked)) {
        return { found: false, message: data.message ?? "", checked: data.checked.filter((c): c is string => typeof c === "string") };
      }
      if (!res.ok) throw new Error(data?.message ?? `The playground answered ${res.status}.`);
      const source = parseSpecSource(res.headers.get("X-Vesper-Spec-Source"));
      return { found: true, doc: data, source: source.kind === "unknown" && pg.openapi ? { kind: "file", path: pg.openapi } : source };
    },
  });
  const source = spec.data?.found ? spec.data.source : null;
  const inferred = source?.kind === "inferred" ? source : null;
  // Where the workspace is now, to tell whether an inferred document still matches it.
  const head = useQuery({
    queryKey: ["playground-meta", origin],
    enabled: !!inferred,
    retry: false,
    queryFn: async () => (await (await fetch(`${origin}/__vesper/meta`, { credentials: "include", cache: "no-store" })).json()) as { commit?: string },
  });
  const stale = !!inferred && inferredIsStale(inferred.commit, head.data?.commit ?? "");
  const [asked, setAsked] = useState<string>();
  const askToMap = async () => {
    const drop: ComposerDrop = { text: mapApiPrompt({ stale, existing: inferred?.path ?? null }) };
    const sent = onSendToComposer ? await onSendToComposer(drop) : sendToComposer(chatId, drop);
    setAsked(sent ? "Added to your message: send it and the persona maps the API." : "Open the chat to ask the persona.");
  };
  const parsed = useMemo<{ api?: ApiDoc; error?: string }>(() => {
    if (!spec.data?.found) return {};
    try {
      return { api: parseOpenAPI(spec.data.doc) };
    } catch (e) {
      return { error: errorText(e) };
    }
  }, [spec.data]);
  const [filter, setFilter] = useState("");
  const [selected, setSelected] = useState<string>();
  const [history, setHistory] = useState<Sent[]>([]);

  if (spec.isPending) return <Empty title="Reading the OpenAPI document…">{pg.openapi}</Empty>;
  if (spec.data && !spec.data.found) {
    return (
      <Empty title="No API document found">
        <span className="block">The app doesn’t serve one at {spec.data.checked.map((c, i) => <span key={c}>{i ? ", " : ""}<code className="font-mono">{c}</code></span>)}, and the playground names none.</span>
        <span className="mt-3 block">The persona can read the routes and handlers and map the API, marked as inferred.</span>
        <Button variant="primary" className="mt-3" onClick={askToMap}>Map this API</Button>
        {asked && <span role="status" className="mt-2 block text-11 text-fg-tertiary">{asked}</span>}
      </Empty>
    );
  }
  const name = source && source.kind !== "unknown" ? source.path : pg.openapi || "the OpenAPI document";
  if (spec.isError || parsed.error) return <Empty title={`Couldn’t read ${name}`}>{parsed.error ?? errorText(spec.error)}</Empty>;
  const api = parsed.api!;
  const groups = filterOps(api, filter);
  const op = api.groups.flatMap((g) => g.ops).find((o) => o.key === selected);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {source && source.kind !== "unknown" && (
        <div data-testid="playground-spec-source" className="flex flex-wrap items-center gap-2 border-b border-border-subtle px-3 py-1.5 text-12 text-fg-secondary">
          {inferred ? (
            <>
              <span className="rounded-full bg-pill-review-bg px-2 py-0.5 text-11 font-semibold text-pill-review-fg">Inferred</span>
              <span>
                Read from the code{inferred.commit ? <> at <code className="font-mono">{inferred.commit.slice(0, 7)}</code></> : ""}; it may be incomplete.
              </span>
              {stale && <span role="status" className="font-semibold text-pill-blocked-fg">The code has changed since.</span>}
              <Button variant="secondary" className="ml-auto" onClick={askToMap}>Re-infer</Button>
            </>
          ) : source.kind === "served" ? (
            <span>Served by the app at <code className="font-mono">{source.path}</code></span>
          ) : (
            <span>From <code className="font-mono">{source.path}</code></span>
          )}
          {asked && <span role="status" className="basis-full text-fg-tertiary">{asked}</span>}
        </div>
      )}
      <div className={cx("flex min-h-0 flex-1", !wide && "max-md:flex-col")}>
        <nav aria-label="Operations" className={cx("flex flex-none flex-col border-r border-border-subtle bg-bg-sidebar", wide ? "w-72" : "w-48")}>
          <div className="flex items-center gap-2 border-b border-border-subtle p-2">
            <input aria-label="Filter operations" placeholder={`Filter ${api.count} operations`} value={filter} onChange={(e) => setFilter(e.target.value)} className="min-w-0 flex-1 rounded-md border border-border-strong bg-surface-sunken px-2 py-1 text-12 text-fg focus:border-accent focus:outline-none" />
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto py-1">
            {groups.map((g) => (
              <details key={g.tag} open={!!filter || g.ops.some((o) => o.key === selected)} className="px-1">
                <summary className="cursor-pointer select-none px-2 py-1 text-10 font-semibold uppercase tracking-wider text-fg-tertiary">
                  {g.tag} <span className="font-normal">{g.ops.length}</span>
                </summary>
                {g.ops.map((o) => (
                  <button key={o.key} type="button" aria-current={o.key === selected} onClick={() => setSelected(o.key)} className={cx("flex w-full items-baseline gap-2 rounded px-2 py-1 text-left font-mono text-12", o.key === selected ? "bg-accent-soft text-fg" : "text-fg-2 hover:bg-hover")}>
                    <span className={cx("w-9 flex-none font-bold", methodTone[o.method])}>{o.method === "DELETE" ? "DEL" : o.method}</span>
                    <span className="min-w-0 truncate">{o.path}</span>
                  </button>
                ))}
              </details>
            ))}
            {history.length > 0 && (
              <details className="px-1">
                <summary className="cursor-pointer select-none px-2 py-1 text-10 font-semibold uppercase tracking-wider text-fg-tertiary">History <span className="font-normal">{history.length}</span></summary>
                {history.map((h, i) => (
                  <button key={i} type="button" onClick={() => setSelected(h.op.key)} className="flex w-full items-baseline gap-2 rounded px-2 py-1 text-left font-mono text-12 text-fg-2 hover:bg-hover">
                    <span className={cx("w-9 flex-none font-bold", h.status >= 400 ? "text-pill-blocked-fg" : "text-pill-done-fg")}>{h.status || "ERR"}</span>
                    <span className="min-w-0 truncate">{h.op.method} {h.op.path}</span>
                  </button>
                ))}
              </details>
            )}
          </div>
        </nav>
        {op ? (
          <OperationView
            key={op.key}
            spec={spec.data?.found ? spec.data.doc : null}
            base={api.base}
            op={op}
            origin={origin}
            logs={logs}
            wide={wide}
            onOpenLogs={onOpenLogs}
            onSent={(s) => setHistory((h) => [s, ...h].slice(0, 30))}
            last={history.find((h) => h.op.key === op.key)}
          />
        ) : (
          <Empty title={api.title || "API"}>
            {api.count} operations under <code className="font-mono">{api.base || "/"}</code>, from <code className="font-mono">{name}</code>. Pick one to try it.
          </Empty>
        )}
      </div>
    </div>
  );
}

function OperationView({ spec, base, op, origin, logs, wide, onOpenLogs, onSent, last }: { spec: unknown; base: string; op: Operation; origin: string; logs: LogLine[]; wide: boolean; onOpenLogs: () => void; onSent: (s: Sent) => void; last?: Sent }) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [headers, setHeaders] = useState(op.body ? `Content-Type: ${op.body.contentType}` : "");
  const [body, setBody] = useState(() => (op.body ? JSON.stringify(exampleFor(spec, op.body.schema), null, 2) : ""));
  const [tab, setTab] = useState<"params" | "headers" | "body">(op.body ? "body" : "params");
  const [sending, setSending] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [resTab, setResTab] = useState<"body" | "headers">("body");
  const [copied, setCopied] = useState(false);

  const warnings = useMemo(() => {
    if (!op.body || !/json/i.test(op.body.contentType) || !body.trim()) return [];
    try {
      return validate(spec, op.body.schema, JSON.parse(body));
    } catch {
      return [{ path: "body", message: "isn’t valid JSON" }];
    }
  }, [spec, op, body]);
  const missing = op.params.filter((p) => p.required && !values[`${p.in}:${p.name}`]);
  const path = requestPath(base, op, values);
  const headerMap: Record<string, string> = {};
  for (const line of headers.split("\n")) {
    const i = line.indexOf(":");
    if (i > 0) headerMap[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  for (const p of op.params) if (p.in === "header" && values[`header:${p.name}`]) headerMap[p.name] = values[`header:${p.name}`];
  const sendsBody = !!op.body && !["GET", "HEAD"].includes(op.method);

  const send = async () => {
    setSending(true);
    setFailure(null);
    const sentAt = Date.now();
    try {
      const res = await fetch(origin + path, { method: op.method, credentials: "include", headers: headerMap, body: sendsBody ? body : undefined, cache: "no-store" });
      const text = await res.text();
      const doneAt = Date.now();
      onSent({ op, url: origin + path, status: res.status, statusText: res.statusText, ms: doneAt - sentAt, bytes: new Blob([text]).size, contentType: res.headers.get("content-type") ?? "", headers: [...res.headers.entries()], body: text, sentAt, doneAt });
    } catch (e) {
      setFailure(`The request didn’t complete: ${errorText(e)}. The app may have stopped; see Logs.`);
    } finally {
      setSending(false);
    }
  };

  const tabButton = (t: typeof tab, label: string) => (
    <button type="button" role="tab" aria-selected={tab === t} onClick={() => setTab(t)} className={cx("border-b-2 pb-1", tab === t ? "border-accent text-fg" : "border-transparent text-fg-secondary hover:text-fg")}>{label}</button>
  );
  const requestId = last?.headers.find(([k]) => k.toLowerCase() === "x-request-id")?.[1] ?? "";
  const { by: matchedBy, lines: related } = last ? linesForRequest(logs, requestId, last.sentAt, last.doneAt) : { by: "time" as const, lines: [] };
  return (
    <div className={cx("flex min-h-0 min-w-0 flex-1 overflow-y-auto", wide ? "gap-4 p-4" : "flex-col gap-3 p-3")}>
      <section aria-label="Request" className="flex min-w-0 flex-1 flex-col gap-3">
        <div className="flex items-center gap-2">
          <span className={cx("rounded px-1.5 py-0.5 font-mono text-11 font-bold", methodTone[op.method])}>{op.method}</span>
          <code className="min-w-0 truncate text-13 text-fg">{op.path}</code>
        </div>
        {op.summary && <h3 className="text-14 font-semibold text-fg">{op.summary}</h3>}
        {/* Plain text: the document is the agent's to write. */}
        {op.description && <p className="whitespace-pre-line text-12 text-fg-secondary">{op.description.trim()}</p>}
        {op.operationId && <p className="text-11 text-fg-tertiary">{op.operationId} · {op.tag}</p>}
        {op.source && <HandlerSource source={op.source} />}
        <p className="rounded-md border border-pill-done-fg/30 bg-pill-done-bg px-2.5 py-1.5 text-12 text-fg-2">Sends with the cookies of your Preview session, as the app’s own page would.</p>
        <div role="tablist" className="flex gap-4 text-12">
          {tabButton("params", `Params${op.params.length ? ` ${op.params.length}` : ""}`)}
          {tabButton("headers", "Headers")}
          {op.body && tabButton("body", "Body")}
        </div>
        {tab === "params" &&
          (op.params.length === 0 ? (
            <p className="text-12 text-fg-tertiary">No parameters.</p>
          ) : (
            <div className="flex flex-col gap-2">
              {op.params.map((p) => (
                <label key={`${p.in}:${p.name}`} className="flex flex-col gap-0.5 text-12">
                  <span className="text-fg-2">
                    <code className="font-mono">{p.name}</code> <span className="text-fg-tertiary">{p.in}{p.required ? ", required" : ""}</span>
                  </span>
                  <input value={values[`${p.in}:${p.name}`] ?? ""} placeholder={p.description || String(exampleFor(spec, p.schema) ?? "")} onChange={(e) => setValues((v) => ({ ...v, [`${p.in}:${p.name}`]: e.target.value }))} className="rounded-md border border-border-strong bg-surface-sunken px-2 py-1 font-mono text-fg focus:border-accent focus:outline-none" />
                </label>
              ))}
            </div>
          ))}
        {tab === "headers" && <textarea aria-label="Headers" rows={4} value={headers} onChange={(e) => setHeaders(e.target.value)} placeholder="Name: value, one per line" className="rounded-md border border-border-strong bg-surface-sunken p-2 font-mono text-12 text-fg focus:border-accent focus:outline-none" />}
        {tab === "body" && op.body && (
          <>
            <textarea aria-label="Body" spellCheck={false} rows={12} value={body} onChange={(e) => setBody(e.target.value)} className="min-h-40 rounded-md border border-border-strong bg-surface-sunken p-2 font-mono text-12 text-fg focus:border-accent focus:outline-none" />
            <button type="button" className="self-start text-12 text-accent hover:underline" onClick={() => setBody(JSON.stringify(exampleFor(spec, op.body!.schema), null, 2))}>Fill example</button>
          </>
        )}
        {warnings.map((w) => (
          <p key={w.path + w.message} className="text-12 text-pill-blocked-fg">⚠ {w.path} {w.message}</p>
        ))}
        {missing.length > 0 && <p className="text-12 text-fg-tertiary">Needs {missing.map((p) => p.name).join(", ")}.</p>}
        <div className="flex items-center gap-2">
          <Button variant="secondary" onClick={() => { void navigator.clipboard.writeText(curlFor(op.method, origin + path, headerMap, sendsBody ? body : undefined)); setCopied(true); setTimeout(() => setCopied(false), 1500); }}>
            {copied ? "Copied" : "Copy as curl"}
          </Button>
          <Button variant="primary" className="ml-auto" disabled={sending || missing.some((p) => p.in === "path")} onClick={() => void send()}>{sending ? "Sending…" : "Send"}</Button>
        </div>
        {warnings.length > 0 && <p className="text-11 text-fg-tertiary">Warnings don’t block sending: testing bad input is the point.</p>}
        {failure && <p role="alert" className="text-12 text-pill-blocked-fg">{failure}</p>}
      </section>
      <section aria-label="Response" data-testid="playground-response" className="flex min-w-0 flex-1 flex-col gap-2">
        {!last ? (
          <p className="text-12 text-fg-tertiary">Send the request to see the response.</p>
        ) : (
          <>
            <div className="flex flex-wrap items-center gap-2 text-12">
              <span className="text-13 font-semibold text-fg">Response</span>
              <span className={cx("rounded-full px-2 py-0.5 font-semibold", last.status >= 400 ? "bg-pill-blocked-bg text-pill-blocked-fg" : "bg-pill-done-bg text-pill-done-fg")}>{last.status}</span>
              <span className="text-fg-secondary">{last.ms} ms · {last.bytes} B{last.contentType ? ` · ${last.contentType.split(";")[0]}` : ""}</span>
            </div>
            <div role="tablist" className="flex gap-4 text-12">
              {(["body", "headers"] as const).map((t) => (
                <button key={t} type="button" role="tab" aria-selected={resTab === t} onClick={() => setResTab(t)} className={cx("border-b-2 pb-1 capitalize", resTab === t ? "border-accent text-fg" : "border-transparent text-fg-secondary hover:text-fg")}>{t}</button>
              ))}
            </div>
            <pre className="max-h-72 overflow-auto rounded-md border border-border-strong bg-surface-sunken p-2 font-mono text-12 text-fg-2">
              {resTab === "body" ? pretty(last.body, last.contentType) || "(empty)" : last.headers.map(([k, v]) => `${k}: ${v}`).join("\n")}
            </pre>
            <div className="mt-1 flex items-center text-12">
              <span className="font-semibold text-fg">Logs around this request</span>
              <button type="button" className="ml-auto text-accent hover:underline" onClick={onOpenLogs}>Open in Logs</button>
            </div>
            <div className="rounded-md border border-border-strong bg-surface-sunken p-2 font-mono text-11 leading-relaxed">
              {related.length === 0 ? (
                <p className="text-fg-tertiary">Nothing was logged while it ran.</p>
              ) : (
                related.map((l, i) => (
                  <div key={i} className="flex gap-2">
                    <span className="w-14 flex-none truncate text-fg-secondary">{l.source}</span>
                    <span className={cx("min-w-0 flex-1 break-words", isErrorLine(l) ? "text-pill-blocked-fg" : "text-fg-2")}>{l.text}</span>
                  </div>
                ))
              )}
              <p className="mt-1 font-sans text-11 text-fg-tertiary">
                {matchedBy === "id" ? <>Lines naming its request id, <code className="font-mono">{requestId}</code>.</> : "Matched by time: the app’s logs don’t show the request’s id, so lines from other requests at the same moment show too."}
              </p>
            </div>
          </>
        )}
      </section>
    </div>
  );
}

/** An inferred operation's handler, "file:line", to copy into an editor or a question. */
function HandlerSource({ source }: { source: NonNullable<Operation["source"]> }) {
  const [copied, setCopied] = useState(false);
  const ref = source.line ? `${source.file}:${source.line}` : source.file;
  return (
    <p className="flex items-center gap-2 text-11 text-fg-tertiary">
      Handler <code data-testid="playground-handler" className="min-w-0 truncate font-mono text-fg-2">{ref}</code>
      <button type="button" className="text-accent hover:underline" onClick={() => { void navigator.clipboard.writeText(ref); setCopied(true); setTimeout(() => setCopied(false), 1500); }}>
        {copied ? "Copied" : "Copy"}
      </button>
    </p>
  );
}

function Empty({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className="grid min-h-0 flex-1 place-items-center p-6">
      <div className="max-w-sm text-center">
        <p className="text-14 font-semibold text-fg">{title}</p>
        {children && <p className="mt-1 text-12 text-fg-secondary">{children}</p>}
      </div>
    </div>
  );
}
