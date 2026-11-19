"use client";

import { DropdownMenu } from "radix-ui";
import type { ReactNode } from "react";
import { useBootstrap } from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useConnectors } from "@/lib/api/connector-hooks";
import { cx } from "@/lib/cx";
import { SPACE_COLORS, spaceHex, spaceInitial, type SpaceColor } from "@/lib/spaces";
import { floatPanel } from "@/components/domain/pickers";
import { Icon } from "@/components/ui/icon";

/** A space's tile: its initial on a tint of its color (mockups 1–3). */
export function SpaceTile({ name, color, size = 16, className }: { name: string; color?: string; size?: number; className?: string }) {
  const hex = spaceHex(color);
  return (
    <span
      aria-hidden
      className={cx("grid flex-none place-items-center font-bold leading-none", className)}
      style={{
        width: size,
        height: size,
        borderRadius: Math.round(size / 4),
        fontSize: Math.max(9, Math.round(size * 0.55)),
        background: `color-mix(in srgb, ${hex} 25%, transparent)`,
        color: `color-mix(in srgb, ${hex} 85%, var(--text))`,
      }}
    >
      {spaceInitial(name)}
    </span>
  );
}

const menuItem = "flex h-[32px] cursor-default select-none items-center gap-[10px] rounded-md px-[8px] text-13 outline-none data-[highlighted]:bg-hover";

/** The tile as a button that picks the space's color. */
export function ColorPicker({ name, value, onChange, size = 40, disabled }: { name: string; value: SpaceColor; onChange: (c: SpaceColor) => void; size?: number; disabled?: boolean }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={`Space color: ${value}`}
          className="grid flex-none place-items-center rounded-lg border border-border-strong hover:brightness-110 data-[state=open]:border-accent disabled:opacity-50"
          style={{ width: size, height: size }}
        >
          <SpaceTile name={name || "?"} color={value} size={size - 2} />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "grid grid-cols-4 gap-[4px] p-[8px]")}>
          {SPACE_COLORS.map((c) => (
            <DropdownMenu.Item
              key={c.value}
              aria-label={c.label}
              onSelect={() => onChange(c.value)}
              className={cx("grid size-[36px] cursor-default place-items-center rounded-md outline-none data-[highlighted]:bg-hover", c.value === value && "bg-selected")}
            >
              <SpaceTile name={name || "?"} color={c.value} size={24} />
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** A labelled box that opens a menu: the defaults row in mockup 3. */
function SelectBox({ label, value, muted, disabled, children }: { label: string; value: string; muted: boolean; disabled?: boolean; children: ReactNode }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={`${label}: ${value}`}
          className="flex h-[56px] min-w-[0px] flex-1 flex-col justify-center gap-[4px] rounded-lg border border-border-strong bg-surface-sunken px-[14px] text-left hover:bg-hover data-[state=open]:border-accent disabled:opacity-50"
        >
          <span className="text-11 text-fg-tertiary">{label}</span>
          <span className="flex w-full items-center gap-[8px]">
            <span className={cx("min-w-[0px] flex-1 truncate text-14", muted ? "text-fg-secondary" : "text-fg")}>{value}</span>
            <Icon name="chev" size={12} className="flex-none text-fg-secondary" />
          </span>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "max-h-[288px] w-[240px] overflow-y-auto")}>
          {children}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

const Check = ({ on }: { on: boolean }) => <span className="ml-auto w-[14px] text-accent">{on && <Icon name="check" size={14} />}</span>;

/** The persona a space's new chats start with; "" is the default persona. */
export function usePersonaName(id: string) {
  const q = usePersonas();
  const personas = q.data?.personas ?? [];
  const def = personas.find((p) => p.id === q.data?.default_persona_id);
  const picked = personas.find((p) => p.id === id);
  return picked?.name ?? def?.name ?? "Assistant";
}

export function PersonaSelect({ value, onChange, disabled }: { value: string; onChange: (id: string) => void; disabled?: boolean }) {
  const q = usePersonas();
  const personas = q.data?.personas ?? [];
  const name = usePersonaName(value);
  return (
    <SelectBox label="Persona" value={name} muted={false} disabled={disabled}>
      <DropdownMenu.RadioGroup value={value} onValueChange={onChange}>
        <DropdownMenu.RadioItem value="" className={menuItem}>
          <span className="flex-1">Default persona</span>
          <Check on={!value} />
        </DropdownMenu.RadioItem>
        {personas.length > 0 && <DropdownMenu.Separator className="my-[4px] h-px bg-border-strong" />}
        {personas.map((p) => (
          <DropdownMenu.RadioItem key={p.id} value={p.id} className={menuItem}>
            <span aria-hidden className="size-[10px] flex-none rounded-full" style={{ background: p.color }} />
            <span className="flex-1 truncate">{p.name}</span>
            <Check on={value === p.id} />
          </DropdownMenu.RadioItem>
        ))}
      </DropdownMenu.RadioGroup>
    </SelectBox>
  );
}

export function useProjectName(key: string) {
  const boot = useBootstrap();
  return (boot.data?.projects ?? []).find((p) => p.key === key)?.name;
}

export function ProjectSelect({ value, onChange, disabled }: { value: string; onChange: (key: string) => void; disabled?: boolean }) {
  const boot = useBootstrap();
  const projects = (boot.data?.projects ?? []).filter((p) => !p.archived || p.key === value);
  const name = useProjectName(value);
  return (
    <SelectBox label="New tickets go to" value={name ?? "None"} muted={!name} disabled={disabled}>
      <DropdownMenu.RadioGroup value={value} onValueChange={onChange}>
        <DropdownMenu.RadioItem value="" className={menuItem}>
          <span className="flex-1 text-fg-secondary">None</span>
          <Check on={!value} />
        </DropdownMenu.RadioItem>
        {projects.length > 0 && <DropdownMenu.Separator className="my-[4px] h-px bg-border-strong" />}
        {projects.map((p) => (
          <DropdownMenu.RadioItem key={p.key} value={p.key} className={menuItem}>
            <span aria-hidden className="size-[10px] flex-none rounded-[3px]" style={{ background: p.color }} />
            <span className="flex-1 truncate">{p.name}</span>
            <Check on={value === p.key} />
          </DropdownMenu.RadioItem>
        ))}
      </DropdownMenu.RadioGroup>
    </SelectBox>
  );
}

export function useConnectorNames(ids: string[]) {
  const list = useConnectors();
  const rows = list.data?.connectors ?? [];
  const names = ids.map((id) => rows.find((c) => c.id === id)?.name).filter((n): n is string => !!n);
  return names.length ? names.join(", ") : "None";
}

/** Which connectors chats in the space may use; none by default. */
export function ConnectorSelect({ value, onChange, disabled }: { value: string[]; onChange: (ids: string[]) => void; disabled?: boolean }) {
  const list = useConnectors();
  const rows = list.data?.connectors ?? [];
  const label = useConnectorNames(value);
  const toggle = (id: string, on: boolean) => onChange(on ? [...value, id] : value.filter((v) => v !== id));
  return (
    <SelectBox label="Connectors" value={label} muted={label === "None"} disabled={disabled}>
      {rows.length === 0 ? (
        <p className="px-[8px] py-[6px] text-12 text-fg-secondary">No connectors yet. Add one under Settings → Connectors.</p>
      ) : (
        rows.map((c) => (
          <DropdownMenu.CheckboxItem key={c.id} checked={value.includes(c.id)} onCheckedChange={(on) => toggle(c.id, on === true)} onSelect={(e) => e.preventDefault()} className={menuItem}>
            <span className="flex-1 truncate">{c.name}</span>
            <Check on={value.includes(c.id)} />
          </DropdownMenu.CheckboxItem>
        ))
      )}
    </SelectBox>
  );
}

/** Space memory or shared memory, as two radio cards (mockup 3). */
export function MemoryChoice({ value, onChange, disabled }: { value: boolean; onChange: (spaceMemory: boolean) => void; disabled?: boolean }) {
  const options = [
    { on: true, title: "Space memory", detail: "Facts learned here stay in this space. Chats here still read your general memory." },
    { on: false, title: "Shared memory", detail: "Read and update your general memory, like any other chat." },
  ];
  return (
    <div role="radiogroup" aria-label="Memory" className="flex flex-col gap-[10px]">
      {options.map((o) => {
        const picked = value === o.on;
        return (
          <button
            key={o.title}
            type="button"
            role="radio"
            aria-checked={picked}
            disabled={disabled}
            onClick={() => onChange(o.on)}
            className={cx(
              "flex min-h-[64px] items-center gap-[14px] rounded-[10px] border px-[16px] py-[12px] text-left disabled:opacity-50",
              picked ? "border-accent bg-accent-soft" : "border-border-strong bg-surface-sunken hover:bg-hover",
            )}
          >
            <span className={cx("grid size-[16px] flex-none place-items-center rounded-full border-[1.5px]", picked ? "border-accent" : "border-fg-tertiary")}>
              {picked && <span className="size-[8px] rounded-full bg-accent" />}
            </span>
            <span className="flex min-w-[0px] flex-col gap-[2px]">
              <span className="text-14 font-semibold text-fg">{o.title}</span>
              <span className="text-12 text-fg-secondary">{o.detail}</span>
            </span>
          </button>
        );
      })}
    </div>
  );
}
