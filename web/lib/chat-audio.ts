import type { components } from "./api/schema";

export type ChatAudio = components["schemas"]["ChatAudio"];
export type AudioStage = components["schemas"]["ChatAudioStage"];

export interface AudioStageDef {
  id: AudioStage;
  label: string;
  failed: string;
  retry: string;
}

/** The pipeline code-rendered audio shows, in order. */
export const AUDIO_STAGES: AudioStageDef[] = [
  { id: "compose", label: "Compose", failed: "Composing failed", retry: "Retry composing" },
  { id: "render", label: "Render", failed: "Rendering failed", retry: "Retry render" },
  { id: "check", label: "Mix check", failed: "Checking the mix failed", retry: "Retry mix check" },
  { id: "save", label: "Save to Library", failed: "Saving failed", retry: "Retry save" },
];

/** The pipeline AI music generation shows, in order. */
export const MUSIC_STAGES: AudioStageDef[] = [
  { id: "compose", label: "Queued", failed: "Couldn’t start generation", retry: "Retry" },
  { id: "render", label: "Generating", failed: "Music generation failed", retry: "Retry" },
  { id: "save", label: "Save to Library", failed: "Saving failed", retry: "Retry" },
];

export type AudioStageState = "done" | "active" | "failed" | "pending";

export function isMusicAudio(a: Pick<ChatAudio, "source_kind">): boolean {
  return a.source_kind === "music";
}

export function stagesForAudio(a: Pick<ChatAudio, "source_kind">): AudioStageDef[] {
  return isMusicAudio(a) ? MUSIC_STAGES : AUDIO_STAGES;
}

/** Each stage's state: done before the job's stage, its stage active (or failed), the rest pending. A finished file is done throughout. */
export function audioStageStates(a: Pick<ChatAudio, "stage" | "state" | "source_kind">): AudioStageState[] {
  const stages = stagesForAudio(a);
  const at = stages.findIndex((s) => s.id === a.stage);
  return stages.map((_, i) => {
    if (a.state === "done" || i < at) return "done";
    if (i > at) return "pending";
    return a.state === "failed" ? "failed" : "active";
  });
}

export interface PlacedStandaloneAudio<T extends ChatAudio = ChatAudio> {
  leading: T[];
  afterMessage: Map<string, T[]>;
  trailing: T[];
  total: number;
}

/**
 * Places chat audio that isn't attached to a reply message or the active live turn
 * chronologically among messages so standalone music generations appear where created.
 */
export function placeStandaloneAudio<T extends ChatAudio>(
  audio: readonly T[],
  messages: readonly { id: string; created_at: string }[],
  opts: { running: boolean; currentRunId?: string | null },
): PlacedStandaloneAudio<T> {
  const leading: T[] = [];
  const afterMessage = new Map<string, T[]>();
  const trailing: T[] = [];
  let total = 0;

  for (const a of audio) {
    if (a.message_id) continue;
    const isLiveTurnAudio = opts.running && !!a.run_id && a.run_id === opts.currentRunId;
    if (isLiveTurnAudio) continue;

    total++;
    const at = Date.parse(a.created_at);
    const idx = Number.isNaN(at) ? -1 : messages.findIndex((m) => Date.parse(m.created_at) >= at);
    if (idx === -1) {
      trailing.push(a);
    } else if (idx === 0) {
      leading.push(a);
    } else {
      const key = messages[idx - 1].id;
      const list = afterMessage.get(key);
      if (list) list.push(a);
      else afterMessage.set(key, [a]);
    }
  }

  return { leading, afterMessage, trailing, total };
}

export interface MusicErrorCopy {
  title: string;
  body: string;
  actionLabel: string;
  showSettingsLink: boolean;
}

export function musicErrorCopy(a: Pick<ChatAudio, "error" | "error_kind" | "failure_kind">): MusicErrorCopy {
  if (a.failure_kind === "stopped") {
    return {
      title: "Stopped",
      body: a.error || "Music generation was stopped.",
      actionLabel: "Retry",
      showSettingsLink: false,
    };
  }
  switch (a.error_kind) {
    case "auth":
      return {
        title: "API key rejected",
        body: a.error || "The active media provider rejected your credentials.",
        actionLabel: "Retry",
        showSettingsLink: true,
      };
    case "quota":
      return {
        title: "Quota or spending limit reached",
        body: a.error || "Your monthly credit or API quota limit was reached.",
        actionLabel: "Retry",
        showSettingsLink: true,
      };
    case "rate_limit":
      return {
        title: "Rate limited",
        body: a.error || "Too many requests right now. Try again in a moment.",
        actionLabel: "Retry",
        showSettingsLink: false,
      };
    case "filtered":
      return {
        title: "Blocked by safety filter",
        body: a.error || "The prompt or lyrics were rejected by the provider’s safety filter.",
        actionLabel: "Edit prompt",
        showSettingsLink: false,
      };
    case "unavailable":
      return {
        title: "Music provider not ready",
        body: a.error || "Configure a music provider in Settings → Workspace → Media providers.",
        actionLabel: "Retry",
        showSettingsLink: true,
      };
    default:
      return {
        title: "Music generation failed",
        body: a.error || "Could not generate music.",
        actionLabel: "Retry",
        showSettingsLink: false,
      };
  }
}

/** What Retry asks the persona to do for failed audio. */
export function audioRetryRequest(a: Pick<ChatAudio, "title" | "stage">): string {
  const step = AUDIO_STAGES.find((s) => s.id === a.stage)?.label.toLowerCase() ?? a.stage;
  return `Retry the audio "${a.title}" from the ${step} step.`;
}

/** The bars a waveform draws: the server's peaks, or a flat line for a format it can't decode. */
export const WAVE_BARS = 64;
export function waveBars(peaks: readonly number[] | undefined, count = WAVE_BARS): number[] {
  if (!peaks?.length) return Array.from({ length: count }, () => 0.08);
  return Array.from({ length: count }, (_, i) => {
    // Resample: the server sends 64 buckets, a small tile draws fewer.
    const from = Math.floor((i * peaks.length) / count);
    const to = Math.max(from + 1, Math.floor(((i + 1) * peaks.length) / count));
    let top = 0;
    for (let j = from; j < to; j++) top = Math.max(top, peaks[j]);
    return Math.max(0.08, top / 255);
  });
}

/** 1 for 1×, "1.5×" for the speed button. */
export function speedLabel(rate: number): string {
  return `${rate}×`;
}

export const SPEEDS = [0.75, 1, 1.25, 1.5, 2] as const;

/** The next speed after rate, wrapping around. */
export function nextSpeed(rate: number): number {
  const i = SPEEDS.findIndex((s) => s === rate);
  return SPEEDS[(i + 1) % SPEEDS.length];
}

/** A play position moved by seconds, kept inside the clip. */
export function skip(at: number, by: number, length: number): number {
  return Math.min(Math.max(0, at + by), Math.max(0, length));
}

/** "WAV · 44.1 kHz" style labels aren't known without decoding; the type names the format. */
export function audioFormat(contentType: string, filename: string): string {
  const ext = filename.split(".").pop()?.toUpperCase();
  if (ext && ext.length <= 4) return ext;
  return contentType.replace(/^audio\//, "").toUpperCase();
}
