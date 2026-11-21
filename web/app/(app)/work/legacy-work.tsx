"use client";

import { useSearchParams } from "next/navigation";
import { redirect } from "next/navigation";
import { workHref, type WorkView } from "@/lib/work-navigation";

/** Keep bookmarks, notifications and links from other apps in the same Work surface. */
export function LegacyWork({
  view,
  run,
  ticket,
  epic,
}: {
  view: WorkView;
  run?: string;
  ticket?: string;
  epic?: string;
}) {
  const params = useSearchParams();
  const next = new URLSearchParams(params);
  if (view === "tickets" && next.has("view"))
    next.set("ticket_view", next.get("view")!);
  const layout = next.get("layout");
  if (next.has("assignee")) {
    next.set("agent", next.get("assignee")!);
    next.delete("assignee");
  }
  if (view === "tickets" && layout !== "epics" && next.has("epic")) {
    next.set("filter_epic", next.get("epic")!);
    next.delete("epic");
  }
  return redirect(
    workHref(next, {
      view: layout === "epics" ? "epics" : view === "activity" ? null : view,
      ...(run ? { run } : {}),
      ...(ticket ? { ticket } : {}),
      ...(epic ? { epic } : {}),
    }),
  );
}
