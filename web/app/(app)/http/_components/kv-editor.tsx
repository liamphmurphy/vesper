"use client";

import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { TextInput } from "@/components/ui/primitives";
import type { EnvVar, KeyValue } from "@/lib/api/http-client-hooks";
import type { ApiSecret } from "@/lib/api/secret-hooks";

export function KVEditor({
  items,
  onChange,
  keyPlaceholder = "Key",
  valuePlaceholder = "Value",
  emptyLabel = "No entries yet.",
}: {
  items: KeyValue[];
  onChange: (next: KeyValue[]) => void;
  keyPlaceholder?: string;
  valuePlaceholder?: string;
  emptyLabel?: string;
}) {
  const update = (idx: number, patch: Partial<KeyValue>) => {
    onChange(items.map((row, i) => (i === idx ? { ...row, ...patch } : row)));
  };
  const remove = (idx: number) => {
    onChange(items.filter((_, i) => i !== idx));
  };
  const add = () => {
    onChange([...items, { key: "", value: "", enabled: true }]);
  };

  return (
    <div className="flex flex-col gap-2">
      {items.length === 0 ? (
        <p className="text-12 text-fg-tertiary">{emptyLabel}</p>
      ) : (
        <div className="flex flex-col gap-1.5">
          {items.map((row, idx) => (
            <div key={idx} className="flex items-center gap-1.5">
              <input
                type="checkbox"
                aria-label={`Enable ${row.key || `row ${idx + 1}`}`}
                checked={row.enabled}
                onChange={(e) => update(idx, { enabled: e.target.checked })}
                className="size-3.5 accent-accent"
              />
              <TextInput
                mono
                value={row.key}
                placeholder={keyPlaceholder}
                onChange={(e) => update(idx, { key: e.target.value })}
                className="min-w-0 flex-1"
              />
              <TextInput
                mono
                value={row.value}
                placeholder={valuePlaceholder}
                onChange={(e) => update(idx, { value: e.target.value })}
                className="min-w-0 flex-[1.4]"
              />
              <button
                type="button"
                aria-label="Remove row"
                onClick={() => remove(idx)}
                className="grid size-[30px] flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
              >
                <Icon name="trash" size={14} />
              </button>
            </div>
          ))}
        </div>
      )}
      <div>
        <Button variant="outline" icon="plus" onClick={add}>
          Add row
        </Button>
      </div>
    </div>
  );
}

export function EnvVarEditor({
  items,
  secrets,
  onChange,
  emptyLabel = "No variables in this environment yet.",
}: {
  items: EnvVar[];
  secrets: ApiSecret[];
  onChange: (next: EnvVar[]) => void;
  emptyLabel?: string;
}) {
  const update = (idx: number, patch: Partial<EnvVar>) => {
    onChange(items.map((row, i) => (i === idx ? { ...row, ...patch } : row)));
  };
  const remove = (idx: number) => {
    onChange(items.filter((_, i) => i !== idx));
  };
  const add = () => {
    onChange([...items, { key: "", value: "", secret_handle: "", enabled: true }]);
  };

  return (
    <div className="flex flex-col gap-2">
      {items.length === 0 ? (
        <p className="text-12 text-fg-tertiary">{emptyLabel}</p>
      ) : (
        <div className="flex flex-col gap-1.5">
          {items.map((row, idx) => {
            const usesSecret = Boolean(row.secret_handle);
            return (
              <div key={idx} className="flex flex-wrap items-center gap-1.5">
                <input
                  type="checkbox"
                  aria-label={`Enable ${row.key || `variable ${idx + 1}`}`}
                  checked={row.enabled}
                  onChange={(e) => update(idx, { enabled: e.target.checked })}
                  className="size-3.5 accent-accent"
                />
                <TextInput
                  mono
                  value={row.key}
                  placeholder="variable_name"
                  onChange={(e) => update(idx, { key: e.target.value })}
                  className="min-w-[120px] flex-1"
                />
                {usesSecret ? (
                  <select
                    aria-label="Vesper secret"
                    value={row.secret_handle ?? ""}
                    onChange={(e) => update(idx, { secret_handle: e.target.value })}
                    className="h-[30px] min-w-[160px] flex-[1.4] rounded-md border border-border-strong bg-surface px-2 font-mono text-12 text-fg focus:border-accent focus:outline-none"
                  >
                    <option value="">Plain value…</option>
                    {secrets.map((s) => (
                      <option key={s.id} value={s.handle}>
                        secret:{s.handle} ({s.name})
                      </option>
                    ))}
                    {row.secret_handle && !secrets.some((s) => s.handle === row.secret_handle) && (
                      <option value={row.secret_handle}>secret:{row.secret_handle}</option>
                    )}
                  </select>
                ) : (
                  <TextInput
                    mono
                    value={row.value}
                    placeholder="https://api.nonprod.example.com"
                    onChange={(e) => update(idx, { value: e.target.value })}
                    className="min-w-[160px] flex-[1.4]"
                  />
                )}
                <button
                  type="button"
                  title={usesSecret ? "Switch to plain value" : "Use a Vesper secret"}
                  onClick={() =>
                    update(
                      idx,
                      usesSecret
                        ? { secret_handle: "" }
                        : { secret_handle: secrets[0]?.handle ?? "api-token", value: "" },
                    )
                  }
                  className="inline-flex h-[30px] items-center gap-1 rounded-md border border-border-strong bg-surface px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg"
                >
                  <Icon name={usesSecret ? "lock" : "key"} size={13} />
                  {usesSecret ? "Secret" : "Plain"}
                </button>
                <button
                  type="button"
                  aria-label="Remove variable"
                  onClick={() => remove(idx)}
                  className="grid size-[30px] flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
                >
                  <Icon name="trash" size={14} />
                </button>
              </div>
            );
          })}
        </div>
      )}
      <div>
        <Button variant="outline" icon="plus" onClick={add}>
          Add variable
        </Button>
      </div>
    </div>
  );
}
