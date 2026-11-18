"use client";

import { Dialog } from "radix-ui";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { useBootstrap, useChatModels } from "@/lib/api/hooks";
import { useCreateCourse } from "@/lib/api/learning-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { currentProject } from "@/lib/project-scope";
import { PART_MINUTES, TIME_STEPS, partsEstimate, timeDetail, timeLabel } from "@/lib/learning";
import { cx } from "@/lib/cx";
import { useRememberedProject } from "@/components/shell/project-scope";
import { Button, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { ModelPicker, type Selection } from "@/app/(app)/chat/_components/model-picker";
import { hoverReveal } from "@/lib/reveal";

const LEVELS = [
  { value: "new", label: "New", detail: "I'm starting from scratch." },
  { value: "some", label: "Some background", detail: "I've met the basics and want to go further." },
  { value: "experienced", label: "Experienced", detail: "I know this area and want the depth." },
] as const;
const STEPS = ["Topic", "Purpose", "Level", "Time", "Review"] as const;
const LAST = STEPS.length - 1;

type Level = (typeof LEVELS)[number]["value"];

/** How long the module should take, from half an hour to 20 hours. */
function TimeSlider({ minutes, onChange }: { minutes: number; onChange: (m: number) => void }) {
  const at = Math.max(0, TIME_STEPS.indexOf(minutes));
  const partsFrom = TIME_STEPS.indexOf(PART_MINUTES) / (TIME_STEPS.length - 1);
  return (
    <div className="guide-stagger flex flex-col gap-3">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-22 font-semibold text-fg" aria-live="polite">{timeLabel(minutes)}</span>
        {minutes > PART_MINUTES && <span className="rounded-full bg-accent-soft px-2 py-0.5 text-12 font-semibold text-accent">In {partsEstimate(minutes)} parts</span>}
      </div>
      <input
        type="range"
        aria-label="Time"
        aria-valuetext={timeLabel(minutes)}
        data-step-focus
        min={0}
        max={TIME_STEPS.length - 1}
        value={at}
        onChange={(e) => onChange(TIME_STEPS[Number(e.target.value)])}
        className="w-full cursor-pointer accent-[var(--accent)]"
      />
      <div className="relative h-4 text-11 text-fg-tertiary" aria-hidden>
        <span className="absolute left-0">30 min</span>
        <span className="absolute -translate-x-1/2" style={{ left: `${partsFrom * 100}%` }}>8h · parts beyond</span>
        <span className="absolute right-0">20h</span>
      </div>
      <p className="text-12 text-fg-secondary">{timeDetail(minutes)}</p>
    </div>
  );
}

/** A step's question. Text steps pass htmlFor so it labels their input. */
function Question({ htmlFor, focus, children }: { htmlFor?: string; focus?: boolean; children: ReactNode }) {
  const Tag = htmlFor ? "label" : "h3";
  return (
    <Tag htmlFor={htmlFor} tabIndex={focus ? -1 : undefined} data-step-focus={focus || undefined} className="type-title block text-fg outline-none">
      {children}
    </Tag>
  );
}

function Options<T extends string>({ name, label, options, value, onChange }: {
  name: string;
  label: string;
  options: ReadonlyArray<{ value: T; label: string; detail: string }>;
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <div role="radiogroup" aria-label={label} className="guide-stagger flex flex-col gap-2">
      {options.map((o) => {
        const on = o.value === value;
        return (
          <label key={o.value} className={cx(
            "flex cursor-pointer items-center gap-3 rounded-lg border px-3.5 py-2.5 transition-colors has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-1 has-[:focus-visible]:outline-accent",
            on ? "border-accent bg-selected" : "border-border-strong hover:border-border-hover hover:bg-hover",
          )}>
            <input type="radio" className="sr-only" name={name} checked={on} data-step-focus={on || undefined} onChange={() => onChange(o.value)} />
            <span className="min-w-0 flex-1">
              <span className="block text-14 font-medium text-fg">{o.label}</span>
              <span className="block text-12 text-fg-secondary">{o.detail}</span>
            </span>
            <span className={cx("grid size-[18px] flex-none place-items-center rounded-full border transition-colors", on ? "border-accent bg-accent text-on-accent" : "border-border-strong")}>
              {on && <Icon name="check" size={12} strokeWidth={2.2} className="motion-pop" />}
            </span>
          </label>
        );
      })}
    </div>
  );
}

function ReviewRow({ label, onEdit, children }: { label: string; onEdit: () => void; children: ReactNode }) {
  return (
    <button type="button" aria-label={`Edit ${label.toLowerCase()}`} onClick={onEdit} className="group flex w-full items-baseline gap-3 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-hover">
      <span className="w-16 flex-none text-12 text-fg-tertiary">{label}</span>
      <span className="min-w-0 flex-1 truncate text-13 text-fg">{children}</span>
      <span className={cx("flex-none text-12 text-accent transition-opacity group-focus-visible:opacity-100", hoverReveal())}>Edit</span>
    </button>
  );
}

function focusStep(layer?: HTMLElement) {
  layer?.querySelector<HTMLElement>("[data-step-focus]")?.focus({ preventScroll: true });
}

/** The New Learning Module button and the guided steps it opens. */
export function NewModuleGuide({ open: openProp, onOpenChange, hideTrigger }: { open?: boolean; onOpenChange?: (open: boolean) => void; hideTrigger?: boolean } = {}) {
  const router = useRouter();
  const search = useSearchParams();
  const boot = useBootstrap();
  const remembered = useRememberedProject();
  const personas = usePersonas();
  const models = useChatModels();
  const create = useCreateCourse();
  const [ownOpen, setOwnOpen] = useState(false);
  // The page may hold the open state (the Mac app opens it from the window's toolbar).
  const open = openProp ?? ownOpen;
  const setOpen = onOpenChange ?? setOwnOpen;
  const [step, setStep] = useState(0);
  const [leaving, setLeaving] = useState<number | null>(null);
  const [direction, setDirection] = useState<"forward" | "back">("forward");
  const [topic, setTopic] = useState("");
  const [goal, setGoal] = useState("");
  const [level, setLevel] = useState<Level>("some");
  const [time, setTime] = useState(180);
  const [tutor, setTutor] = useState("");
  const [picked, setPicked] = useState<Selection | null>(null);
  const layers = useRef(new Map<number, HTMLDivElement>());
  const projects = boot.data?.projects ?? [];
  // A module belongs to a project only for its model and permissions, so any open one will do.
  const project = currentProject("/learn", search, remembered, projects) ?? projects.find((p) => !p.archived);
  const groups = models.data;
  const fallback = groups?.flatMap((g) => g.models.filter((m) => m.default).map((m) => ({ harness: g.harness, model: m.id })))[0];
  const selection = picked ?? fallback;
  const list = personas.data?.personas ?? [];
  const blocked = !topic.trim() || (step === LAST && (!project || create.isPending));

  useEffect(() => focusStep(layers.current.get(step)), [step]);

  const go = (to: number) => {
    if (to === step) return;
    setDirection(to > step ? "forward" : "back");
    setLeaving(step);
    setStep(to);
  };
  const submit = () => {
    if (blocked || !project) return;
    if (step < LAST) return go(step + 1);
    create.mutate(
      { project: project.key, topic: topic.trim(), goal: goal.trim() || undefined, level, minutes_budget: time, persona_id: tutor || undefined, harness: selection?.harness, model: selection?.model },
      { onSuccess: (c) => router.push(`/learn/${c.summary.id}`) },
    );
  };
  // Starting a run costs money, so a held Enter or a double click must not fall through to the last step's submit.
  const onFormKey = (e: KeyboardEvent) => {
    if (e.key === "Enter" && e.repeat) e.preventDefault();
  };
  const onGoalKey = (e: KeyboardEvent) => {
    if (e.key !== "Enter" || e.shiftKey || e.nativeEvent.isComposing) return;
    e.preventDefault();
    if (!e.repeat) submit();
  };

  const body = (s: number) => {
    switch (s) {
      case 0:
        return (
          <div className="guide-stagger flex flex-col gap-3">
            <Question htmlFor="learn-topic">What do you want to learn?</Question>
            <TextInput id="learn-topic" data-step-focus maxLength={200} placeholder="How Postgres MVCC and vacuum actually work" value={topic} onChange={(e) => setTopic(e.target.value)} />
            <p className="text-12 text-fg-tertiary">Be as specific as you like. A narrow topic makes a better module.</p>
          </div>
        );
      case 1:
        return (
          <div className="guide-stagger flex flex-col gap-3">
            <Question htmlFor="learn-goal">What&apos;s it for?</Question>
            <TextArea id="learn-goal" data-step-focus rows={4} maxLength={1000} placeholder="I debug slow queries at work and want to understand table bloat" value={goal} onChange={(e) => setGoal(e.target.value)} onKeyDown={onGoalKey} />
            <p className="text-12 text-fg-tertiary">This shapes what gets taught. Skip it if you&apos;re just curious.</p>
          </div>
        );
      case 2:
        return (
          <div className="flex flex-col gap-3">
            <div className="guide-stagger"><Question>How much do you already know?</Question></div>
            <Options name="learn-level" label="Your level" options={LEVELS} value={level} onChange={setLevel} />
          </div>
        );
      case 3:
        return (
          <div className="flex flex-col gap-3">
            <div className="guide-stagger"><Question>How much time do you have?</Question></div>
            <TimeSlider minutes={time} onChange={setTime} />
          </div>
        );
      default:
        return (
          <div className="guide-stagger flex flex-col gap-3">
            <Question focus>Here&apos;s your module</Question>
            <div className="-mx-2 flex flex-col">
              <ReviewRow label="Topic" onEdit={() => go(0)}>{topic.trim()}</ReviewRow>
              <ReviewRow label="Purpose" onEdit={() => go(1)}>{goal.trim() || <span className="text-fg-tertiary">Not set</span>}</ReviewRow>
              <ReviewRow label="Level" onEdit={() => go(2)}>{LEVELS.find((l) => l.value === level)?.label}</ReviewRow>
              <ReviewRow label="Time" onEdit={() => go(3)}>{timeLabel(time)}{time > PART_MINUTES && `, in about ${partsEstimate(time)} parts`}</ReviewRow>
            </div>
            <div className="flex flex-wrap items-end gap-x-6 gap-y-3">
              <Field label="Tutor" htmlFor="learn-tutor">
                <select id="learn-tutor" value={tutor} onChange={(e) => setTutor(e.target.value)} className="h-[30px] rounded-md border border-border-strong bg-btn-outline px-2 text-13 text-fg-2">
                  <option value="">Default persona</option>
                  {list.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </Field>
              {selection && <Field label="Model"><ModelPicker groups={groups} value={selection} onChange={setPicked} /></Field>}
            </div>
            {create.error && <Banner tone="blocked" title={create.error.message} />}
          </div>
        );
    }
  };

  return (
    <Dialog.Root open={open} onOpenChange={(o) => { setOpen(o); setLeaving(null); }}>
      {!hideTrigger && (
        <Dialog.Trigger asChild>
          <Button variant="primary" icon="plus">New Learning Module</Button>
        </Dialog.Trigger>
      )}
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          onOpenAutoFocus={(e) => { e.preventDefault(); focusStep(layers.current.get(step)); }}
          className="motion-dialog fixed left-1/2 top-[10vh] z-50 flex max-h-[84vh] w-[min(640px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-center gap-2 px-[18px] pt-3.5">
            <Dialog.Title className="type-heading">New Learning Module</Dialog.Title>
            <span className="font-mono text-12 text-fg-tertiary">{step + 1} of {STEPS.length}</span>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close" className="ml-auto" />
            </Dialog.Close>
          </div>
          <div className="flex gap-1 px-[18px] pt-3" aria-hidden>
            {STEPS.map((s, i) => (
              <span key={s} className="h-1 flex-1 overflow-hidden rounded-full bg-track">
                <span className={cx("block h-full origin-left rounded-full bg-accent transition-transform duration-(--motion-slow) ease-out motion-reduce:transition-none", i <= step ? "scale-x-100" : "scale-x-0")} />
              </span>
            ))}
          </div>
          <form className="flex min-h-0 flex-col" onKeyDown={onFormKey} onSubmit={(e) => { e.preventDefault(); submit(); }}>
            <div className="guide-stage relative h-[340px] min-h-0 shrink overflow-clip" data-direction={direction}>
              {(leaving === null ? [step] : [leaving, step]).map((s) => (
                <div
                  key={s}
                  ref={(el) => {
                    if (el) layers.current.set(s, el);
                    else layers.current.delete(s);
                  }}
                  inert={s !== step}
                  className={cx("absolute inset-0 overflow-y-auto px-[18px] pb-4 pt-6", s === step ? "guide-step-enter" : "guide-step-leave")}
                  onAnimationEnd={(e) => {
                    if (e.target === e.currentTarget && s === leaving) setLeaving(null);
                  }}
                >
                  {body(s)}
                </div>
              ))}
            </div>
            <div className="flex flex-wrap items-center gap-3 border-t border-track bg-surface-sunken px-[18px] py-3">
              <span className="min-w-0 flex-1 text-12 text-fg-tertiary">{step === LAST ? "Drafting takes one short run. You approve the outline before any research starts." : null}</span>
              {step > 0 && <Button variant="ghost" onClick={() => go(step - 1)}>Back</Button>}
              <Button variant="primary" type="submit" disabled={blocked} onClick={(e) => { if (e.detail > 1) e.preventDefault(); }}>
                {step === LAST ? (create.isPending ? "Starting…" : "Draft outline") : step === 1 && !goal.trim() ? "Skip" : "Continue"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
