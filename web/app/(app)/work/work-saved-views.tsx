"use client";

import { useState } from "react";
import { useSearchParams } from "next/navigation";
import { useCreateSavedView, useSavedViews } from "@/lib/api/hooks";
import { updateWorkUrl } from "@/lib/work-navigation";
import { workViewPatch, workViewQuery } from "@/lib/native-shell/models/saved-views";
import { FilterMenu } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";
import { TextInput } from "@/components/ui/primitives";

export function WorkSavedViews() {
  const params = useSearchParams();
  const views = useSavedViews();
  const create = useCreateSavedView();
  const [saving, setSaving] = useState(false);
  const [name, setName] = useState("");
  function apply(id: string) {
    const v = views.data?.find((v) => v.id === id);
    if (!v) return;
    updateWorkUrl(workViewPatch(id, v.query));
  }
  return (
    <div className="flex flex-wrap items-center gap-1 text-11">
      <FilterMenu
        quiet
        label="Saved views"
        value={params.get("saved") ?? ""}
        onChange={apply}
        options={[
          { value: "", label: "Saved views" },
          ...(views.data ?? []).map((v) => ({ value: v.id, label: v.name })),
        ]}
      />
      <button
        aria-label="Save current Work filters"
        className="px-2 text-fg-tertiary hover:text-fg"
        onClick={() => setSaving(!saving)}
      >
        +
      </button>
      {views.isError && (
        <p role="alert">
          Couldn’t load saved views.{" "}
          <button onClick={() => views.refetch()}>Retry</button>
        </p>
      )}
      {saving && (
        <form
          className="flex flex-wrap gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (!name.trim() || create.isPending) return;
            const q = workViewQuery(params);
            create.mutate(
              { name: name.trim(), query: q },
              {
                onSuccess: () => {
                  setSaving(false);
                  setName("");
                },
              },
            );
          }}
        >
          <TextInput
            aria-label="View name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={80}
          />
          <Button type="submit" disabled={!name.trim() || create.isPending}>
            Save
          </Button>
          <Button onClick={() => setSaving(false)}>Cancel</Button>
          {create.isError && <p role="alert">{create.error.message}</p>}
        </form>
      )}
    </div>
  );
}
