"use client";

import { useRouter } from "next/navigation";
import { Suspense, use } from "react";
import { useDelegatedRunLogs, useRunLog } from "@/lib/api/hooks";
import { isNativeShell, post } from "@/lib/native-shell/bridge";
import { PROTOCOL_VERSION } from "@/lib/native-shell/protocol";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { WORK_COLUMN } from "@/components/domain/work-detail-header";
import { RunGraphView } from "./run-graph-view";

function GraphSlot({ params }: { params: PageProps<"/runs/[id]">["params"] }) {
  const { id } = use(params);
  const router = useRouter();
  const { data: d, isError, error } = useRunLog(id);
  const children = useDelegatedRunLogs(d?.child_runs ?? []);

  if (isError) {
    return (
      <div className="p-6">
        <Banner tone="blocked" title="Couldn't load this run">
          {error.message}
        </Banner>
      </div>
    );
  }
  if (!d) {
    return (
      <div aria-busy="true" className={`${WORK_COLUMN} flex flex-col gap-3 py-8`}>
        <Skeleton className="h-6 w-2/3" />
        <Skeleton className="h-40 w-full rounded-xl" />
      </div>
    );
  }

  const openAnchor = (hash: string) => {
    const path = `/runs/${encodeURIComponent(id)}?view=details&anchor=${encodeURIComponent(hash)}#${hash}`;
    if (isNativeShell()) {
      post({ v: PROTOCOL_VERSION, type: "openInMain", path });
    } else {
      router.push(path);
    }
  };

  return (
    <RunGraphView
      d={d}
      childDetails={children.map((c) => c.data)}
      onOpenTurn={(n) => openAnchor(`turn-${n}`)}
      onOpenEvent={(seq) => openAnchor(`event-${seq}`)}
    />
  );
}

export default function RunPage({ params }: PageProps<"/runs/[id]">) {
  return (
    <Suspense>
      <GraphSlot params={params} />
    </Suspense>
  );
}
