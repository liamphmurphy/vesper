"use client";

import { useContext, useState } from "react";
import { cx } from "@/lib/cx";
import { formatBytes } from "@/lib/files";
import { Button, ButtonLink, buttonClass } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { RecommendActions } from "./recommend-fence";
import { AudioPlayer } from "./audio-player";
import {
  AUDIO_STAGES,
  audioRetryRequest,
  audioStageStates,
  isMusicAudio,
  musicErrorCopy,
  stagesForAudio,
  type AudioStageState,
  type ChatAudio,
} from "@/lib/chat-audio";
import { clock, scriptName } from "@/lib/chat-video";

/**
 * Audio a chat creates — either code-rendered during a turn or AI-generated music —
 * shown as one card following its pipeline stages, then an inline player or structured error.
 */
export function AudioCards({
  chatId,
  audio,
  messageId,
  onStop,
  onStopAudio,
  onRetryMusic,
}: {
  chatId: string;
  audio: ChatAudio[];
  messageId?: string;
  onStop?: () => void;
  onStopAudio?: (audioId: string) => void;
  onRetryMusic?: (a: ChatAudio) => void;
}) {
  if (!audio.length) return null;
  return (
    <div className="flex w-full flex-col gap-3" data-testid="audio-cards">
      {audio.map((a) => (
        <AudioCard
          key={a.id}
          chatId={chatId}
          a={a}
          messageId={messageId}
          onStop={onStop}
          onStopAudio={onStopAudio}
          onRetryMusic={onRetryMusic}
        />
      ))}
    </div>
  );
}

function AudioCard({
  chatId,
  a,
  messageId,
  onStop,
  onStopAudio,
  onRetryMusic,
}: {
  chatId: string;
  a: ChatAudio;
  messageId?: string;
  onStop?: () => void;
  onStopAudio?: (audioId: string) => void;
  onRetryMusic?: (a: ChatAudio) => void;
}) {
  const music = isMusicAudio(a);
  const stages = stagesForAudio(a);
  const states = audioStageStates(a);
  const done = a.state === "done" && !!a.output;
  return (
    <div
      className="w-full max-w-[640px] overflow-hidden rounded-xl border border-border bg-surface"
      data-testid="audio-card"
      data-source-kind={a.source_kind ?? "code"}
      data-stage={a.stage}
      data-state={a.state}
    >
      <div className="flex items-center gap-2 border-b border-border-subtle px-3 py-2.5">
        <span className="flex items-center gap-1 rounded bg-accent-soft px-1.5 py-px text-11 text-accent">
          <Icon name="audio" size={9} />
          {music ? "Music" : "Audio"}
        </span>
        <b className="min-w-0 truncate text-13 font-semibold text-fg">{a.title}</b>
        <span className="flex-1" />
        <span className="flex-none text-12 text-fg-tertiary">{done ? a.output!.filename : `~${clock(a.duration_ms)}`}</span>
      </div>
      <ol className="flex flex-wrap items-center gap-1.5 border-b border-border-subtle px-3 py-2 text-12" aria-label="Stages">
        {stages.map((s, i) => (
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
      {done ? (
        <Ready chatId={chatId} a={a} />
      ) : a.state === "failed" ? (
        <Failed a={a} messageId={messageId} onRetryMusic={onRetryMusic} />
      ) : (
        <Working a={a} onStop={music && onStopAudio ? () => onStopAudio(a.id) : onStop} />
      )}
    </div>
  );
}

function StageDot({ state }: { state: AudioStageState }) {
  const base = "grid size-3.5 flex-none place-items-center rounded-full border-[1.5px] text-10 font-bold leading-none";
  if (state === "done") return <span className={cx(base, "border-state-done bg-state-done text-bg")} aria-hidden>✓</span>;
  if (state === "failed") return <span className={cx(base, "border-state-blocked bg-state-blocked text-bg")} aria-hidden>!</span>;
  if (state === "active") return <span className={cx(base, "video-spin border-state-progress border-t-transparent")} aria-hidden />;
  return <span className={cx(base, "border-border-strong")} aria-hidden />;
}

function Checks({ a }: { a: ChatAudio }) {
  if (!a.checks.length) return null;
  return (
    <ul className="mt-2.5 flex flex-col gap-1 text-12 text-fg-secondary" data-testid="audio-checks">
      {a.checks.map((c, i) => (
        <li key={i} className={cx("transition-opacity", c.passed === undefined || c.passed === null ? "opacity-40" : "opacity-100")}>
          {c.passed === true ? <span className="text-pill-done-fg">✓</span> : c.passed === false ? <span className="text-pill-blocked-fg">✗</span> : "○"} {c.label}
        </li>
      ))}
    </ul>
  );
}

/** What the card says while the agent works: the stage, the renderer's progress and the numbers it measured. */
function Working({ a, onStop }: { a: ChatAudio; onStop?: () => void }) {
  const music = isMusicAudio(a);
  const line = music
    ? {
        compose: a.stage_note || "Queued…",
        render: a.stage_note || "Generating music…",
        check: a.stage_note || "Checking audio…",
        save: a.stage_note || "Saving to your Library…",
      }[a.stage]
    : {
        compose: a.script_path ? `Writing ${scriptName(a.script_path)}…` : "Writing the music or sound…",
        render: a.stage_note || "Rendering…",
        check: "Measuring the file: you can’t listen from here, so the checks are numbers",
        save: "Saving to your Library…",
      }[a.stage];
  return (
    <div className="p-3">
      <div className="mb-1.5 flex items-center gap-2 text-12 text-fg-secondary">
        <span className="video-spin inline-block size-[11px] flex-none rounded-full border-[1.5px] border-accent border-t-transparent" aria-hidden />
        <span data-testid="audio-note">{line}</span>
        <span className="flex-1" />
        {a.stage === "render" && a.percent > 0 && <span className="font-mono text-fg-tertiary" data-testid="audio-percent">{a.percent}%</span>}
      </div>
      <div className="h-1 overflow-hidden rounded-sm bg-track" role="progressbar" aria-label="Render progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={a.percent}>
        <div className="h-full bg-gradient-to-r from-accent to-state-review transition-[width] duration-(--motion-progress)" style={{ width: `${a.percent}%` }} />
      </div>
      {a.method && <p className="mt-2 text-12 text-fg-tertiary" data-testid="audio-method">{a.method}</p>}
      <Checks a={a} />
      {onStop && a.stage !== "save" && <div className="mt-2.5 flex"><Button variant="secondary" onClick={onStop}>Stop</Button></div>}
    </div>
  );
}

function Ready({ chatId, a }: { chatId: string; a: ChatAudio }) {
  const out = a.output!;
  const src = `/api/v1/chats/${chatId}/audio/${a.id}/content`;
  const hasPromptDetails = isMusicAudio(a) && (!!a.prompt || !!a.lyrics || !!a.instrumental);
  return (
    <>
      <div className="p-3">
        <AudioPlayer src={src} peaks={a.peaks} durationMs={out.duration_ms ?? a.duration_ms} />
        <Checks a={a} />
        {hasPromptDetails && (
          <details className="mt-2.5 rounded-md border border-border-subtle bg-surface-sunken px-2.5 py-2 text-12">
            <summary className="cursor-pointer select-none font-medium text-fg-secondary hover:text-fg">
              Prompt &amp; lyrics{a.instrumental ? " · Instrumental" : ""}
            </summary>
            <div className="mt-2 flex flex-col gap-1.5 text-fg-secondary">
              {a.prompt && <p className="whitespace-pre-wrap">{a.prompt}</p>}
              {a.lyrics && (
                <p className="whitespace-pre-wrap border-t border-border-subtle pt-1.5 text-fg-tertiary">{a.lyrics}</p>
              )}
            </div>
          </details>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-2 border-t border-border-subtle px-3 py-2.5">
        {a.library_item_id && <span className="rounded-full bg-pill-done-bg px-2 py-0.5 text-11 text-pill-done-fg">✓ Saved to Library</span>}
        <span className="text-12 text-fg-tertiary" data-testid="audio-meta">{[a.method, formatBytes(out.size_bytes)].filter(Boolean).join(" · ")}</span>
        <span className="flex-1" />
        <a href={`${src}?download=true`} download={out.filename} className={buttonClass("secondary")}>Download</a>
        {a.library_item_id && <ButtonLink href={`/library?tab=audio&item=${a.library_item_id}`}>Open in Library</ButtonLink>}
      </div>
    </>
  );
}

function Failed({
  a,
  messageId,
  onRetryMusic,
}: {
  a: ChatAudio;
  messageId?: string;
  onRetryMusic?: (a: ChatAudio) => void;
}) {
  const actions = useContext(RecommendActions);
  const [log, setLog] = useState(false);

  if (isMusicAudio(a)) {
    const copy = musicErrorCopy(a);
    return (
      <div className="p-3">
        <div className="rounded-lg border border-state-blocked/35 bg-pill-blocked-bg px-3 py-2.5" role="alert">
          <b className="text-13 text-pill-blocked-fg">{copy.title}</b>
          <p className="mb-2 mt-1 text-13 text-fg-2">{copy.body}</p>
          <div className="flex flex-wrap items-center gap-2">
            {onRetryMusic && (
              <Button variant="secondary" onClick={() => onRetryMusic(a)}>
                {copy.actionLabel}
              </Button>
            )}
            {copy.showSettingsLink && (
              <ButtonLink variant="secondary" href="/settings?section=workspace#media">
                Media settings
              </ButtonLink>
            )}
            <span className="flex-1" />
            <span className="rounded-full bg-pill-blocked-bg px-2 py-0.5 text-11 text-pill-blocked-fg">Not saved</span>
          </div>
        </div>
      </div>
    );
  }

  const stage = AUDIO_STAGES.find((s) => s.id === a.stage) ?? AUDIO_STAGES[0];
  const stopped = a.failure_kind === "stopped";
  return (
    <div className="p-3">
      <div className="rounded-lg border border-state-blocked/35 bg-pill-blocked-bg px-3 py-2.5" role="alert">
        <b className="text-13 text-pill-blocked-fg">{stopped ? "Stopped" : stage.failed}</b>
        <p className="mb-2 mt-1 text-13 text-fg-2">{a.error}</p>
        {log && a.error_log && (
          <pre className="mb-2 max-h-48 overflow-auto rounded-md border border-border-subtle bg-surface-sunken px-2.5 py-2 font-mono text-11 leading-[1.5] text-fg-secondary" data-testid="audio-log">{a.error_log}</pre>
        )}
        <div className="flex flex-wrap items-center gap-2">
          {actions && messageId && (
            <Button variant="secondary" disabled={actions.disabled} onClick={() => actions.ask(messageId, audioRetryRequest(a))}>{stage.retry}</Button>
          )}
          {a.error_log && <Button variant="secondary" onClick={() => setLog((x) => !x)}>{log ? "Hide log" : "Show log"}</Button>}
          <span className="flex-1" />
          <span className="rounded-full bg-pill-blocked-bg px-2 py-0.5 text-11 text-pill-blocked-fg">Not saved</span>
        </div>
      </div>
    </div>
  );
}
