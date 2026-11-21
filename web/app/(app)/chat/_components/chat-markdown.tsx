"use client";

import { useMemo } from "react";
import { Markdown } from "@/components/domain/markdown";
import { linkCitations } from "@/lib/chat-sources";
import { linkTicketKeys } from "@/lib/ticket-keys";
import { SvgFenceMessage } from "@/components/domain/svg-fence";

/** replyId: the assistant reply this is, so its SVG diagrams can be saved. cites: the citation numbers it defines. */
export function ChatMarkdown({ children, replyId, cites }: { children: string; replyId?: string; cites?: number[] }) {
  const md = useMemo(() => linkCitations(linkTicketKeys(children), cites ?? []), [children, cites]);
  return (
    <SvgFenceMessage.Provider value={replyId}>
      <Markdown codeBlocks>{md}</Markdown>
    </SvgFenceMessage.Provider>
  );
}
