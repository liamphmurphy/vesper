"use client";

import { DropdownMenu } from "radix-ui";
import type { Harness, Schemas } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";
import { catalogModelLabel } from "@/lib/chat-ui";
import { composerGhost } from "./reply-tools";

/** auto routes the model per message (the server's AutoModel); model is then the one it starts from. */
export type Selection = { harness: Harness; model: string; auto?: boolean };
export type Effort = Schemas["ChatEffort"];
type Group = Schemas["ChatHarnessModels"];

const EFFORT_LABELS: Record<Effort, string> = { low: "Low", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max" };
export const effortLabel = (e: Effort | undefined) => (e ? EFFORT_LABELS[e] : "Automatic");

/**
 * The efforts the selected model offers. A model the catalog doesn't list (the
 * definition's alias) gets its harness default model's, as the server allows.
 */
export function modelEfforts(groups: Group[] | undefined, s: Selection): { efforts: Effort[] } {
  if (!s.model && !s.auto) return { efforts: [] };
  const g = groups?.find((x) => x.harness === s.harness);
  const m = g?.models.find((x) => x.id === s.model) ?? g?.models.find((x) => x.default);
  return { efforts: m?.efforts ?? [] };
}

export const sameSelection = (a: Selection, b: Selection) =>
  a.harness === b.harness && !!a.auto === !!b.auto && (!!a.auto || a.model === b.model);

export function modelLabel(groups: Group[] | undefined, s: Selection) {
  const g = groups?.find((x) => x.harness === s.harness);
  return { harness: g?.label ?? s.harness, model: catalogModelLabel(g?.models ?? [], s.model) };
}

// Two harnesses' models plus the efforts outgrow the room above a low
// composer (the Welcome's), so the menu scrolls inside whatever space Radix
// finds instead of running off the top of the window.
const menuHeight = "max-h-[min(24rem,var(--radix-dropdown-menu-content-available-height))]";
const menuPanel = cx(floatPanel, "w-64 overflow-y-auto", menuHeight);
// Models and efforts side by side, each column scrolling on its own, so the
// efforts never sit below a long model list.
const columnsPanel = cx(floatPanel, "flex w-[min(26rem,calc(100vw-16px))]", menuHeight);
const MENU_EDGE = 8;

const item =
  "flex min-h-8 cursor-default select-none flex-col justify-center rounded-md px-2 py-1 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

/** Harness/model choice as a form field (the Learn guide). The composer uses ModelEffortPicker. */
export function ModelPicker({
  groups,
  value,
  onChange,
  disabled,
}: {
  groups?: Group[];
  value: Selection;
  onChange: (s: Selection) => void;
  disabled?: boolean;
}) {
  const l = modelLabel(groups, value);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={`Model for the next message: ${l.harness}, ${l.model}`}
          title={`${l.harness} · ${l.model}`}
          className="flex h-[30px] max-w-full items-center gap-1.5 rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50"
        >
          <span className="truncate">{l.harness} · {l.model}</span>
          <Icon name="chev" size={13} strokeWidth={1.6} className="text-fg-tertiary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" side="top" sideOffset={6} collisionPadding={MENU_EDGE} className={menuPanel}>
          {(groups ?? []).map((g, i) => (
            <DropdownMenu.Group key={g.harness} aria-label={g.label}>
              {i > 0 && <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />}
              <DropdownMenu.Label className="px-2 py-1 text-12 font-medium text-fg-tertiary">{g.label}</DropdownMenu.Label>
              {!g.available && (
                <div role="status" className="px-2 py-1 text-12 text-fg-tertiary">
                  {g.checking ? "Checking available models…" : g.unavailable_reason ?? "Model discovery unavailable"}
                </div>
              )}
              {g.models.map((m) => {
                const on = value.harness === g.harness && value.model === m.id;
                return (
                  <DropdownMenu.Item
                    key={m.id}
                    disabled={!g.available}
                    aria-label={`${g.label} ${m.label}${g.available ? "" : ` (unavailable: ${g.unavailable_reason ?? "not configured"})`}`}
                    className={item}
                    onSelect={() => onChange({ harness: g.harness, model: m.id })}
                  >
                    <span className="flex items-center gap-2">
                      {m.label}
                      <span className="ml-auto w-4 text-accent">{on && <Icon name="check" size={14} strokeWidth={1.8} />}</span>
                    </span>
                    {!g.available && <span className="text-12 text-fg-tertiary">{g.unavailable_reason ?? "Unavailable"}</span>}
                  </DropdownMenu.Item>
                );
              })}
            </DropdownMenu.Group>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** The composer's short effort name: "Auto" rather than "Automatic", which the menu spells out. */
const effortShort = (e: Effort | undefined) => (e ? EFFORT_LABELS[e] : "Auto");

/** What the composer's model control reads: the model, and the effort unless both are automatic. */
export function modelEffortSummary(groups: Group[] | undefined, value: Selection, hasEfforts: boolean, effort: Effort | undefined) {
  const model = value.auto ? "Auto" : modelLabel(groups, value).model;
  // "Auto · Auto" says nothing twice: an all-automatic choice is just "Auto".
  const shown = hasEfforts && !(value.auto && !effort) ? effortShort(effort) : undefined;
  return { model, effort: shown, text: shown ? `${model} · ${shown}` : model };
}

/**
 * The composer's model and effort, as one quiet control ("Opus 5.5 · Auto"): they're set
 * together and rarely change. One menu in two columns: the models by harness, and beside
 * them the reasoning effort the picked model offers (one column when it has no effort control).
 */
export function ModelEffortPicker({
  groups,
  value,
  onChange,
  efforts,
  effort,
  onEffort,
  disabled,
  allowAuto = true,
  side = "top",
  align = "end",
  showHarness = false,
  placeholder,
  ariaLabel,
  triggerClassName,
}: {
  groups?: Group[];
  value: Selection;
  onChange: (s: Selection) => void;
  efforts: Effort[];
  effort: Effort | undefined;
  onEffort: (e: Effort | undefined) => void;
  disabled?: boolean;
  allowAuto?: boolean;
  side?: "top" | "bottom";
  align?: "start" | "end";
  showHarness?: boolean;
  placeholder?: string;
  ariaLabel?: string;
  triggerClassName?: string;
}) {
  const l = modelLabel(groups, value);
  const options: (Effort | undefined)[] = efforts.length ? [undefined, ...efforts] : [];
  const hasModel = !!value.auto || !!value.model;
  const summary = modelEffortSummary(groups, value, efforts.length > 0, effort);
  const displayModel = !hasModel ? (placeholder ?? "Pick model") : value.auto || !showHarness ? summary.model : `${l.harness} · ${summary.model}`;
  const defaultAriaLabel = `Model and effort for the next message: ${l.harness}, ${value.auto ? "automatic model" : l.model || (placeholder ?? "unset")}${options.length ? `, ${effortLabel(effort)} effort` : ""}`;
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={ariaLabel ?? defaultAriaLabel}
          title={hasModel ? `${l.harness} · ${value.auto ? `Auto (now ${l.model})` : l.model}${options.length ? ` · ${effortLabel(effort)} effort` : ""}` : (placeholder ?? "Pick model")}
          className={triggerClassName ?? composerGhost}
        >
          <span className={cx("truncate", !hasModel && "text-fg-tertiary")}>
            {displayModel}
            {hasModel && summary.effort && <span className="text-fg-tertiary"> · </span>}
            {hasModel && summary.effort}
          </span>
          <Icon name="chev" size={13} strokeWidth={1.6} className="flex-none text-fg-tertiary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align={align} side={side} sideOffset={6} collisionPadding={MENU_EDGE} className={options.length ? columnsPanel : menuPanel}>
          <div className={options.length ? "min-w-0 flex-1 overflow-y-auto" : undefined}>
            {allowAuto && (
              <>
                <DropdownMenu.Item aria-label="Automatic model" className={item} onSelect={() => onChange({ harness: value.harness, model: value.model, auto: true })}>
                  <span className="flex items-center gap-2">
                    Auto
                    <span className="ml-auto w-4 text-accent">{value.auto && <Icon name="check" size={14} strokeWidth={1.8} />}</span>
                  </span>
                  <span className="text-12 text-fg-tertiary">Picks the model for each message</span>
                </DropdownMenu.Item>
                <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
              </>
            )}
            {(groups ?? []).map((g, i) => (
              <DropdownMenu.Group key={g.harness} aria-label={g.label}>
                {i > 0 && <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />}
                <DropdownMenu.Label className="px-2 py-1 text-12 font-medium text-fg-tertiary">{g.label}</DropdownMenu.Label>
                {!g.available && (
                  <div role="status" className="px-2 py-1 text-12 text-fg-tertiary">
                    {g.checking ? "Checking available models…" : g.unavailable_reason ?? "Model discovery unavailable"}
                  </div>
                )}
                {g.models.map((m) => {
                  const on = !value.auto && value.harness === g.harness && (value.model === m.id || catalogModelLabel([m], value.model) === m.label);
                  return (
                    <DropdownMenu.Item
                      key={m.id}
                      disabled={!g.available}
                      aria-label={`${g.label} ${m.label}${g.available ? "" : ` (unavailable: ${g.unavailable_reason ?? "not configured"})`}`}
                      className={item}
                      onSelect={() => onChange({ harness: g.harness, model: m.id })}
                    >
                      <span className="flex items-center gap-2">
                        {m.label}
                        <span className="ml-auto w-4 text-accent">{on && <Icon name="check" size={14} strokeWidth={1.8} />}</span>
                      </span>
                      {!g.available && <span className="text-12 text-fg-tertiary">{g.unavailable_reason ?? "Unavailable"}</span>}
                    </DropdownMenu.Item>
                  );
                })}
              </DropdownMenu.Group>
            ))}
          </div>
          {options.length > 0 && (
            <DropdownMenu.Group aria-label="Reasoning effort" className="ml-1 w-36 flex-none overflow-y-auto border-l border-border-subtle pl-1">
              <DropdownMenu.Label className="px-2 py-1 text-12 font-medium text-fg-tertiary">Reasoning effort</DropdownMenu.Label>
              {options.map((e) => (
                <DropdownMenu.Item key={e ?? "default"} className={item} onSelect={() => onEffort(e)}>
                  <span className="flex items-center gap-2">
                    {effortLabel(e)}
                    <span className="ml-auto w-4 text-accent">{effort === e && <Icon name="check" size={14} strokeWidth={1.8} />}</span>
                  </span>
                </DropdownMenu.Item>
              ))}
            </DropdownMenu.Group>
          )}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
