"use client";

import Link from "next/link";
import { useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { spaceHex } from "@/lib/spaces";
import { SourcesDialog } from "./sources-dialog";

type SpaceRef = Schemas["ChatSpaceRef"];

const chip = "inline-flex h-[26px] flex-none items-center rounded-full border px-[12px] text-12";

/** What the space gives this chat: its instructions, sources and memory (mockup 2). Which space it is, and moving it, is the header's "In" control. */
/** `dense`: a narrow dock, where the chips sit tight under its header instead of centred over a page. */
export function SpaceContextChips({ space, dense }: { space: SpaceRef; dense?: boolean }) {
  const [sources, setSources] = useState(false);
  const hex = spaceHex(space.color);
  return (
    <div className={dense ? "px-3 pt-2" : "px-6 pt-[16px]"}>
      <div aria-label={`From ${space.name}`} role="group" className="mx-auto flex max-w-[860px] flex-wrap items-center gap-[8px]">
        {space.has_instructions && (
          <Link
            href={`/spaces/${space.id}`}
            className={chip}
            title={`${space.name}’s instructions apply to this chat`}
            style={{
              background: `color-mix(in srgb, ${hex} 12%, transparent)`,
              borderColor: `color-mix(in srgb, ${hex} 40%, transparent)`,
              color: `color-mix(in srgb, ${hex} 55%, var(--text))`,
            }}
          >
            {space.name} instructions
          </Link>
        )}
        {space.source_count > 0 && (
          <button type="button" className={`${chip} border-border-strong bg-surface-raised text-fg-secondary hover:bg-hover`} onClick={() => setSources(true)}>
            {space.source_count} {space.source_count === 1 ? "source" : "sources"}
          </button>
        )}
        {space.space_memory && (
          <Link href={`/settings?section=spaces&space=${space.id}`} className={`${chip} border-border-strong bg-surface-raised text-fg-secondary hover:bg-hover`} title={`What’s learned here stays in ${space.name}`}>
            Space memory
          </Link>
        )}
      </div>
      <SourcesDialog spaceId={space.id} spaceName={space.name} open={sources} onOpenChange={setSources} />
    </div>
  );
}
