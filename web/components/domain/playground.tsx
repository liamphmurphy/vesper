"use client";

import { useContext, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { useChatPlayground, usePlaygroundAction, type Playground } from "@/lib/api/playground-hooks";
import { cx } from "@/lib/cx";
import { CaptureError, captureElement } from "@/lib/frame-capture";
import { ago, idleRule, isErrorLine, parsePlaygroundFence, playgroundOrigin, type LogLine } from "@/lib/playground";
import { applyProbe, emptyProbe, playgroundReport, reportNames, sendToComposer, type ProbeState } from "@/lib/playground-report";
import { usePlaygroundPanel, type PlaygroundTab } from "@/lib/use-playground-panel";
import { Button, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { CodeFence } from "./code-fence";
import { ApiTab, LogsTab, PreviewTab, usePlaygroundLogs } from "./playground-tabs";
import { RecommendActions } from "./recommend-fence";
import { LoadingText } from "@/components/ui/loading";

// A chat's playground: the app its agent is building, running on the runner
// with fresh services, opened beside the chat or over the whole window.

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
const noSubscribe = () => () => {};

/** Now, ticking every half minute: enough for "6 min ago". */
function useNow() {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);
  return now;
}

/** The playground's origin, once in the browser (it follows the page's host). */
function useOrigin(pg: Playground | null | undefined) {
  const loc = useSyncExternalStore(noSubscribe, () => window.location, () => null);
  return loc && pg?.port && (pg.state === "running" || pg.state === "starting") ? playgroundOrigin(loc, pg.port) : null;
}

/** What the gateway's probe in the Preview frame reports; only messages from the playground's own origin count. */
function usePlaygroundProbe(origin: string | null) {
  const [probe, setProbe] = useState<ProbeState>(emptyProbe);
  useEffect(() => {
    if (!origin) return;
    const onMessage = (e: MessageEvent) => {
      if (e.origin === origin) setProbe((s) => applyProbe(s, e.data, Date.now()));
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [origin]);
  return { probe, reset: () => setProbe(emptyProbe()) };
}

/**
 * "Send to chat": a report of the page, console errors and failed requests,
 * and a screenshot of the frame, attached to the next message. The browser
 * asks to share the tab for each screenshot; declining still sends the report.
 */
function SendToChat({ chatId, origin, branch, probe, logs, frame, onSent }: {
  chatId: string;
  origin: string;
  branch?: string | null;
  probe: ProbeState;
  logs: LogLine[];
  frame: HTMLIFrameElement | null;
  onSent: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string>();
  const send = async () => {
    setBusy(true);
    setProblem(undefined);
    const at = Date.now();
    const names = reportNames(at);
    const files: File[] = [];
    let noScreenshot: string | undefined = frame ? undefined : "the Preview tab wasn’t open";
    if (frame) {
      try {
        files.push(new File([await captureElement(frame)], names.screenshot, { type: "image/png" }));
      } catch (e) {
        noScreenshot = e instanceof CaptureError ? e.message : "the screen couldn’t be captured";
      }
    }
    const report = playgroundReport({ origin, probe, logs, branch, at, noScreenshot });
    files.unshift(new File([report], names.report, { type: "text/markdown" }));
    setBusy(false);
    if (!sendToComposer(chatId, { files })) {
      setProblem("Open the chat to attach it.");
      return;
    }
    onSent();
  };
  return (
    <>
      {problem && <span role="alert" className="text-12 text-pill-blocked-fg">{problem}</span>}
      <Button variant="secondary" disabled={busy} onClick={send} title="Attach the page, console errors, failed requests and a screenshot to your next message">
        {busy ? "Capturing…" : "Send to chat"}
      </Button>
    </>
  );
}

function StatusPill({ pg }: { pg: Playground }) {
  const [label, tone] =
    pg.action === "reset" ? ["Resetting", "review"] : pg.action === "stop" ? ["Stopping", "neutral"] :
    pg.state === "running" ? ["Running", "done"] : pg.state === "starting" ? ["Starting", "review"] : pg.state === "failed" ? ["Failed", "blocked"] : ["Stopped", "neutral"];
  return (
    <span data-testid="playground-state" className={cx("inline-flex flex-none items-center gap-1.5 rounded-full px-2 py-0.5 text-11 font-semibold", `bg-pill-${tone}-bg text-pill-${tone}-fg`)}>
      <span aria-hidden className="size-1.5 rounded-full bg-current" />
      {label}
    </span>
  );
}
// Tailwind needs the full class names present in source:
// bg-pill-review-bg text-pill-review-fg bg-pill-neutral-bg text-pill-neutral-fg bg-pill-done-bg text-pill-done-fg bg-pill-blocked-bg text-pill-blocked-fg

/** The playground: header, tabs and the running app; `full` lays it out over the whole window. */
function PlaygroundView({ chatId, pg, full }: { chatId: string; pg: Playground; full: boolean }) {
  const panel = usePlaygroundPanel();
  const act = usePlaygroundAction(chatId);
  const origin = useOrigin(pg);
  const running = pg.state === "running" && !pg.action;
  const logs = usePlaygroundLogs(running || pg.action === "reset" ? origin : null);
  const errors = logs.lines.slice(-200).filter(isErrorLine).length;
  const { probe, reset: resetProbe } = usePlaygroundProbe(running ? origin : null);
  const [frame, setFrame] = useState<HTMLIFrameElement | null>(null);
  const now = useNow();
  const tab = (t: PlaygroundTab, label: string, badge?: number) => (
    <button type="button" role="tab" aria-selected={panel.tab === t} onClick={() => panel.setTab(t)} className={cx("flex items-center gap-1.5 border-b-2 px-0.5 pb-2 pt-2.5 text-13", panel.tab === t ? "border-accent font-semibold text-fg" : "border-transparent text-fg-secondary hover:text-fg")}>
      {label}
      {!!badge && <span aria-label={`${badge} errors`} className="rounded-full bg-pill-blocked-bg px-1.5 text-10 font-semibold text-pill-blocked-fg">{badge}</span>}
    </button>
  );
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-2 border-b border-border-subtle px-4 py-2.5">
        {full && <Button variant="secondary" onClick={panel.exitFull}>← Back to chat</Button>}
        <h2 className="text-14 font-semibold text-fg">Playground</h2>
        <StatusPill pg={pg} />
        {pg.branch && <code className="min-w-0 truncate font-mono text-12 text-fg-secondary">{pg.branch}</code>}
        <span className="ml-auto flex items-center gap-1">
          {origin && running && (
            <a href={origin} target="_blank" rel="noopener noreferrer" aria-label="Open in a new tab" title="Open in a new tab" className="grid size-7 place-items-center rounded-sm text-fg-secondary hover:bg-hover hover:text-fg">↗</a>
          )}
          {full ? <IconButton icon="shrink" label="Exit full screen" onClick={panel.exitFull} /> : <IconButton icon="expand" label="Full screen" onClick={panel.openFull} />}
          <IconButton icon="x" label="Close playground" onClick={panel.close} />
        </span>
      </div>
      <div className="flex items-center gap-4 border-b border-border-subtle px-4">
        <span role="tablist" aria-label="Playground view" className="flex items-center gap-4">
          {tab("preview", "Preview")}
          {tab("api", "API")}
          {tab("logs", "Logs", errors)}
        </span>
        <span className="ml-auto flex items-center gap-2 py-1.5">
          {(pg.state === "running" || pg.state === "starting") && (
            <>
              {running && origin && (
                <SendToChat chatId={chatId} origin={origin} branch={pg.branch} probe={probe} logs={logs.lines} frame={panel.tab === "preview" ? frame : null} onSent={full ? panel.exitFull : () => {}} />
              )}
              <Button variant="secondary" disabled={!running || act.isPending} onClick={() => act.mutate("reset")}>↺ Reset data</Button>
              <Button variant="secondary" disabled={pg.action === "stop" || act.isPending} onClick={() => act.mutate("stop")}>■ Stop</Button>
            </>
          )}
          {(pg.state === "stopped" || pg.state === "failed") && <Button variant="primary" disabled={act.isPending} onClick={() => act.mutate("start")}>Start again</Button>}
        </span>
      </div>
      {act.isError && <p role="alert" className="border-b border-border-row px-4 py-1 text-12 text-pill-blocked-fg">{errorText(act.error)}</p>}
      {running && origin ? (
        panel.tab === "api" ? (
          <ApiTab chatId={chatId} pg={pg} origin={origin} logs={logs.lines} wide={full} onOpenLogs={() => panel.setTab("logs")} />
        ) : panel.tab === "logs" ? (
          <LogsTab logs={logs} />
        ) : (
          <PreviewTab origin={origin} frameRef={setFrame} livePath={probe.path} onReload={resetProbe} />
        )
      ) : (
        <NotRunning pg={pg} />
      )}
      <div className="flex flex-wrap items-center gap-x-3 gap-y-0.5 border-t border-border-subtle px-4 py-2 text-12 text-fg-tertiary">
        <span className="text-fg-secondary">
          {[...pg.processes.map((p) => `${p.name} :${p.port}`), ...pg.services.map((s) => s.image)].join(" · ")}
        </span>
        {pg.state === "running" && pg.data_reset_at && <span>Fresh data {ago(pg.data_reset_at, now)}</span>}
        {pg.state === "running" && <span>{idleRule(pg.idle_ttl_seconds)}</span>}
        <span className="ml-auto">Your session only</span>
      </div>
    </div>
  );
}

/** Starting, failed or stopped: what it's doing, or why it isn't running. */
function NotRunning({ pg }: { pg: Playground }) {
  if (pg.state === "running") {
    return <div className="grid flex-1 place-items-center text-12 text-fg-secondary">{pg.step || "Resetting data"}…</div>;
  }
  if (pg.state === "starting") {
    return (
      <div className="grid flex-1 place-items-center p-6 text-center">
        <div>
          <p className="text-14 font-semibold text-fg">Starting</p>
          <p data-testid="playground-step" className="mt-1 text-12 text-fg-secondary">{pg.step || "Waiting for a runner"}…</p>
          <p className="mt-3 text-11 text-fg-tertiary">The first start installs dependencies and can take a few minutes.</p>
        </div>
      </div>
    );
  }
  if (pg.state === "failed") {
    return (
      <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-auto p-4">
        <p role="alert" className="text-14 font-semibold text-pill-blocked-fg">{pg.error}</p>
        {pg.error_log && <pre data-testid="playground-error-log" className="overflow-auto rounded-md border border-border-strong bg-surface-sunken p-2 font-mono text-12 text-fg-2">{pg.error_log}</pre>}
        <p className="text-12 text-fg-secondary">Ask the agent to fix it, or start it again.</p>
      </div>
    );
  }
  return (
    <div className="grid flex-1 place-items-center p-6 text-center">
      <div>
        <p className="text-14 font-semibold text-fg">Stopped</p>
        <p className="mt-1 text-12 text-fg-secondary">{pg.stop_reason || "It isn’t running."} Its data starts fresh when it starts again.</p>
      </div>
    </div>
  );
}

/**
 * The playground in the desktop dock's tab while the person keeps talking to the agent (fullscreen
 * shows over the window instead); `sheet` fills the compact panel sheet, so fullscreen shows there too.
 */
export function PlaygroundPanel({ chatId, sheet }: { chatId: string; sheet?: boolean }) {
  const panel = usePlaygroundPanel();
  const pg = useChatPlayground(chatId).data;
  if (!panel.open || (panel.fullscreen && !sheet) || !pg) return null;
  return (
    <aside aria-label="Playground" data-testid="playground-panel" className="flex min-h-0 flex-1 flex-col bg-panel">
      <PlaygroundView chatId={chatId} pg={pg} full={false} />
    </aside>
  );
}

/** Over the whole window; Escape goes back to the panel. */
export function PlaygroundFullscreen({ chatId }: { chatId: string }) {
  const panel = usePlaygroundPanel();
  const pg = useChatPlayground(chatId).data;
  const mounted = useSyncExternalStore(noSubscribe, () => true, () => false);
  // Only while it's showing: Escape elsewhere mustn't open the playground (in the dock, as a tab).
  const shown = panel.fullscreen && !!pg;
  const exit = useRef<(() => void) | null>(null);
  useEffect(() => {
    exit.current = shown ? panel.exitFull : null;
  });
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !(e.target as Element).closest?.("input, textarea, select")) exit.current?.();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  if (!panel.fullscreen || !pg || !mounted) return null;
  return createPortal(
    <section role="dialog" aria-modal="true" aria-label="Playground" data-testid="playground-fullscreen" className="fixed inset-0 z-[100] flex flex-col bg-panel">
      <PlaygroundView chatId={chatId} pg={pg} full />
    </section>,
    document.body,
  );
}

/** A ```playground fence: the chat's playground as a card that opens it. */
export function PlaygroundFence({ code, info }: { code: string; info?: string }) {
  const id = parsePlaygroundFence(code);
  const chatId = useContext(RecommendActions)?.chatId;
  const q = useChatPlayground(id ? chatId : undefined);
  const panel = usePlaygroundPanel();
  const pg = q.data;
  if (!id || !chatId || q.isError || (q.isSuccess && pg?.id !== id)) return <CodeFence code={code} info={info} />;
  const accent = pg?.state === "running" ? "bg-pill-done-fg" : pg?.state === "failed" ? "bg-pill-blocked-fg" : "bg-fg-tertiary";
  const detail = !pg
    ? <LoadingText className="w-32" />
    : pg.state === "running"
      ? [pg.processes.map((p) => p.name).join(", "), ...pg.services.map((s) => s.image)].join(" · ")
      : pg.state === "starting"
        ? `${pg.step || "Starting"}…`
        : pg.state === "failed"
          ? pg.error
          : pg.stop_reason || "Stopped";
  return (
    <div data-testid="playground-card" className="relative flex w-[480px] max-w-full items-center gap-3 overflow-hidden rounded-xl border border-border bg-surface py-3 pl-4 pr-3">
      <span aria-hidden className={cx("absolute inset-y-0 left-0 w-1", accent)} />
      <Icon name="play" size={16} className="flex-none text-fg-tertiary" />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="type-micro uppercase text-fg-tertiary">Playground</span>
        <span className="truncate text-14 font-semibold text-fg">{pg?.branch || "This chat’s app"}</span>
        <span className="truncate text-12 text-fg-secondary">{detail}</span>
      </span>
      <Button variant="primary" disabled={!pg} onClick={panel.show}>Open</Button>
    </div>
  );
}
