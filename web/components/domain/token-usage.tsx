import { compact } from "@/lib/format";
import { tokenBreakdown, type TokenUsage as Usage } from "@/lib/token-usage";

export function TokenUsage({ usage, compact: stacked }: { usage: Usage; compact?: boolean }) {
  const tokens = tokenBreakdown(usage);
  if (stacked) {
    return (
      <div aria-label="Token breakdown" className="flex flex-col gap-1 text-12 text-fg-secondary">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-fg-tertiary">Input</span>
          <strong className="font-mono font-medium text-fg">{compact(tokens.input)}</strong>
        </div>
        {tokens.hasBreakdown && (
          <>
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-fg-tertiary">Cached input</span>
              <strong className="font-mono font-medium text-fg">{compact(tokens.cached)}</strong>
            </div>
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-fg-tertiary">Uncached input</span>
              <strong className="font-mono font-medium text-fg">{compact(tokens.uncached)}</strong>
            </div>
          </>
        )}
        {tokens.unknown > 0 && (
          <p className="text-11 text-fg-tertiary">
            Cache breakdown unavailable for <strong className="font-mono font-medium text-fg-secondary">{compact(tokens.unknown)}</strong> input
          </p>
        )}
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-fg-tertiary">Output</span>
          <strong className="font-mono font-medium text-fg">{compact(tokens.output)}</strong>
        </div>
        <p className="pt-0.5 text-11 text-fg-tertiary">Total includes cached input.</p>
      </div>
    );
  }
  return <div aria-label="Token breakdown" className="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-border-subtle px-6 py-2 text-12 text-fg-secondary">
    <span>Input <strong className="font-mono font-medium text-fg">{compact(tokens.input)}</strong></span>
    {tokens.hasBreakdown && <>
      <span>Cached input <strong className="font-mono font-medium text-fg">{compact(tokens.cached)}</strong></span>
      <span>Uncached input <strong className="font-mono font-medium text-fg">{compact(tokens.uncached)}</strong></span>
    </>}
    {tokens.unknown > 0 && <span>Cache breakdown unavailable for <strong className="font-mono font-medium">{compact(tokens.unknown)}</strong> input</span>}
    <span>Output <strong className="font-mono font-medium text-fg">{compact(tokens.output)}</strong></span>
    <span className="text-fg-tertiary">Total includes cached input.</span>
  </div>;
}
