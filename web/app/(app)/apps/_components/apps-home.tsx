"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { Dialog } from "radix-ui";
import { useRef, useState, type FormEvent } from "react";
import { useNativeContextMenu } from "@/lib/native-shell/hooks";
import { Content, TopBar } from "@/components/shell/topbar";
import { Button, IconButton } from "@/components/ui/button";
import { confirmAction } from "@/components/ui/confirm";
import { Segmented } from "@/components/ui/controls";
import { Icon, type IconName } from "@/components/ui/icon";
import { PageHeader } from "@/components/ui/page-header";
import { Banner, Card, EmptyState, Field, Skeleton, TextInput } from "@/components/ui/primitives";
import { useCreateCustomApp, useCustomApps, useDeleteCustomApp, type CustomAppSummary } from "@/lib/api/custom-app-hooks";
import { CUSTOM_APP_ICONS, resolveAppIcon, slugifyAppName, validateCustomAppSlug, type CustomAppIcon } from "@/lib/custom-app-bridge";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { toast } from "@/lib/toast";

type StarterKey = "blank" | "tracker" | "ledger";

const STARTERS: ReadonlyArray<{ key: StarterKey; label: string; icon: IconName; detail: string }> = [
  { key: "blank", label: "Blank", icon: "code", detail: "Clean React + TypeScript + SQLite canvas ready for custom views." },
  { key: "tracker", label: "Tracker", icon: "tickets", detail: "Status views, quick entry, and SQLite persistence out of the box." },
  { key: "ledger", label: "Ledger", icon: "dollar", detail: "Accounts, transactions, and category summaries in embedded SQLite." },
];

const STARTER_DEFAULT_ICON: Record<StarterKey, CustomAppIcon> = {
  blank: "dashboard",
  tracker: "tickets",
  ledger: "dollar",
};

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace(/\.0$/, "")} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function AppsHome() {
  const list = useCustomApps();
  const [dialogOpen, setDialogOpen] = useState(false);
  const [initialTemplate, setInitialTemplate] = useState<StarterKey>("blank");

  const openNew = (template: StarterKey) => {
    setInitialTemplate(template);
    setDialogOpen(true);
  };

  const apps = list.data?.apps ?? [];

  return (
    <>
      <TopBar
        crumbs={[{ label: "Custom Apps" }]}
        nativeActions={[{ id: "apps.new", label: "New app", kind: "button", icon: "plus", showsLabel: true, accent: true, run: () => openNew("blank") }]}
      />
      <Content>
        <div className="flex flex-col gap-7">
          <PageHeader
            title="Custom Apps"
            description="Sandboxed React + SQLite apps inside your workbench, wired to Vesper APIs, MCP connectors, and your personas."
          />

          {list.isError ? (
            <Banner tone="blocked" title="Couldn’t load custom apps">
              {errorText(list.error)}
            </Banner>
          ) : list.isPending ? (
            <div className="grid gap-3.5 sm:grid-cols-2 lg:grid-cols-3">
              {[0, 1, 2].map((i) => (
                <Skeleton key={i} className="h-[148px] w-full rounded-xl" />
              ))}
            </div>
          ) : apps.length > 0 ? (
            <section aria-label="Your apps" className="flex flex-col gap-3">
              <div className="grid gap-3.5 sm:grid-cols-2 lg:grid-cols-3">
                {apps.map((app) => (
                  <CustomAppCard key={app.id} app={app} />
                ))}
              </div>
            </section>
          ) : (
            <Card>
              <EmptyState
                icon="dashboard"
                title="Build your first custom app"
                actions={
                  <Button variant="primary" icon="plus" onClick={() => openNew("blank")}>
                    Create custom app
                  </Button>
                }
              >
                Start from a template or ask a persona in Chat to scaffold an app with its own SQLite tables and views.
              </EmptyState>
            </Card>
          )}

          <section aria-label="Starter templates" className="flex flex-col gap-3">
            <h2 className="text-11 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">Starter templates</h2>
            <div className="grid gap-3 sm:grid-cols-3">
              {STARTERS.map((s) => (
                <button
                  key={s.key}
                  type="button"
                  onClick={() => openNew(s.key)}
                  data-testid={`starter-${s.key}`}
                  className="flex flex-col items-start gap-2 rounded-xl border border-border bg-surface p-4 text-left transition-colors hover:border-border-strong hover:bg-hover"
                >
                  <span className="flex items-center gap-2 text-14 font-semibold text-fg">
                    <span className="grid size-7 place-items-center rounded-md border border-border bg-surface-raised text-fg-2">
                      <Icon name={s.icon} size={15} />
                    </span>
                    {s.label}
                  </span>
                  <span className="text-13 text-fg-secondary">{s.detail}</span>
                  <span className="mt-auto pt-1 text-12 font-medium text-accent">Start with {s.label} →</span>
                </button>
              ))}
            </div>
          </section>
        </div>
      </Content>

      {dialogOpen && (
        <NewCustomAppDialog
          key={initialTemplate}
          initialTemplate={initialTemplate}
          onClose={() => setDialogOpen(false)}
        />
      )}
    </>
  );
}

function CustomAppCard({ app }: { app: CustomAppSummary }) {
  const router = useRouter();
  const deleteApp = useDeleteCustomApp();
  const cardRef = useRef<HTMLElement>(null);
  const href = `/apps/${app.slug}`;
  const caps = Object.entries(app.capabilities ?? {}).filter(([, mode]) => mode !== "denied");

  const handleDelete = async () => {
    const ok = await confirmAction({
      title: `Delete ${app.name}?`,
      body: "This permanently deletes the app, its version history, and its embedded SQLite database.",
      confirmLabel: "Delete",
    });
    if (!ok) return;
    deleteApp.mutate(app.slug, {
      onSuccess: () => toast({ id: `del-${app.slug}`, title: `Deleted ${app.name}` }),
      onError: (e) => toast({ id: `del-${app.slug}`, tone: "error", title: `Couldn’t delete ${app.name}`, description: errorText(e) }),
    });
  };

  useNativeContextMenu(
    cardRef,
    () => [
      { id: "open", label: `Open ${app.name}`, icon: "dashboard", onSelect: () => router.push(href) },
      { id: "open-tab", label: "Open in new tab", icon: "external", onSelect: () => window.open(href, "_blank") },
      { id: "sep-copy", separator: true },
      {
        id: "copy-link",
        label: "Copy link",
        icon: "link",
        onSelect: () => {
          const full = new URL(href, window.location.href).href;
          void navigator.clipboard?.writeText(full).then(() => toast({ title: "Link copied", tone: "success" }));
        },
      },
      { id: "sep-del", separator: true },
      { id: "delete", label: `Delete ${app.name}`, icon: "trash", destructive: true, disabled: deleteApp.isPending, onSelect: () => void handleDelete() },
    ],
    { links: "menu" },
  );

  return (
    <article
      ref={cardRef}
      data-testid={`custom-app-card-${app.slug}`}
      className="flex flex-col gap-3 rounded-xl border border-border bg-surface p-4 transition-colors hover:border-border-strong"
    >
      <div className="flex items-start gap-3">
        <span className="grid size-9 flex-none place-items-center rounded-lg border border-border bg-surface-raised text-fg-2">
          <Icon name={resolveAppIcon(app.icon)} size={17} />
        </span>
        <div className="min-w-0 flex-1">
          <Link href={`/apps/${app.slug}`} className="block truncate text-14 font-semibold text-fg hover:text-accent">
            {app.name}
          </Link>
          <span className="block truncate font-mono text-11 text-fg-tertiary">/apps/{app.slug}</span>
        </div>
        <IconButton
          icon="trash"
          label={`Delete ${app.name}`}
          disabled={deleteApp.isPending}
          onClick={() => void handleDelete()}
          className="text-fg-tertiary hover:text-pill-blocked-fg"
        />
      </div>

      <p className="line-clamp-2 min-h-[36px] text-13 text-fg-secondary">{app.description || "Custom workbench app"}</p>

      {caps.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {caps.slice(0, 4).map(([cap, mode]) => (
            <span
              key={cap}
              className="inline-flex items-center rounded-sm border border-border-subtle bg-surface-sunken px-1.5 py-0.5 font-mono text-11 text-fg-secondary"
            >
              {cap}
              {mode === "requires_approval" ? " (ask)" : ""}
            </span>
          ))}
          {caps.length > 4 && (
            <span className="inline-flex items-center rounded-sm border border-border-subtle px-1.5 py-0.5 text-11 text-fg-tertiary">
              +{caps.length - 4}
            </span>
          )}
        </div>
      )}

      <div className="mt-auto flex items-center justify-between gap-2 border-t border-border-subtle pt-2.5 text-12 text-fg-tertiary">
        <span className="truncate font-mono text-11">
          v{app.current_seq} · SQLite · {formatBytes(app.db_size_bytes)} · {ago(app.updated_at)}
        </span>
        <Link href={`/apps/${app.slug}`} className="flex-none font-medium text-accent hover:underline">
          Open →
        </Link>
      </div>
    </article>
  );
}

function NewCustomAppDialog({ initialTemplate, onClose }: { initialTemplate: StarterKey; onClose: () => void }) {
  const router = useRouter();
  const createApp = useCreateCustomApp();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugTouched, setSlugTouched] = useState(false);
  const [description, setDescription] = useState("");
  const [icon, setIcon] = useState<CustomAppIcon>(STARTER_DEFAULT_ICON[initialTemplate]);
  const [template, setTemplate] = useState<StarterKey>(initialTemplate);

  const effectiveSlug = slug.trim();
  const slugError = effectiveSlug ? validateCustomAppSlug(effectiveSlug) : null;
  const canSubmit = !!name.trim() && !!effectiveSlug && !slugError && !createApp.isPending;

  const handleNameChange = (nextName: string) => {
    setName(nextName);
    if (!slugTouched) setSlug(slugifyAppName(nextName));
  };

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!canSubmit) return;
    createApp.mutate(
      {
        name: name.trim(),
        slug: effectiveSlug,
        description: description.trim() || undefined,
        icon,
        template,
      },
      {
        onSuccess: (created) => {
          onClose();
          router.push(`/apps/${created.slug}`);
        },
      },
    );
  };

  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-[8vh] z-50 flex max-h-[86vh] w-[min(560px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-y-auto rounded-2xl border border-border-float bg-surface-raised p-6 shadow-[var(--shadow-float)] outline-none"
        >
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="flex items-center justify-between">
              <Dialog.Title className="text-18 font-semibold text-fg">New custom app</Dialog.Title>
              <Dialog.Close asChild>
                <IconButton icon="x" label="Close dialog" />
              </Dialog.Close>
            </div>

            <Field label="Starter template">
              <Segmented
                label="Starter template"
                layout="fill"
                value={template}
                onChange={(next) => {
                  setTemplate(next);
                  setIcon(STARTER_DEFAULT_ICON[next]);
                }}
                options={STARTERS.map((s) => ({ value: s.key, label: s.label }))}
              />
            </Field>

            <Field label="Name" htmlFor="custom-app-name">
              <TextInput
                id="custom-app-name"
                value={name}
                maxLength={80}
                autoFocus
                placeholder={template === "ledger" ? "Finance" : template === "tracker" ? "Reading Tracker" : "My App"}
                disabled={createApp.isPending}
                onChange={(e) => handleNameChange(e.target.value)}
              />
            </Field>

            <Field
              label="Slug"
              htmlFor="custom-app-slug"
              hint={
                slugError ? (
                  <span className="text-pill-blocked-fg">{slugError}</span>
                ) : (
                  "URL path under /apps/ and space identifier."
                )
              }
            >
              <TextInput
                id="custom-app-slug"
                prefix="/apps/"
                mono
                value={slug}
                maxLength={48}
                placeholder="finance"
                disabled={createApp.isPending}
                onChange={(e) => {
                  setSlugTouched(true);
                  setSlug(e.target.value.toLowerCase());
                }}
              />
            </Field>

            <Field label="Description" htmlFor="custom-app-description">
              <TextInput
                id="custom-app-description"
                value={description}
                maxLength={500}
                placeholder="Optional one-line summary of what this app tracks or does"
                disabled={createApp.isPending}
                onChange={(e) => setDescription(e.target.value)}
              />
            </Field>

            <Field label="Icon">
              <div role="radiogroup" aria-label="App icon" className="grid grid-cols-6 gap-1.5 sm:grid-cols-12">
                {CUSTOM_APP_ICONS.map((ic) => {
                  const selected = icon === ic;
                  return (
                    <button
                      key={ic}
                      type="button"
                      role="radio"
                      aria-checked={selected}
                      aria-label={ic}
                      title={ic}
                      disabled={createApp.isPending}
                      onClick={() => setIcon(ic)}
                      className={cx(
                        "grid h-9 place-items-center rounded-md border transition-colors",
                        selected
                          ? "border-accent bg-selected text-accent"
                          : "border-border bg-surface text-fg-secondary hover:bg-hover hover:text-fg",
                      )}
                    >
                      <Icon name={ic} size={16} />
                    </button>
                  );
                })}
              </div>
            </Field>

            {createApp.isError && (
              <Banner tone="blocked" title="Couldn’t create app">
                {errorText(createApp.error)}
              </Banner>
            )}

            <div className="mt-2 flex justify-end gap-2">
              <Dialog.Close asChild>
                <Button variant="secondary" disabled={createApp.isPending}>
                  Cancel
                </Button>
              </Dialog.Close>
              <Button type="submit" variant="primary" disabled={!canSubmit}>
                {createApp.isPending ? "Creating…" : "Create app"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
