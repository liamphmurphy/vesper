"use client";

import Link from "next/link";
import { DropdownMenu, Popover } from "radix-ui";
import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import type { Priority, Schemas, TicketStatus } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";
import { AgentAvatar, HumanAvatar, UnassignedAvatar } from "./avatars";
import { PriorityGlyph, StatusGlyph } from "./glyphs";
import { PRIORITY_NAME, PRIORITY_ORDER, STATUS_NAME, STATUS_ORDER } from "./meta";

// Floating UI: raised surface + float border + shadow (DESIGN.md §1).
export const floatPanel =
  "motion-float z-50 rounded-xl border border-border-float bg-surface-raised p-1 text-13 text-fg shadow-[var(--shadow-float)] outline-none";
const item =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

function Check({ on }: { on: boolean }) {
  return <span className="ml-auto w-4 text-accent">{on && <Icon name="check" size={14} strokeWidth={1.8} />}</span>;
}

/**
 * `label` names the trigger for assistive tech: what the picker sets, then its
 * current value ("Status: In progress"). Triggers shouldn't set their own
 * aria-label; the picker's wins only when the child has none.
 */
type MenuProps<T> = { value?: T; onChange: (v: T) => void; children: ReactNode; align?: "start" | "end"; label?: string };

/** "Label: value", "Label: none" for a cleared value, or just "Label" with no value (bulk edits). */
export function pickerName(label: string, value: string | null | undefined) {
  if (value === undefined) return label;
  return `${label}: ${value === null || value === "" ? "none" : value}`;
}

export function StatusMenu({ value, onChange, children, align = "start", label = "Status", statuses = STATUS_ORDER }: MenuProps<TicketStatus> & { statuses?: TicketStatus[] }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={pickerName(label, value && STATUS_NAME[value])}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align={align} sideOffset={6} className={cx(floatPanel, "w-52")}>
          {statuses.map((s) => (
            <DropdownMenu.Item key={s} className={item} onSelect={() => onChange(s)}>
              <StatusGlyph state={s} surface="var(--surface-raised)" label={false} />
              {STATUS_NAME[s]}
              <Check on={s === value} />
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

export function PriorityMenu({ value, onChange, children, align = "start", label = "Priority" }: MenuProps<Priority>) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={pickerName(label, value && PRIORITY_NAME[value])}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align={align} sideOffset={6} className={cx(floatPanel, "w-48")}>
          {PRIORITY_ORDER.map((p) => (
            <DropdownMenu.Item key={p} className={item} onSelect={() => onChange(p)}>
              <PriorityGlyph priority={p} label={false} />
              {PRIORITY_NAME[p]}
              <Check on={p === value} />
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** Choose whether tickets need a person-approved mockup (bulk edits). */
export function MockupRequirementMenu({ onChange, children, align = "start", label = "Mockup requirement" }: Omit<MenuProps<boolean>, "value">) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={label}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align={align} sideOffset={6} className={cx(floatPanel, "w-52")}>
          <DropdownMenu.Item className={item} onSelect={() => onChange(true)}>
            Require mockup
          </DropdownMenu.Item>
          <DropdownMenu.Item className={item} onSelect={() => onChange(false)}>
            Don’t require mockup
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

export function UserMenu({
  users,
  value,
  onChange,
  children,
  label = "Reviewer",
}: MenuProps<string | null> & { users: Schemas["User"][] }) {
  const current = value ? (users.find((u) => u.id === value)?.name ?? null) : value;
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={pickerName(label, current)}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "w-56")}>
          {users.map((u) => (
            <DropdownMenu.Item key={u.id} className={item} onSelect={() => onChange(u.id)}>
              <HumanAvatar name={u.name} initials={u.initials} color={u.avatar_color} src={u.avatar_url} label={false} />
              {u.name}
              <Check on={u.id === value} />
            </DropdownMenu.Item>
          ))}
          <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
          <DropdownMenu.Item className={cx(item, "text-fg-secondary")} onSelect={() => onChange(null)}>
            No reviewer
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

export function EpicMenu({
  epics,
  value,
  onChange,
  children,
  label = "Epic",
}: MenuProps<string | null> & { epics: Schemas["Epic"][] }) {
  const current = value ? (epics.find((e) => e.id === value)?.name ?? null) : value;
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={pickerName(label, current)}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "w-56")}>
          {epics.length === 0 && <div className="px-2 py-1.5 text-fg-tertiary">No epics in this space</div>}
          {epics.map((e) => (
            <DropdownMenu.Item key={e.id} className={item} onSelect={() => onChange(e.id)}>
              <Icon name="epics" size={14} className="text-fg-tertiary" />
              {e.name}
              <Check on={e.id === value} />
            </DropdownMenu.Item>
          ))}
          <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
          <DropdownMenu.Item className={cx(item, "text-fg-secondary")} onSelect={() => onChange(null)}>
            No epic
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

const availability: Record<Schemas["Agent"]["status"], { label: string; cls: string }> = {
  idle: { label: "Available", cls: "text-pill-done-fg" },
  running: { label: "Busy", cls: "text-pill-human-fg" },
  waiting: { label: "Waiting", cls: "text-pill-human-fg" },
  blocked: { label: "Blocked", cls: "text-pill-blocked-fg" },
};

/**
 * Assignee picker popover (DESIGN.md §4): personas that take tickets, with a search row, 40px
 * options with "model · specialty" and availability. Assigning never starts a run (§6.6).
 */
export function AgentPicker({
  agents,
  value,
  onChange,
  children,
  open,
  onOpenChange,
  label = "Persona",
}: {
  agents: Schemas["Agent"][];
  value?: string | null;
  onChange: (agentId: string | null) => void;
  children: ReactNode;
  open?: boolean;
  onOpenChange?: (o: boolean) => void;
  label?: string;
}) {
  const [q, setQ] = useState("");
  const [active, setActive] = useState(0);
  // Uncontrolled unless the caller passes `open`.
  const [ownOpen, setOwnOpen] = useState(false);
  const isOpen = open ?? ownOpen;
  const setOpen = (o: boolean) => {
    setOwnOpen(o);
    onOpenChange?.(o);
    if (!o) {
      setQ("");
      setActive(0);
    }
  };
  const shown = useMemo(() => {
    const s = q.trim().toLowerCase();
    return s ? agents.filter((a) => `${a.name} ${a.handle} ${a.specialty}`.toLowerCase().includes(s)) : agents;
  }, [agents, q]);
  const options: Array<Schemas["Agent"] | null> = [...shown, ...(value ? [null] : [])];

  function pick(i: number) {
    const a = options[i];
    if (a === undefined) return;
    onChange(a ? a.id : null);
    setOpen(false);
  }

  return (
    <Popover.Root open={isOpen} onOpenChange={setOpen}>
      <Popover.Trigger asChild aria-label={pickerName(label, value ? (agents.find((a) => a.id === value)?.name ?? null) : value)}>{children}</Popover.Trigger>
      <Popover.Portal>
        <Popover.Content align="start" sideOffset={6} className={cx(floatPanel, "w-[300px] p-0")}>
          <div className="flex items-center gap-2 border-b border-border-subtle px-3">
            <Icon name="search" size={14} className="text-fg-tertiary" />
            <input
              autoFocus
              role="combobox"
              aria-expanded="true"
              aria-controls="agent-options"
              aria-activedescendant={options.length ? `agent-opt-${active}` : undefined}
              aria-label="Assign to persona"
              placeholder="Assign to persona…"
              value={q}
              onChange={(e) => { setQ(e.target.value); setActive(0); }}
              onKeyDown={(e) => {
                if (e.key === "ArrowDown") { e.preventDefault(); setActive((i) => Math.min(i + 1, options.length - 1)); }
                if (e.key === "ArrowUp") { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
                if (e.key === "Enter") { e.preventDefault(); pick(active); }
              }}
              className="h-10 flex-1 bg-transparent text-13 outline-none placeholder:text-fg-tertiary"
            />
          </div>
          <div id="agent-options" role="listbox" aria-label="Personas" className="max-h-[320px] overflow-y-auto p-1">
            {options.length === 0 && <div className="px-2 py-2 text-fg-tertiary">No personas that take tickets match “{q}”</div>}
            {options.map((a, i) =>
              a ? (
                <div
                  key={a.id}
                  id={`agent-opt-${i}`}
                  role="option"
                  aria-selected={a.id === value}
                  onMouseEnter={() => setActive(i)}
                  onClick={() => pick(i)}
                  className={cx("flex h-10 cursor-default items-center gap-2.5 rounded-md px-2", i === active && "bg-hover")}
                >
                  <AgentAvatar name={a.name} colorIndex={a.color_index} size="md" label={false} />
                  <span className="flex min-w-0 flex-1 flex-col leading-tight">
                    <span className="font-medium">{a.name}</span>
                    <span className="truncate text-12 text-fg-tertiary">
                      {a.model} · {a.specialty}
                    </span>
                  </span>
                  {a.id === value ? (
                    <Icon name="check" size={14} className="text-accent" />
                  ) : (
                    <span className={cx("text-12", availability[a.status].cls)}>{availability[a.status].label}</span>
                  )}
                </div>
              ) : (
                <div
                  key="unassign"
                  id={`agent-opt-${i}`}
                  role="option"
                  aria-selected={false}
                  onMouseEnter={() => setActive(i)}
                  onClick={() => pick(i)}
                  className={cx("mt-1 flex h-9 cursor-default items-center gap-2.5 rounded-md border-t border-border-subtle px-2 text-fg-secondary", i === active && "bg-hover")}
                >
                  <UnassignedAvatar />
                  Unassign
                </div>
              ),
            )}
          </div>
          <p className="border-t border-border-subtle px-3 py-2 text-12 text-fg-tertiary">
            Personas that take tickets. Assigning queues the ticket; a person starts the run.{" "}
            <Link href="/settings?section=personas" className="text-accent hover:underline">Turn it on for another…</Link>
          </p>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}

/** Multi-select labels with checkboxes. Applies on each toggle. */
export function LabelPicker({
  labels,
  value,
  onChange,
  children,
  label = "Labels",
}: {
  labels: Schemas["Label"][];
  value: string[];
  onChange: (ids: string[]) => void;
  children: ReactNode;
  label?: string;
}) {
  const names = labels.filter((l) => value.includes(l.id)).map((l) => l.name).join(", ");
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild aria-label={pickerName(label, names || null)}>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "max-h-[360px] w-52 overflow-y-auto")}>
          {labels.map((l) => {
            const on = value.includes(l.id);
            return (
              <DropdownMenu.CheckboxItem
                key={l.id}
                checked={on}
                className={item}
                onSelect={(e) => e.preventDefault()}
                onCheckedChange={(c) => onChange(c ? [...value, l.id] : value.filter((x) => x !== l.id))}
              >
                <span aria-hidden className="size-2 rounded-full" style={{ background: l.color }} />
                {l.name}
                <Check on={on} />
              </DropdownMenu.CheckboxItem>
            );
          })}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/**
 * Story-point radiogroup with a roving tabindex (WAI-ARIA radio group): one
 * Tab stop, on the checked option (or the first when none is), arrow keys
 * move focus and check, Home/End jump to the ends. Keyboard moves report one
 * change once the person settles (or leaves the group), not one per key.
 */
export function EstimatePicker({
  scale,
  value,
  onChange,
  label = "Estimate",
  disabled,
}: {
  scale: readonly number[];
  value: number | null | undefined;
  onChange: (points: number) => void;
  label?: string;
  disabled?: boolean;
}) {
  const refs = useRef<Array<HTMLButtonElement | null>>([]);
  const [pending, setPending] = useState<number | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const latest = useRef({ pending, value, onChange });
  useEffect(() => {
    latest.current = { pending, value, onChange };
  });
  const flush = () => {
    clearTimeout(timer.current);
    const { pending: p, value: v, onChange: change } = latest.current;
    if (p != null && p !== v) change(p);
    setPending(null);
  };
  // Don't drop a settled keyboard choice when the panel unmounts.
  useEffect(() => () => {
    clearTimeout(timer.current);
    const { pending: p, value: v, onChange: change } = latest.current;
    if (p != null && p !== v) change(p);
  }, []);
  const shown = pending ?? value;
  const checked = shown == null ? -1 : scale.indexOf(shown);
  const stop = checked >= 0 ? checked : 0;
  function move(e: KeyboardEvent, i: number) {
    const last = scale.length - 1;
    const next =
      e.key === "ArrowRight" || e.key === "ArrowDown" ? (i === last ? 0 : i + 1)
      : e.key === "ArrowLeft" || e.key === "ArrowUp" ? (i === 0 ? last : i - 1)
      : e.key === "Home" ? 0
      : e.key === "End" ? last
      : -1;
    if (next < 0) return;
    e.preventDefault();
    refs.current[next]?.focus();
    setPending(scale[next]);
    latest.current.pending = scale[next];
    clearTimeout(timer.current);
    timer.current = setTimeout(flush, 600);
  }
  return (
    <div
      role="radiogroup"
      aria-label={label}
      aria-disabled={disabled || undefined}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) flush();
      }}
      className="inline-flex overflow-hidden rounded-md border border-border-strong">
      {scale.map((n, i) => (
        <button
          key={n}
          ref={(el) => { refs.current[i] = el; }}
          type="button"
          role="radio"
          aria-checked={i === checked}
          tabIndex={i === stop ? 0 : -1}
          disabled={disabled}
          onClick={() => {
            clearTimeout(timer.current);
            setPending(null);
            latest.current.pending = null;
            if (n !== value) onChange(n);
          }}
          onKeyDown={(e) => move(e, i)}
          className={cx(
            "h-7 min-w-7 border-l border-border-strong px-1.5 font-mono text-12 first:border-l-0 focus-visible:relative focus-visible:z-10 disabled:opacity-50",
            i === checked ? "bg-accent text-on-accent" : "text-fg-2 hover:bg-hover",
          )}
        >
          {n}
        </button>
      ))}
    </div>
  );
}

/**
 * A list page's filter or sort: a menu like the app's other pickers rather than a native <select>.
 * Its name says what it filters and what it's set to ("Epic: All epics"). quiet: text only, for a
 * sort that sits beside other controls.
 */
export function FilterMenu({ label, value, options, onChange, quiet, className }: { label: string; value: string; options: { value: string; label: string }[]; onChange: (v: string) => void; quiet?: boolean; className?: string }) {
  const current = options.find((o) => o.value === value) ?? options[0];
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button type="button" aria-label={`${label}: ${current?.label ?? ""}`}
          className={cx(
            "flex h-8 max-w-56 items-center gap-1.5 rounded-md px-2.5 text-12 hover:bg-hover data-[state=open]:border-accent",
            quiet ? "text-fg-secondary hover:text-fg" : "border border-border-strong bg-surface text-fg",
            className,
          )}>
          <span className="truncate">{current?.label}</span>
          <Icon name="chev" size={12} strokeWidth={1.6} className="flex-none text-fg-tertiary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="end" sideOffset={6} className={cx(floatPanel, "max-h-80 w-56 overflow-y-auto")}>
          <DropdownMenu.RadioGroup value={value} onValueChange={onChange}>
            {options.map((o) => (
              <DropdownMenu.RadioItem key={o.value} value={o.value} className="flex h-8 cursor-default select-none items-center gap-2 rounded-md px-2 text-13 outline-none data-[highlighted]:bg-hover">
                <span className="flex-1 truncate">{o.label}</span>
                <DropdownMenu.ItemIndicator><Icon name="check" size={14} className="text-accent" /></DropdownMenu.ItemIndicator>
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
