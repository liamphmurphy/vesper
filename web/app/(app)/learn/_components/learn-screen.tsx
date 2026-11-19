"use client";

import Link from "next/link";
import { useCourses, type CourseSummary } from "@/lib/api/learning-hooks";
import { BUILD_STEPS, COURSE_STATE_LABELS, buildStepIndex, type BuildState } from "@/lib/learning";
import { cx } from "@/lib/cx";
import { Content, TopBar } from "@/components/shell/topbar";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { useState } from "react";
import { NewModuleGuide } from "./new-module-guide";
import { PageHeader } from "@/components/ui/page-header";

function StatePill({ state }: { state: BuildState }) {
  const human = state === "outline_ready";
  const blocked = state === "failed";
  return (
    <span className={cx("inline-block rounded px-1.5 py-0.5 text-11 font-medium", human ? "bg-pill-human-bg text-pill-human-fg" : blocked ? "bg-pill-blocked-bg text-pill-blocked-fg" : "bg-selected text-fg-2")}>
      {COURSE_STATE_LABELS[state]}
    </span>
  );
}

function ProgressBar({ value, total }: { value: number; total: number }) {
  return (
    <div className="h-1 w-full overflow-hidden rounded-full bg-track" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={value}>
      <div className="h-full rounded-full bg-fg-2" style={{ width: `${total ? (value / total) * 100 : 0}%` }} />
    </div>
  );
}

function BuildCard({ c }: { c: CourseSummary }) {
  const step = buildStepIndex(c.state);
  return (
    <Link href={`/learn/${c.id}`} className="flex flex-col gap-2 rounded-lg border border-border bg-surface p-4 hover:border-border-hover">
      <span className="truncate text-14 font-semibold text-fg">{c.topic}</span>
      <span><StatePill state={c.state} /></span>
      <span className="truncate font-mono text-12 text-fg-tertiary">
        {c.state === "failed" ? c.error : c.build_note || (c.state === "outline_ready" ? `${c.units} units · ${c.lessons} lessons` : " ")}
      </span>
      {step >= 0 && (
        <span className="flex gap-1" aria-hidden>
          {BUILD_STEPS.map((s, i) => <span key={s.state} className={cx("h-1 flex-1 rounded-full", i < step ? "bg-fg-2" : "bg-track")} />)}
        </span>
      )}
    </Link>
  );
}

function ModuleCard({ c }: { c: CourseSummary }) {
  return (
    <Link href={`/learn/${c.id}`} className="flex flex-col gap-2 rounded-lg border border-border bg-surface p-4 hover:border-border-hover">
      <span className="truncate text-14 font-semibold text-fg">{c.topic}</span>
      <span className="font-mono text-12 text-fg-tertiary">{c.parts > 1 && `Part ${c.state === "ready" ? c.part + 1 : c.part} of ${c.parts} · `}{c.complete} of {c.lessons} complete · {c.solid} solid</span>
      <ProgressBar value={c.complete} total={c.lessons} />
      <span className="flex items-center justify-between gap-2 text-13">
        <span className={cx("truncate font-medium", c.next_lesson ? "text-accent" : "text-fg-secondary")}>{c.next_lesson ? `Continue: ${c.next_lesson}` : c.parts > c.part + 1 || c.state !== "ready" ? "Built parts done" : "Finished"}</span>
        {c.state !== "ready" && <StatePill state={c.state} />}
        {c.flagged > 0 && <span className="flex-none text-12 text-pill-human-fg">{c.flagged} flagged</span>}
      </span>
    </Link>
  );
}

const GRID = "grid gap-4 [grid-template-columns:repeat(auto-fill,minmax(300px,1fr))]";

export function LearnScreen() {
  const courses = useCourses();
  const all = courses.data ?? [];
  // A module built in parts stays with the person's modules while its next part is built.
  const building = all.filter((c) => !c.studyable);
  const ready = all.filter((c) => c.studyable);
  const [guideOpen, setGuideOpen] = useState(false);
  return (
    <>
      <TopBar
        crumbs={[{ label: "Learn" }]}
        nativeActions={[{ id: "learn.new", label: "New Learning Module", kind: "button", icon: "plus", showsLabel: true, accent: true, run: () => setGuideOpen(true) }]}
      />
      <NewModuleGuide open={guideOpen} onOpenChange={setGuideOpen} hideTrigger />
      <Content>
        <div className="flex flex-col gap-6">
          <PageHeader title="Learn" description="Turn a topic into a sourced, properly ordered module, then work through it with a tutor." />
          {courses.error && <Banner tone="blocked" title={courses.error.message} />}
          {courses.isPending ? (
            <Skeleton className="h-28 w-full rounded-lg" />
          ) : all.length === 0 ? (
            <EmptyState icon="learn" title="No modules yet">Start a New Learning Module and you&apos;ll get an outline to review.</EmptyState>
          ) : (
            <>
              {building.length > 0 && (
                <section className="flex flex-col gap-3">
                  <h2 className="type-heading">In progress</h2>
                  <div className={GRID}>{building.map((c) => <BuildCard key={c.id} c={c} />)}</div>
                </section>
              )}
              {ready.length > 0 && (
                <section className="flex flex-col gap-3">
                  <h2 className="type-heading">Your modules</h2>
                  <div className={GRID}>{ready.map((c) => <ModuleCard key={c.id} c={c} />)}</div>
                </section>
              )}
            </>
          )}
        </div>
      </Content>
    </>
  );
}
