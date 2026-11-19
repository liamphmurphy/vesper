"use client";

import Link from "next/link";
import { useCosts } from "@/lib/api/hooks";
import { spendLabel } from "@/lib/costs";
import { Icon } from "@/components/ui/icon";

/** A header pill with spend; links to the Costs page. */
export function CostChip({ value, title, href = "/reports?tab=costs" }: { value: string; title: string; href?: string }) {
  return (
    <Link
      href={href}
      title={title}
      aria-label={`${title}: ${value}`}
      data-testid="cost-chip"
      className="flex flex-none items-center gap-1 whitespace-nowrap rounded-full border border-border-strong py-0.5 pl-1.5 pr-2.5 font-mono text-12 text-fg-secondary hover:bg-hover hover:text-fg"
    >
      <Icon name="dollar" size={12} className="text-fg-tertiary" />
      {value}
    </Link>
  );
}

/** All-time spend on a chat, every run segment included. */
export function ChatCostChip({ chatId, project }: { chatId: string; project?: string }) {
  const q = useCosts({ chat: chatId });
  if (!q.data || q.data.total.runs === 0) return null;
  return (
    <CostChip
      value={spendLabel(q.data.total.cost_micros, q.data.unpriced_runs)}
      title="Spend on this chat"
      href={project ? `/reports?tab=costs&project=${encodeURIComponent(project)}` : "/reports?tab=costs"}
    />
  );
}
