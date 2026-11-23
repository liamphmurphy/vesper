// Pure formatting and threshold helpers for the chat context-window meter.
// Kept free of React so `npm run test:unit` covers it.

export const DEFAULT_AUTO_ROLLOVER_TOKENS = 160_000;

export type ContextMeterTone = "neutral" | "warning" | "danger";

export type RolloverPreset = {
  label: string;
  /** null = inherit server default (160k), 0 = disabled, >0 = explicit token threshold */
  value: number | null;
};

export const ROLLOVER_PRESETS: RolloverPreset[] = [
  { label: "Default (160k)", value: null },
  { label: "80k", value: 80_000 },
  { label: "120k", value: 120_000 },
  { label: "160k", value: 160_000 },
  { label: "200k", value: 200_000 },
  { label: "Off", value: 0 },
];

export function formatTokenCount(tokens: number): string {
  if (tokens < 1000) return `${Math.max(0, Math.round(tokens))}`;
  if (tokens < 100_000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, "")}k`;
  return `${Math.round(tokens / 1000)}k`;
}

export function contextMeterState(
  contextTokens: number | undefined,
  effectiveLimit: number | undefined,
): {
  tokens: number;
  limit: number;
  ratio: number;
  tone: ContextMeterTone;
  label: string;
} {
  const tokens = Math.max(0, contextTokens ?? 0);
  const limit = Math.max(0, effectiveLimit ?? 0);
  if (limit <= 0) {
    return {
      tokens,
      limit: 0,
      ratio: 0,
      tone: "neutral",
      label: tokens > 0 ? `${formatTokenCount(tokens)} tok` : "Auto-compact off",
    };
  }
  const ratio = Math.min(1, tokens / limit);
  const tone: ContextMeterTone = ratio >= 0.9 ? "danger" : ratio >= 0.75 ? "warning" : "neutral";
  return {
    tokens,
    limit,
    ratio,
    tone,
    label: `${formatTokenCount(tokens)} / ${formatTokenCount(limit)}`,
  };
}

/** True when a reply is long enough to offer collapse/expand folding in the transcript. */
export function isFoldableReply(bodyMd: string): boolean {
  if (bodyMd.length >= 2400) return true;
  let lines = 1;
  for (let i = 0; i < bodyMd.length; i++) {
    if (bodyMd.charCodeAt(i) === 10) {
      lines++;
      if (lines >= 42) return true;
    }
  }
  return false;
}

/** Builds a compact preview for a collapsed long reply. */
export function collapsedReplyPreview(bodyMd: string, maxLines = 5, maxChars = 420): string {
  const lines = bodyMd.replace(/\r\n/g, "\n").split("\n").filter((l) => l.trim().length > 0);
  const head = lines.slice(0, maxLines).join("\n");
  if (head.length <= maxChars) return head;
  return `${head.slice(0, maxChars - 1).trimEnd()}…`;
}
