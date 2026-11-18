"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useCourse, useDeleteCourse, useStopCourse } from "@/lib/api/learning-hooks";
import { COURSE_STATE_LABELS, courseBuilding, type BuildState } from "@/lib/learning";
import type { NativeAction } from "@/lib/native-shell/actions";
import { Content, TopBar } from "@/components/shell/topbar";
import { Button } from "@/components/ui/button";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { BuildStepper, OutlineReview } from "./outline-review";
import { StudyView } from "./study-view";
import { confirmAction } from "@/components/ui/confirm";

export function CourseScreen({ id }: { id: string }) {
  const router = useRouter();
  const search = useSearchParams();
  const course = useCourse(id);
  const stop = useStopCourse(id);
  const del = useDeleteCourse();
  const discard = async () => {
    if (await confirmAction({ title: "Delete this module?", body: "Its progress and its tutor conversation are deleted too.", confirmLabel: "Delete module" })) del.mutate(id, { onSuccess: () => router.push("/learn") });
  };
  const c = course.data;
  const state = c?.summary.state as BuildState | undefined;
  // A later part's outline is reviewed here; otherwise what's built is studied.
  const laterPart = !!c && c.summary.part > 0;
  const actions = c && (laterPart ? (
    <>
      <Link href={`/learn/${id}`} className="inline-flex h-7 items-center rounded-md px-2.5 text-12 text-fg-secondary hover:bg-hover">Back to studying</Link>
      <Button variant="outline" disabled={stop.isPending} onClick={() => stop.mutate(undefined, { onSuccess: () => router.push(`/learn/${id}`) })}>Discard this part</Button>
    </>
  ) : (
    <>
      {courseBuilding(c.summary.state) && <Button disabled={stop.isPending} onClick={() => stop.mutate()}>Stop</Button>}
      <Button variant="outline" disabled={del.isPending} onClick={discard}>Delete</Button>
    </>
  ));
  const nativeActions: NativeAction[] | undefined = c && (laterPart
    ? [
        { id: "course.back", label: "Back to studying", kind: "button", showsLabel: true, run: () => router.push(`/learn/${id}`) },
        { id: "course.discard", label: "Discard this part", kind: "button", showsLabel: true, disabled: stop.isPending, run: () => stop.mutate(undefined, { onSuccess: () => router.push(`/learn/${id}`) }) },
      ]
    : [
        ...(courseBuilding(c.summary.state) ? [{ id: "course.stop", label: "Stop", kind: "button" as const, icon: "pause", showsLabel: true, disabled: stop.isPending, run: () => stop.mutate() }] : []),
        { id: "course.delete", label: "Delete", kind: "button" as const, icon: "trash", showsLabel: true, disabled: del.isPending, run: discard },
      ]);
  const crumbs = [{ label: "Learn", href: "/learn" }, { label: c?.summary.topic ?? "Module" }];
  if (c && c.summary.studyable && !(search.get("review") === "1" && state === "outline_ready")) return <StudyView course={c} onDelete={discard} />;
  return (
    <>
      <TopBar crumbs={crumbs} actions={actions} nativeActions={nativeActions} />
      <Content>
        <div className="flex flex-col gap-5">
          {course.error && <Banner tone="blocked" title={course.error.message} />}
          {(stop.error || del.error) && <Banner tone="blocked" title={(stop.error ?? del.error)?.message} />}
          {course.isPending && <Skeleton className="h-64 w-full rounded-lg" />}
          {c && state && (
            <>
              <BuildStepper state={state} />
              {state === "failed" && <Banner tone="blocked" title="This module couldn't be built">{c.summary.error}</Banner>}
              {state === "stopped" && <Banner tone="blocked" title="This module was stopped">Delete it, or start a new one from Learn.</Banner>}
              {state === "outline_ready" ? (
                <OutlineReview course={c} />
              ) : (
                <div className="space-y-1">
                  <h1 className="type-title">{c.summary.topic}</h1>
                  {courseBuilding(state) && (
                    <p className="text-14 text-fg-secondary">
                      {COURSE_STATE_LABELS[state]}{c.summary.build_note ? ` · ${c.summary.build_note}` : ""}. This takes a while; you can leave and come back.
                    </p>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      </Content>
    </>
  );
}
