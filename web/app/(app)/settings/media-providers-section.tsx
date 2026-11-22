"use client";

import { useState } from "react";
import {
  useCheckMediaProvider,
  useClearMediaProviderSecret,
  useMediaProviders,
  useSetMediaDefault,
  useUpdateMediaProvider,
  type MediaFieldSpec,
  type MediaProvider,
  type MediaProviderCheckResponse,
} from "@/lib/api/media-hooks";
import { cx } from "@/lib/cx";
import {
  activeMusicProvider,
  buildProviderPatch,
  effectiveSettings,
  isFieldVisible,
  musicProviders,
  providerStatus,
} from "@/lib/media-providers";
import { toast } from "@/lib/toast";
import { Button } from "@/components/ui/button";
import { Segmented } from "@/components/ui/controls";
import { LoadingLines } from "@/components/ui/loading";
import { Card, Field, TextInput } from "@/components/ui/primitives";

const STATUS_PILL = {
  ready: "bg-pill-done-bg text-pill-done-fg",
  "needs-setup": "bg-pill-human-bg text-pill-human-fg",
  soon: "bg-selected text-fg-tertiary",
  disabled: "bg-selected text-fg-tertiary",
} as const;

const CAPABILITY_LABEL: Record<string, string> = {
  music: "Music",
  video: "Video",
  tts: "TTS",
  script: "Podcast script",
};

/** Settings: pluggable media providers (music generation now; TTS/podcasts later) & workspace defaults. */
export function MediaProvidersSection() {
  const list = useMediaProviders();
  const setDefault = useSetMediaDefault();

  if (list.isPending) return <LoadingLines />;
  if (list.error) return <p role="alert" className="text-14 text-pill-blocked-fg">{list.error.message}</p>;

  const data = list.data;
  const engines = musicProviders(data);
  const active = activeMusicProvider(data);
  const selectedEngine = data.defaults.music || active?.id;

  return (
    <div className="flex flex-col gap-4" data-testid="media-providers-section">
      {engines.length > 0 && (
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-2">
            <span className="text-13 font-medium text-fg">Active Music engine</span>
            {active && <span className="text-12 text-fg-tertiary">Using {active.label}</span>}
          </div>
          <div role="radiogroup" aria-label="Music engine" className="flex flex-col gap-1.5">
            {engines.map((p) => {
              const on = selectedEngine === p.id;
              const disabled = setDefault.isPending || p.coming_soon || !p.available || !p.enabled;
              return (
                <button
                  key={p.id}
                  type="button"
                  role="radio"
                  aria-checked={on}
                  disabled={disabled}
                  onClick={() => !on && !disabled && setDefault.mutate({ capability: "music", providerId: p.id })}
                  className={cx(
                    "flex items-start gap-2.5 rounded-[8px] border px-3 py-2 text-left transition-colors",
                    on ? "border-accent bg-accent-soft" : "border-border hover:bg-hover",
                    disabled && "cursor-not-allowed opacity-65 hover:bg-transparent",
                  )}
                >
                  <span
                    aria-hidden
                    className={cx(
                      "mt-[3px] size-[12px] flex-none rounded-full border",
                      on ? "border-accent bg-accent" : "border-border-strong",
                    )}
                  />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="flex items-center gap-2 text-13 font-medium text-fg">
                      {p.label}
                      {p.coming_soon && <span className="rounded bg-selected px-1.5 py-px text-11 text-fg-tertiary">Soon</span>}
                    </span>
                    <span className="text-12 text-fg-tertiary">
                      {p.available ? (p.description ?? "Ready for music generation.") : (p.unavailable_reason ?? "Not configured yet.")}
                    </span>
                  </span>
                </button>
              );
            })}
          </div>
          {setDefault.error && <p role="alert" className="text-12 text-pill-blocked-fg">{setDefault.error.message}</p>}
        </div>
      )}

      <div className="flex flex-col gap-3">
        {data.providers.map((p) => (
          <ProviderCard key={p.id} provider={p} />
        ))}
      </div>
    </div>
  );
}

function ProviderCard({ provider }: { provider: MediaProvider }) {
  const save = useUpdateMediaProvider();
  const clearSecret = useClearMediaProviderSecret();
  const check = useCheckMediaProvider();

  const [draftSettings, setDraftSettings] = useState<Record<string, string>>({});
  const [draftSecrets, setDraftSecrets] = useState<Record<string, string>>({});
  const [checkResult, setCheckResult] = useState<MediaProviderCheckResponse | null>(null);

  const settings = effectiveSettings(provider, draftSettings);
  const status = providerStatus(provider);
  const visibleFields = provider.fields.filter((f) => isFieldVisible(f, settings));
  const hasDirty = Object.keys(draftSettings).length > 0 || Object.values(draftSecrets).some((v) => v.trim().length > 0);
  const busy = save.isPending || clearSecret.isPending || check.isPending;

  function onSave() {
    save.mutate(
      { id: provider.id, body: buildProviderPatch(provider, draftSettings, draftSecrets) },
      {
        onSuccess: () => {
          setDraftSettings({});
          setDraftSecrets({});
          setCheckResult(null);
          toast(`Saved ${provider.label}`);
        },
      },
    );
  }

  function onClearSecret(field: string) {
    clearSecret.mutate(
      { id: provider.id, field },
      {
        onSuccess: () => {
          setDraftSecrets((prev) => {
            const next = { ...prev };
            delete next[field];
            return next;
          });
          setCheckResult(null);
          toast(`Removed ${provider.label} key`);
        },
      },
    );
  }

  function onCheck() {
    setCheckResult(null);
    check.mutate(provider.id, {
      onSuccess: (res) => setCheckResult(res),
    });
  }

  return (
    <Card
      as="article"
      title={
        <span className="flex flex-wrap items-center gap-2">
          <span>{provider.label}</span>
          {provider.capabilities.map((cap) => (
            <span key={cap} className="rounded bg-selected px-1.5 py-px text-11 font-normal text-fg-secondary">
              {CAPABILITY_LABEL[cap] ?? cap}
            </span>
          ))}
        </span>
      }
      action={<span className={cx("rounded-full px-2 py-0.5 text-11 font-medium", STATUS_PILL[status.tone])}>{status.label}</span>}
    >
      {provider.description && <p className="mb-3 text-13 text-fg-secondary">{provider.description}</p>}

      {provider.coming_soon ? (
        <p className="text-12 text-fg-tertiary">{provider.unavailable_reason ?? "Support for this provider will arrive in a future release."}</p>
      ) : (
        <div className="flex flex-col gap-3.5">
          {visibleFields.map((field) => (
            <ProviderField
              key={field.key}
              providerId={provider.id}
              field={field}
              value={field.kind === "secret" ? (draftSecrets[field.key] ?? "") : (settings[field.key] ?? "")}
              secretSet={!!provider.secrets_set[field.key]}
              disabled={busy}
              onSettingChange={(v) => {
                setCheckResult(null);
                setDraftSettings((prev) => ({ ...prev, [field.key]: v }));
              }}
              onSecretChange={(v) => {
                setCheckResult(null);
                setDraftSecrets((prev) => ({ ...prev, [field.key]: v }));
              }}
              onClearSecret={() => onClearSecret(field.key)}
            />
          ))}

          {(save.error || clearSecret.error || check.error) && (
            <p role="alert" className="text-12 text-pill-blocked-fg">
              {(save.error ?? clearSecret.error ?? check.error)?.message}
            </p>
          )}

          {checkResult && (
            <div
              role={checkResult.ok ? "status" : "alert"}
              className={cx(
                "rounded-md border px-3 py-2 text-12",
                checkResult.ok
                  ? "border-state-done/35 bg-pill-done-bg text-pill-done-fg"
                  : "border-state-blocked/35 bg-pill-blocked-bg text-pill-blocked-fg",
              )}
            >
              <span className="font-medium">{checkResult.ok ? "Connection verified: " : "Connection check failed: "}</span>
              <span>{checkResult.message}</span>
            </div>
          )}

          <div className="flex flex-wrap items-center justify-end gap-2 pt-1">
            <Button variant="secondary" disabled={busy || !provider.available || hasDirty} onClick={onCheck}>
              {check.isPending ? "Checking…" : "Test connection"}
            </Button>
            <Button variant="primary" disabled={busy || !hasDirty} onClick={onSave}>
              {save.isPending ? "Saving…" : "Save"}
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}

function ProviderField({
  providerId,
  field,
  value,
  secretSet,
  disabled,
  onSettingChange,
  onSecretChange,
  onClearSecret,
}: {
  providerId: string;
  field: MediaFieldSpec;
  value: string;
  secretSet: boolean;
  disabled: boolean;
  onSettingChange: (v: string) => void;
  onSecretChange: (v: string) => void;
  onClearSecret: () => void;
}) {
  const id = `media-${providerId}-${field.key}`;

  if (field.kind === "segmented") {
    const opts = (field.options ?? []).map((o) => ({ value: o.value, label: o.label }));
    return (
      <Field label={field.label} hint={field.help}>
        <div>
          <Segmented label={field.label} options={opts} value={value} onChange={onSettingChange} />
        </div>
      </Field>
    );
  }

  if (field.kind === "select") {
    return (
      <Field label={field.label} htmlFor={id} hint={field.help}>
        <select
          id={id}
          disabled={disabled}
          value={value}
          onChange={(e) => onSettingChange(e.target.value)}
          className="h-[30px] w-full rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg focus:border-accent focus:outline-none disabled:opacity-50"
        >
          {(field.options ?? []).map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </Field>
    );
  }

  if (field.kind === "secret") {
    const placeholder = secretSet ? "•••••••• (configured — enter new key to replace)" : (field.placeholder ?? "Enter key…");
    return (
      <Field label={field.label} htmlFor={id} hint={field.help}>
        <div className="flex items-center gap-2">
          <TextInput
            id={id}
            type="password"
            mono
            autoComplete="off"
            disabled={disabled}
            value={value}
            placeholder={placeholder}
            onChange={(e) => onSecretChange(e.target.value)}
            className="flex-1"
          />
          {secretSet && (
            <Button variant="secondary" disabled={disabled} onClick={onClearSecret}>
              Clear
            </Button>
          )}
        </div>
      </Field>
    );
  }

  return (
    <Field label={field.label} htmlFor={id} hint={field.help}>
      <TextInput
        id={id}
        type="text"
        disabled={disabled}
        value={value}
        placeholder={field.placeholder}
        onChange={(e) => onSettingChange(e.target.value)}
      />
    </Field>
  );
}
