"use client";

import { useMemo, useState } from "react";
import { DropdownMenu } from "radix-ui";
import type { Harness, Schemas } from "@/lib/api/client";
import type { CompareModelOption } from "@/lib/chat-commands";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";

type Group = Schemas["ChatHarnessModels"];

/** Orders available models for a second opinion: other harnesses first, then default models first within each harness. */
export function buildCompareOptions(
  groups: Group[] | undefined,
  currentHarness?: Harness,
  currentModel?: string,
): CompareModelOption[] {
  if (!groups?.length) return [];
  const available = [...groups]
    .filter((g) => g.available && g.models.length > 0)
    .sort((a, b) => Number(a.harness === currentHarness) - Number(b.harness === currentHarness));

  const all: CompareModelOption[] = [];
  for (const g of available) {
    const models = [...g.models].sort((a, b) => Number(!!b.default) - Number(a.default));
    for (const m of models) {
      all.push({
        name: `${g.label} · ${m.label}`,
        harness: g.harness,
        harnessLabel: g.label,
        model: m.id,
        modelLabel: m.label,
        isDefault: m.default,
      });
    }
  }
  const filtered = all.filter((o) => !(o.harness === currentHarness && o.model === currentModel));
  return filtered.length > 0 ? filtered : all;
}

export type SecondOpinionPick = { harness: Harness; model: string; body?: string };

const itemClass =
  "flex cursor-default select-none items-center justify-between gap-2 rounded-md px-2 py-1.5 text-13 text-fg outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

/** Model picker for launching a read-only cross-harness second opinion without touching the parent chat session or prompt cache. */
export function SecondOpinionMenu({
  groups,
  currentHarness,
  currentModel,
  onSelect,
  onOpenChange,
  variant = "icon",
  disabled,
  testId,
}: {
  groups: Group[] | undefined;
  currentHarness?: Harness;
  currentModel?: string;
  onSelect: (pick: SecondOpinionPick) => void;
  onOpenChange?: (open: boolean) => void;
  variant?: "icon" | "button";
  disabled?: boolean;
  testId?: string;
}) {
  const [open, setOpen] = useState(false);
  const [focus, setFocus] = useState("");
  const options = useMemo(() => buildCompareOptions(groups, currentHarness, currentModel), [groups, currentHarness, currentModel]);

  const byHarness = useMemo(() => {
    const grouped: Array<{ harness: string; label: string; isOther: boolean; items: CompareModelOption[] }> = [];
    for (const opt of options) {
      let bucket = grouped.find((g) => g.harness === opt.harness);
      if (!bucket) {
        bucket = { harness: opt.harness, label: opt.harnessLabel, isOther: opt.harness !== currentHarness, items: [] };
        grouped.push(bucket);
      }
      bucket.items.push(opt);
    }
    return grouped;
  }, [options, currentHarness]);

  const handleOpenChange = (next: boolean) => {
    setOpen(next);
    if (!next) setFocus("");
    onOpenChange?.(next);
  };

  const choose = (opt: CompareModelOption) => {
    const trimmed = focus.trim();
    setFocus("");
    setOpen(false);
    onOpenChange?.(false);
    onSelect({ harness: opt.harness as Harness, model: opt.model, ...(trimmed ? { body: trimmed } : {}) });
  };

  return (
    <DropdownMenu.Root open={open} onOpenChange={handleOpenChange}>
      <DropdownMenu.Trigger asChild>
        {variant === "button" ? (
          <button
            type="button"
            disabled={disabled || options.length === 0}
            data-testid={testId ?? "code-second-opinion"}
            className="inline-flex h-7 items-center gap-1.5 rounded-md border border-border px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg focus-visible:ring-2 focus-visible:ring-accent outline-none disabled:opacity-50"
          >
            <Icon name="compare" size={13} />
            <span>Second opinion…</span>
          </button>
        ) : (
          <button
            type="button"
            aria-label="Second opinion"
            title="Second opinion"
            disabled={disabled || options.length === 0}
            data-testid={testId ?? "message-second-opinion"}
            className="grid size-7 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg focus-visible:ring-2 focus-visible:ring-accent outline-none disabled:opacity-50"
          >
            <Icon name="compare" size={14} />
          </button>
        )}
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          data-testid="second-opinion-menu"
          className={cx(floatPanel, "w-72 max-h-[min(24rem,var(--radix-dropdown-menu-content-available-height))] overflow-y-auto p-1.5")}
        >
          <p className="px-1.5 pb-1 text-11 text-fg-tertiary">
            Read-only critique · keeps current prompt cache warm
          </p>
          <div
            className="px-1 pb-1.5"
            onPointerDown={(e) => e.stopPropagation()}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && options[0]) {
                e.preventDefault();
                e.stopPropagation();
                choose(options[0]);
                return;
              }
              if (e.key !== "Escape" && e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "Tab") {
                e.stopPropagation();
              }
            }}
          >
            <input
              type="text"
              value={focus}
              onChange={(e) => setFocus(e.target.value)}
              aria-label="Second opinion focus"
              placeholder="Optional focus (e.g. race conditions)…"
              className="h-7 w-full rounded-md border border-border bg-surface px-2 text-12 text-fg placeholder:text-fg-tertiary focus:border-accent focus:outline-none"
            />
          </div>
          {byHarness.length === 0 ? (
            <p className="px-2 py-2 text-12 text-fg-tertiary">No available models.</p>
          ) : (
            byHarness.map((group, idx) => (
              <DropdownMenu.Group key={group.harness}>
                {idx > 0 && <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />}
                <DropdownMenu.Label className="flex items-center justify-between px-2 py-1 text-11 font-medium text-fg-tertiary">
                  <span>{group.label}</span>
                  {group.isOther && <span className="text-10 text-accent">Other harness</span>}
                </DropdownMenu.Label>
                {group.items.map((opt) => (
                  <DropdownMenu.Item
                    key={`${opt.harness}:${opt.model}`}
                    onSelect={() => choose(opt)}
                    data-testid={`second-opinion-option-${opt.harness}-${opt.model}`}
                    className={itemClass}
                  >
                    <span className="truncate">{opt.modelLabel}</span>
                    {opt.isDefault && <span className="text-11 text-fg-tertiary">Default</span>}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Group>
            ))
          )}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
