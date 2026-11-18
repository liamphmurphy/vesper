"use client";

import { useContext, useEffect, useRef, useState } from "react";
import { cx } from "@/lib/cx";
import { Spinner } from "@/components/ui/loading";
import { formatBytes } from "@/lib/files";
import { Button, ButtonLink, buttonClass } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { RecommendActions } from "./recommend-fence";
import {
  VIDEO_STAGES, clock, frameUrl, plannedMeta, posterFrame, previewFrame, renderEta, renderTook, retryRequest, scriptName, stageStates,
  type ChatVideo, type StageState,
} from "@/lib/chat-video";

/**
 * A video a coding chat renders with code, as one card that follows its stages: the
 * renderer being written, the stills it checked, the render filling a filmstrip, and
 * finally a player (or what went wrong). It shows live under the turn while it works,
 * then on the reply.
 */
export function VideoCards({ chatId, videos, messageId, onStop }: { chatId: string; videos: ChatVideo[]; messageId?: string; onStop?: () => void }) {
  if (!videos.length) return null;
  return (
    <div className="flex w-full flex-col gap-3" data-testid="video-cards">
      {videos.map((v) => <VideoCard key={v.id} chatId={chatId} v={v} messageId={messageId} onStop={onStop} />)}
    </div>
  );
}

/** "▸ Renderer: cat.py (1,024 lines) · rendered in 3m 08s" under a finished video's reply. */
export function VideoRendererNotes({ videos }: { videos: ChatVideo[] }) {
  const done = videos.filter((v) => v.state === "done" && v.script_path);
  if (!done.length) return null;
  return (
    <div className="flex flex-col gap-1">
      {done.map((v) => {
        const took = renderTook(v);
        return (
          <details key={v.id} className="group text-12 text-fg-tertiary" data-testid="video-renderer">
            <summary className="cursor-pointer list-none select-none hover:text-fg-secondary [&::-webkit-details-marker]:hidden">
              <span className="inline-block transition-transform group-open:rotate-90">▸</span>{" "}
              Renderer: {scriptName(v.script_path)}{v.script_lines > 0 && ` (${v.script_lines.toLocaleString()} lines)`}{took && ` · rendered in ${took}`}
            </summary>
            <div className="mt-1.5 flex flex-col gap-1">
              <code className="text-11 text-fg-secondary">{v.script_path}</code>
              {v.script_tail && <pre className="overflow-x-auto rounded-lg border border-border-subtle bg-surface-sunken px-2.5 py-2 font-mono text-11 leading-[1.5] text-fg-secondary">{v.script_tail}</pre>}
            </div>
          </details>
        );
      })}
    </div>
  );
}

function VideoCard({ chatId, v, messageId, onStop }: { chatId: string; v: ChatVideo; messageId?: string; onStop?: () => void }) {
  const states = stageStates(v);
  const done = v.state === "done" && !!v.output;
  return (
    <div className="w-full max-w-[640px] overflow-hidden rounded-xl border border-border bg-surface" data-testid="video-card" data-stage={v.stage} data-state={v.state}>
      <div className="flex items-center gap-2 border-b border-border-subtle px-3 py-2.5">
        <span className="flex items-center gap-1 rounded bg-accent-soft px-1.5 py-px text-11 text-accent"><Icon name="play" size={9} />Video</span>
        <b className="min-w-0 truncate text-13 font-semibold text-fg">{v.title}</b>
        <span className="flex-1" />
        <span className="flex-none text-12 text-fg-tertiary">{done ? v.output!.filename : plannedMeta(v)}</span>
      </div>
      <Pipeline states={states} />
      {done ? (
        <Ready chatId={chatId} v={v} />
      ) : v.state === "failed" ? (
        <Failed chatId={chatId} v={v} messageId={messageId} />
      ) : v.stage === "write" ? (
        <Writing v={v} />
      ) : v.stage === "stills" ? (
        <Stills chatId={chatId} v={v} />
      ) : (
        <Rendering chatId={chatId} v={v} onStop={onStop} />
      )}
    </div>
  );
}

function Pipeline({ states }: { states: StageState[] }) {
  return (
    <ol className="flex flex-wrap items-center gap-1.5 border-b border-border-subtle px-3 py-2 text-12" aria-label="Stages">
      {VIDEO_STAGES.map((s, i) => (
        <li key={s.id} className="flex items-center gap-1.5" data-state={states[i]}>
          {i > 0 && <span className="h-px w-3 bg-border-strong" aria-hidden />}
          <span className={cx("flex items-center gap-1.5", { done: "text-fg-secondary", active: "text-fg", failed: "text-pill-blocked-fg", pending: "text-fg-tertiary" }[states[i]])}>
            <StageDot state={states[i]} />
            {s.label}
            <span className="sr-only">{` (${states[i]})`}</span>
          </span>
        </li>
      ))}
    </ol>
  );
}

function StageDot({ state }: { state: StageState }) {
  const base = "grid size-3.5 flex-none place-items-center rounded-full border-[1.5px] text-10 font-bold leading-none";
  if (state === "done") return <span className={cx(base, "border-state-done bg-state-done text-bg")} aria-hidden>✓</span>;
  if (state === "failed") return <span className={cx(base, "border-state-blocked bg-state-blocked text-bg")} aria-hidden>!</span>;
  if (state === "active") return <span className={cx(base, "video-spin border-state-progress border-t-transparent")} aria-hidden />;
  return <span className={cx(base, "border-border-strong")} aria-hidden />;
}

function Writing({ v }: { v: ChatVideo }) {
  return (
    <div className="p-3">
      <div className="mb-1.5 flex items-center gap-2 text-12 text-fg-secondary">
        <Spinner />
        Writing {v.script_path ? scriptName(v.script_path) : "the renderer"}
        <span className="flex-1" />
        {v.script_lines > 0 && <span className="text-fg-tertiary">{v.script_lines.toLocaleString()} lines</span>}
      </div>
      {v.script_tail && (
        <pre className="mb-2.5 h-24 overflow-hidden rounded-lg border border-border-subtle bg-surface-sunken px-2.5 py-2 font-mono text-11 leading-[1.5] text-fg-secondary [mask-image:linear-gradient(#000_70%,transparent)]" data-testid="video-script">
          {v.script_tail}
        </pre>
      )}
      <div className="video-shimmer grid aspect-video place-items-center rounded-lg text-12 text-fg-tertiary">The preview shows up once the stills are rendered</div>
    </div>
  );
}

function StillGrid({ chatId, v, dim }: { chatId: string; v: ChatVideo; dim?: boolean }) {
  const stills = v.frames.filter((f) => f.kind === "still").sort((a, b) => a.idx - b.idx);
  const pad = dim ? 0 : Math.max(0, 4 - stills.length);
  if (!stills.length && !pad) return null;
  return (
    <div className={cx("grid grid-cols-4 gap-2", dim && "opacity-60")} data-testid="video-stills">
      {stills.map((f) => (
        <div key={f.idx} className="relative aspect-video overflow-hidden rounded-md bg-surface-sunken">
          {/* A same-origin, private URL: next/image would only add a proxy hop. */}
          <img src={frameUrl(chatId, v, "still", f.idx)} alt={`Frame ${f.idx}`} className="block size-full object-cover" />
          <span className="absolute bottom-1 left-1.5 text-10 text-[#fff] [text-shadow:0_1px_2px_#000]">frame {f.idx}</span>
          {!dim && <span className="absolute right-1.5 top-1 text-11 text-[#fff] [text-shadow:0_1px_2px_#000]" aria-hidden>✓</span>}
        </div>
      ))}
      {Array.from({ length: pad }, (_, i) => <div key={`pad-${i}`} className="video-shimmer aspect-video rounded-md" aria-hidden />)}
    </div>
  );
}

function Stills({ chatId, v }: { chatId: string; v: ChatVideo }) {
  const n = v.frames.filter((f) => f.kind === "still").length;
  const checking = v.checks.some((c) => c.passed === undefined || c.passed === null);
  return (
    <div className="p-3">
      <div className="mb-2 flex items-center gap-2 text-12 text-fg-secondary">
        {checking || !v.checks.length ? <Spinner /> : <span className="text-pill-done-fg" aria-hidden>✓</span>}
        Rendering {n || "a few"} stills and checking them before the full render
      </div>
      <StillGrid chatId={chatId} v={v} />
      {v.checks.length > 0 && (
        <ul className="mt-2.5 flex flex-col gap-1 text-12 text-fg-secondary" data-testid="video-checks">
          {v.checks.map((c, i) => (
            <li key={i} className={cx("transition-opacity", c.passed === undefined || c.passed === null ? "opacity-40" : "opacity-100")}>
              {c.passed === true ? <span className="text-pill-done-fg">✓</span> : c.passed === false ? <span className="text-pill-blocked-fg">✗</span> : "○"} {c.label}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Now, ticking once a second while shown. */
function useNow(on: boolean) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!on) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [on]);
  return now;
}

function Rendering({ chatId, v, onStop }: { chatId: string; v: ChatVideo; onStop?: () => void }) {
  const now = useNow(v.stage === "render");
  const pick = previewFrame(v);
  const src = pick && frameUrl(chatId, v, pick.kind, pick.idx);
  const pct = v.frames_total ? Math.min(100, (v.frames_done / v.frames_total) * 100) : 0;
  const badge = { render: "Rendering", encode: "Encoding", save: "Saving" }[v.stage as "render" | "encode" | "save"] ?? "Rendering";
  const cells = new Map(v.frames.filter((f) => f.kind === "strip").map((f) => [f.idx, f]));
  return (
    <div className="p-3">
      <div className="relative aspect-video overflow-hidden rounded-lg bg-[#000]">
        {src ? <img src={src} alt="The latest rendered frame" className="block size-full object-cover" /> : <div className="video-shimmer size-full" />}
        <span className="absolute left-2 top-2 rounded bg-[rgb(0_0_0/0.65)] px-1.5 py-0.5 text-11 text-[#fff]"><span className="video-blink text-state-blocked">●</span> {badge}</span>
        {v.frames_total > 0 && <span className="absolute right-2 top-2 rounded bg-[rgb(0_0_0/0.65)] px-1.5 py-0.5 font-mono text-11 text-[#fff]" data-testid="video-frames">{v.frames_done} / {v.frames_total}</span>}
        {v.stage === "render" && <div className="video-sweep" aria-hidden />}
      </div>
      <div className="mb-1.5 mt-2.5 h-1 overflow-hidden rounded-sm bg-track" role="progressbar" aria-label="Render progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(pct)}>
        <div className="h-full bg-gradient-to-r from-accent to-state-review transition-[width] duration-(--motion-progress)" style={{ width: `${pct}%` }} />
      </div>
      <div className="flex items-center gap-2 text-12 text-fg-tertiary">
        {v.stage === "render" ? (
          <span data-testid="video-eta">{renderEta(v, now)}</span>
        ) : (
          <span className="flex items-center gap-1.5"><Spinner />{v.stage === "encode" ? `Encoding${v.stage_note ? ` ${v.stage_note}` : ""}…` : "Saving to your Library…"}</span>
        )}
        <span className="flex-1" />
        {onStop && v.stage !== "save" && <Button variant="secondary" onClick={onStop}>Stop</Button>}
      </div>
      <div className="mt-2.5 grid grid-cols-[repeat(30,minmax(0,1fr))] gap-0.5" data-testid="video-strip" aria-label="Filmstrip">
        {Array.from({ length: 30 }, (_, i) => (
          <div key={i} className="aspect-video overflow-hidden rounded-[2px] bg-surface-sunken">
            {cells.has(i) && <img src={frameUrl(chatId, v, "strip", i)} alt="" className="block size-full object-cover" />}
          </div>
        ))}
      </div>
    </div>
  );
}

function Ready({ chatId, v }: { chatId: string; v: ChatVideo }) {
  const out = v.output!;
  const ref = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  const [at, setAt] = useState(0);
  const [length, setLength] = useState((out.duration_ms ?? v.duration_ms) / 1000);
  const src = `/api/v1/chats/${chatId}/videos/${v.id}/content`;
  const poster = posterFrame(v);
  const toggle = () => {
    const el = ref.current;
    if (!el) return;
    if (el.paused) void el.play();
    else el.pause();
  };
  const meta = [`${v.width}×${v.height}`, `${v.fps} fps`, out.codec, formatBytes(out.size_bytes)].filter(Boolean).join(" · ");
  return (
    <>
      <div className="relative bg-[#000]">
        <video
          ref={ref}
          src={src}
          poster={poster && frameUrl(chatId, v, poster.kind, poster.idx)}
          preload="metadata"
          playsInline
          onClick={toggle}
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
          onEnded={() => setPlaying(false)}
          onTimeUpdate={(e) => setAt(e.currentTarget.currentTime)}
          onLoadedMetadata={(e) => Number.isFinite(e.currentTarget.duration) && setLength(e.currentTarget.duration)}
          className="block aspect-video w-full cursor-pointer"
          data-testid="video-player"
        />
        {!playing && (
          <button type="button" onClick={toggle} aria-label="Play" className="absolute inset-0 m-auto grid size-14 place-items-center rounded-full bg-bg/80 text-fg backdrop-blur-sm transition-transform hover:scale-105">
            <Icon name="play" size={20} />
          </button>
        )}
      </div>
      <div className="flex items-center gap-2.5 bg-surface-sunken px-2.5 py-1.5 text-12 text-fg-secondary">
        <button type="button" onClick={toggle} aria-label={playing ? "Pause" : "Play"} className="text-fg hover:text-accent">
          <Icon name={playing ? "pause" : "play"} size={13} />
        </button>
        <input
          type="range"
          aria-label="Seek"
          min={0}
          max={length || 0}
          step={0.01}
          value={Math.min(at, length || 0)}
          onChange={(e) => {
            const el = ref.current;
            if (el) el.currentTime = Number(e.target.value);
            setAt(Number(e.target.value));
          }}
          className="h-1 flex-1 cursor-pointer accent-[var(--accent)]"
        />
        <span className="font-mono tabular-nums">{clock(at * 1000)} / {clock(length * 1000)}</span>
        <a href={`${src}?download=true`} download={out.filename} aria-label="Download" className="text-fg hover:text-accent"><Icon name="download" size={13} /></a>
        <button type="button" aria-label="Full screen" onClick={() => void ref.current?.requestFullscreen?.()} className="text-fg hover:text-accent"><Icon name="expand" size={13} /></button>
      </div>
      <div className="flex flex-wrap items-center gap-2 border-t border-border-subtle px-3 py-2.5">
        {v.library_item_id && <span className="rounded-full bg-pill-done-bg px-2 py-0.5 text-11 text-pill-done-fg">✓ Saved to Library</span>}
        <span className="text-12 text-fg-tertiary" data-testid="video-meta">{meta}</span>
        <span className="flex-1" />
        <a href={`${src}?download=true`} download={out.filename} className={buttonClass("secondary")}>Download</a>
        {v.library_item_id && <ButtonLink href={`/library?tab=videos&item=${v.library_item_id}`}>Open in Library</ButtonLink>}
      </div>
    </>
  );
}

function Failed({ chatId, v, messageId }: { chatId: string; v: ChatVideo; messageId?: string }) {
  const actions = useContext(RecommendActions);
  const [log, setLog] = useState(false);
  const stage = VIDEO_STAGES.find((s) => s.id === v.stage) ?? VIDEO_STAGES[0];
  const stopped = v.failure_kind === "stopped";
  return (
    <div className="p-3">
      <StillGrid chatId={chatId} v={v} dim />
      <div className="mt-2.5 rounded-lg border border-state-blocked/35 bg-pill-blocked-bg px-3 py-2.5 first:mt-0" role="alert">
        <b className="text-13 text-pill-blocked-fg">{stopped ? "Stopped" : stage.failed}</b>
        <p className="mb-2 mt-1 text-13 text-fg-2">{v.error}</p>
        {log && v.error_log && (
          <pre className="mb-2 max-h-48 overflow-auto rounded-md border border-border-subtle bg-surface-sunken px-2.5 py-2 font-mono text-11 leading-[1.5] text-fg-secondary" data-testid="video-log">{v.error_log}</pre>
        )}
        <div className="flex flex-wrap items-center gap-2">
          {actions && messageId && (
            <Button variant="secondary" disabled={actions.disabled} onClick={() => actions.ask(messageId, retryRequest(v))}>{stage.retry}</Button>
          )}
          {v.error_log && <Button variant="secondary" onClick={() => setLog((x) => !x)}>{log ? "Hide log" : "Show log"}</Button>}
          <span className="flex-1" />
          <span className="rounded-full bg-pill-blocked-bg px-2 py-0.5 text-11 text-pill-blocked-fg">Not saved</span>
        </div>
      </div>
    </div>
  );
}
