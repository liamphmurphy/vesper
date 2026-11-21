"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import { useLocation } from "react-router";
import type { Schemas } from "@/lib/api/client";
import { useBootstrap, useMemories, useRunnerStatus, useSecrets, useUpdateRunnerSettings } from "@/lib/api/hooks";
import { usePersonas, type Persona } from "@/lib/api/persona-hooks";
import { useApiSecrets } from "@/lib/api/secret-hooks";
import { useSpaces } from "@/lib/api/space-hooks";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { pageOrigin } from "@/lib/native-shell/models/common";
import {
  buildSettingsNavModel,
  NEW_PERSONA_ACTION,
  RETRY_PERSONAS_ACTION,
  SETTINGS_SEARCH_ID,
  type SettingsHealth,
} from "@/lib/native-shell/models/settings";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import { MAX_PERSONAS, sortPersonas } from "@/lib/persona-ui";
import { missingConnections } from "@/lib/settings";
import {
  resolveSettingsRoute,
  selectedNavId,
  settingsHref,
  type SecretsTab,
  type SettingsRoute,
} from "@/lib/settings-nav";
import { toast } from "@/lib/toast";
import { HumanAvatar } from "@/components/domain/avatars";
import { SetupChecklist } from "@/components/domain/setup";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Content, TopBar, type Crumb } from "@/components/shell/topbar";
import { Button, ButtonLink } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { PageHeader } from "@/components/ui/page-header";
import { Banner, Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { PersonaEditor } from "../chat/_components/persona-editor";
import { ApiSecretsSection } from "../customization/api-secrets-section";
import { ConnectorsSection, PersonaConnectors } from "../customization/connectors-section";
import { ImportView, MemorySection, useMemoryExport } from "../customization/memory-section";
import { PersonaModelSection } from "../customization/persona-model";
import { DeleteDialog, PersonaProfile } from "../customization/persona-profile";
import { PersonaWorkSection } from "../customization/persona-work";
import { PersonasList } from "../customization/personas-list";
import { ProfileSection } from "../customization/profile-section";
import { SpaceTile } from "../spaces/_components/space-parts";
import { AppearanceSection } from "./appearance-section";
import { BackupSection } from "./backup-section";
import { DevWorkspaceSection } from "./dev-workspace-section";
import { ImageEngineSection } from "./image-engine-section";
import { MediaProvidersSection } from "./media-providers-section";
import { RepositorySourcesSection } from "./repositories-section";
import { SecretsSection } from "./secrets-section";
import { SignInSection, useAuthStatus } from "./sign-in-section";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
const noSubscribe = () => () => {};

function subscribeHash(cb: () => void) {
  window.addEventListener("hashchange", cb);
  return () => window.removeEventListener("hashchange", cb);
}

const SECTION_TITLES: Record<SettingsRoute["section"], string> = {
  you: "You",
  appearance: "Appearance",
  memory: "Memory",
  personas: "Personas",
  persona: "Persona",
  secrets: "Secrets & Credentials",
  connectors: "Connectors",
  repositories: "Repositories",
  workspace: "Workspace",
  runners: "Runners",
  "dev-workspace": "Dev workspace",
  spaces: "Spaces",
  "sign-in": "Sign-in",
  backup: "Backup & move",
};

const SIMPLE_NAV_IDS = new Set([
  "you",
  "appearance",
  "memory",
  "secrets",
  "connectors",
  "repositories",
  "workspace",
  "runners",
  "dev-workspace",
  "spaces",
  "sign-in",
  "backup",
]);

function PlainHeader({ lead, title, detail, actions }: { lead: ReactNode; title: string; detail: string; actions?: ReactNode }) {
  return (
    <header className="flex flex-wrap items-center gap-4">
      {lead}
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <h1 className="truncate type-display text-fg">{title}</h1>
        <p className="text-14 text-fg-secondary">{detail}</p>
      </div>
      {actions}
    </header>
  );
}

/**
 * Unified Settings: Personal, Personas, Integrations, and System in one grouped sidebar
 * with focused per-section master-detail screens.
 */
export function SettingsScreen() {
  const router = useRouter();
  const search = useSearchParams();
  const loc = useLocation();

  const mounted = useSyncExternalStore(noSubscribe, () => true, () => false);
  const winHash = useSyncExternalStore(subscribeHash, () => window.location.hash, () => "");
  const hash = loc.hash || winHash;

  const route = useMemo(() => resolveSettingsRoute(search, hash), [search, hash]);
  const activeId = selectedNavId(route);

  const boot = useBootstrap();
  const secrets = useSecrets();
  const runner = useRunnerStatus();
  const auth = useAuthStatus();
  const list = usePersonas();
  const count = useMemories();

  const all = useMemo(() => list.data?.personas ?? [], [list.data?.personas]);
  const personas = useMemo(() => sortPersonas(all), [all]);
  const selectedPersona = route.section === "persona" ? personas.find((p) => p.id === route.personaId) : undefined;

  const [filter, setFilter] = useState("");
  const [editing, setEditing] = useState<Persona | "new" | null>(null);
  const [deleting, setDeleting] = useState<Persona | null>(null);
  const [importingFor, setImportingFor] = useState<string | null>(null);
  const [editingProfileFor, setEditingProfileFor] = useState<string | null>(null);

  const importing = route.section === "memory" && importingFor === activeId;
  const editingProfile = route.section === "you" && editingProfileFor === activeId;

  const memoryExport = useMemoryExport();
  const exportError = memoryExport.err;
  useEffect(() => {
    if (exportError) toast({ title: exportError, tone: "error" });
  }, [exportError]);

  const scrollAnchor = (route.section === "workspace" || route.section === "spaces") ? route.anchor : undefined;
  useEffect(() => {
    if (!mounted || !scrollAnchor) return;
    document.getElementById(scrollAnchor)?.scrollIntoView();
  }, [mounted, scrollAnchor]);

  const missing = secrets.data ? missingConnections(secrets.data.secrets).length : 0;
  const secretsHealth: SettingsHealth = !secrets.data ? "unknown" : missing || !secrets.data.key_configured ? "attention" : "ok";
  const workspaceHealth: SettingsHealth = !secrets.data ? "unknown" : secrets.data.key_configured ? "ok" : "attention";
  const runnersHealth: SettingsHealth = !runner.data ? "unknown" : runner.data.online ? "ok" : runner.data.starting ? "unknown" : "attention";
  const signInHealth: SettingsHealth = !auth.data ? "unknown" : auth.data.password_set ? "ok" : "attention";

  const total = count.data?.total;
  const me = boot.data?.me;

  if (!mounted) {
    return (
      <section aria-label="Settings">
        <TopBar crumbs={[{ label: "Settings" }]} />
        <Content>
          <div aria-busy className="flex flex-col gap-6">
            <PageHeader title="Settings" />
            <Skeleton className="h-40 max-w-[1020px]" />
          </div>
        </Content>
      </section>
    );
  }

  const navModel = buildSettingsNavModel({
    me,
    personas: personas.map((p) => ({
      id: p.id,
      name: p.name,
      handle: p.handle,
      color: p.color,
      avatar_url: p.avatar_url,
      is_default: p.is_default,
    })),
    personasState: list.isError ? "error" : !list.data ? "loading" : "ready",
    canAddPersona: all.length < MAX_PERSONAS,
    memoryTotal: total,
    health: {
      secrets: secretsHealth,
      missingCredentials: missing,
      workspace: workspaceHealth,
      runners: runnersHealth,
      signIn: signInHealth,
    },
    selectedId: activeId,
    filter,
    origin: pageOrigin(),
  });

  const handleNativeCommand = (cmd: NativeCommand) => {
    if (cmd.type === "nav.search") {
      if (cmd.searchId === SETTINGS_SEARCH_ID) setFilter(cmd.value);
      return;
    }
    if (cmd.type === "nav.action") {
      if (cmd.actionId === NEW_PERSONA_ACTION) setEditing("new");
      else if (cmd.actionId === RETRY_PERSONAS_ACTION) void list.refetch();
      return;
    }
    if (cmd.type !== "nav.activate") return;
    const id = cmd.itemId;
    if (id === "all-personas") router.push(settingsHref({ section: "personas", personaFilter: "all" }));
    else if (id.startsWith("persona:")) router.push(settingsHref({ section: "persona", personaId: id.slice("persona:".length) }));
    else if (id === "secrets") router.push(settingsHref({ section: "secrets", secretsTab: "provider" }));
    else if (SIMPLE_NAV_IDS.has(id)) {
      router.push(settingsHref({ section: id as Exclude<SettingsRoute["section"], "personas" | "persona" | "secrets"> }));
    }
  };

  const sectionTitle = route.section === "persona" ? (selectedPersona?.name ?? "Persona") : SECTION_TITLES[route.section];
  const crumbs: Crumb[] = route.section === "persona"
    ? [
        { label: "Settings", href: "/settings" },
        { label: "Personas", href: settingsHref({ section: "personas", personaFilter: "all" }) },
        { label: selectedPersona?.name ?? "Persona" },
      ]
    : [{ label: "Settings", href: "/settings" }, { label: sectionTitle }];

  const nativeActions =
    route.section === "memory"
      ? [
          {
            id: "custom.import",
            label: "Import",
            kind: "toggle" as const,
            icon: "upload",
            showsLabel: true,
            on: importing,
            run: () => setImportingFor((v) => (v === activeId ? null : activeId)),
          },
          {
            id: "custom.export",
            label: "Export",
            kind: "menu" as const,
            icon: "download",
            showsLabel: true,
            disabled: memoryExport.busy,
            menu: [
              { id: "export.json", label: "JSON (all entries)", run: () => void memoryExport.run("json") },
              { id: "export.md", label: "Markdown (all entries)", run: () => void memoryExport.run("md") },
            ],
          },
        ]
      : route.section === "workspace"
        ? [
            { id: "settings.setup", label: "Run setup again", kind: "button" as const, showsLabel: true, run: () => router.push("/chat?new&setup") },
            { id: "settings.checklist", label: "Open setup checklist", kind: "button" as const, showsLabel: true, run: () => router.push("/setup") },
          ]
        : undefined;

  const wideBody =
    route.section === "you" ||
    route.section === "memory" ||
    route.section === "personas" ||
    route.section === "persona" ||
    route.section === "connectors" ||
    route.section === "spaces" ||
    (route.section === "secrets" && route.secretsTab === "api");

  return (
    <section aria-label="Settings">
      <NavigatorPortal native={{ model: navModel, onCommand: handleNativeCommand }} />
      <TopBar
        crumbs={crumbs}
        nativeTitle={{
          title: sectionTitle,
          ...(route.section === "memory" && total !== undefined ? { subtitle: `${total} entries` } : {}),
        }}
        nativeActions={nativeActions}
      />
      <Content>
        <div className="flex flex-col gap-5">
          <div className={cx("flex min-w-0 flex-col gap-6", wideBody ? "max-w-[1020px]" : "max-w-[820px]")}>
            {route.section === "you" && (
              <div id="you" className="flex flex-col gap-5">
                <PlainHeader
                  lead={<HumanAvatar name={me?.name ?? "You"} initials={me?.initials} color={me?.avatar_color} src={me?.avatar_url} size={72} label={false} />}
                  title={me?.name ?? "You"}
                  detail={[me?.role_title, "Your profile and what your personas remember about you."].filter(Boolean).join(" · ")}
                  actions={
                    <Button variant="secondary" aria-pressed={editingProfile} onClick={() => setEditingProfileFor((v) => (v === activeId ? null : activeId))}>
                      {editingProfile ? "Done" : "Edit profile"}
                    </Button>
                  }
                />
                {editingProfile && (
                  <section aria-label="Profile">
                    <ProfileSection />
                  </section>
                )}
                <MemorySection key="person" whose="person" heading="About you" />
              </div>
            )}

            {route.section === "appearance" && (
              <section id="appearance" aria-labelledby="appearance-title" className="flex flex-col gap-3">
                <div>
                  <h1 id="appearance-title" className="type-display text-fg">Appearance</h1>
                  <p className="mt-1 text-14 text-fg-secondary">Theme, text size, harness activity, and palette colors.</p>
                </div>
                <AppearanceSection />
              </section>
            )}

            {route.section === "memory" && (
              <section id="memory" aria-label="Memory" className="flex flex-col gap-5">
                {importing ? (
                  <div className="mx-auto w-full max-w-2xl">
                    <ImportView onClose={() => setImportingFor(null)} />
                  </div>
                ) : (
                  <>
                    <PlainHeader
                      lead={
                        <span className="grid size-[72px] flex-none place-items-center rounded-full bg-selected text-fg-secondary">
                          <Icon name="bookmark" size={28} />
                        </span>
                      }
                      title="Memory"
                      detail="Every memory: about you, and each persona’s and space’s own."
                    />
                    <MemorySection key="all" whose="" focus={route.focusId} heading="All memories" />
                  </>
                )}
              </section>
            )}

            {route.section === "personas" && (
              <div id="personas">
                <PersonasList
                  key={route.personaFilter}
                  personas={all}
                  filter={route.personaFilter}
                  onOpen={(id) => router.push(settingsHref({ section: "persona", personaId: id }))}
                  onNew={() => setEditing("new")}
                  canAdd={all.length < MAX_PERSONAS}
                />
              </div>
            )}

            {route.section === "persona" && (
              <div id="persona" className="flex flex-col gap-5">
                {list.isPending ? (
                  <Skeleton className="h-40" />
                ) : list.isError ? (
                  <Banner tone="blocked" title="Couldn’t load persona" actions={<Button variant="outline" onClick={() => void list.refetch()}>Retry</Button>}>
                    {errorText(list.error)}
                  </Banner>
                ) : selectedPersona ? (
                  <PersonaDetailView
                    persona={selectedPersona}
                    onEdit={() => setEditing(selectedPersona)}
                    onDelete={() => setDeleting(selectedPersona)}
                  />
                ) : (
                  <PersonasList
                    personas={all}
                    filter="all"
                    onOpen={(id) => router.push(settingsHref({ section: "persona", personaId: id }))}
                    onNew={() => setEditing("new")}
                    canAdd={all.length < MAX_PERSONAS}
                  />
                )}
              </div>
            )}

            {route.section === "secrets" && (
              <SecretsView
                secretsTab={route.secretsTab}
                secretId={route.secretId}
                personas={personas}
                missing={missing}
                providerSecrets={secrets.data}
                onTabChange={(tab) => router.replace(settingsHref({ section: "secrets", secretsTab: tab }), { scroll: false })}
              />
            )}

            {route.section === "connectors" && (
              <div id="connectors">
                <ConnectorsSection personas={personas} />
              </div>
            )}

            {route.section === "repositories" && (
              <section id="repositories" aria-labelledby="repositories-title" className="flex flex-col gap-3">
                <h1 id="repositories-title" className="type-display text-fg">Repositories &amp; GitHub owners</h1>
                <RepositorySourcesSection />
              </section>
            )}

            {route.section === "workspace" && (
              <div id="workspace" className="flex flex-col gap-8">
                <section aria-labelledby="workspace-title" className="flex flex-col gap-3">
                  <div>
                    <h1 id="workspace-title" className="type-display text-fg">Workspace</h1>
                    <p className="mt-1 text-14 text-fg-secondary">Shared by every space. Secret encryption is configured on the API server.</p>
                  </div>
                  <SetupChecklist />
                  <WorkspaceSection />
                </section>
                <section id="images" aria-labelledby="images-title" className="flex scroll-mt-6 flex-col gap-3 border-t border-border-subtle pt-6">
                  <div>
                    <h2 id="images-title" className="type-title">Image engine</h2>
                    <p className="mt-1 text-14 text-fg-secondary">Which harness makes the images personas and workflows ask for.</p>
                  </div>
                  <ImageEngineSection />
                </section>
                <section id="media" aria-labelledby="media-title" className="flex scroll-mt-6 flex-col gap-3 border-t border-border-subtle pt-6">
                  <div>
                    <h2 id="media-title" className="type-title">Media providers</h2>
                    <p className="mt-1 text-14 text-fg-secondary">Configure cloud or local providers for music generation (and future audio tools).</p>
                  </div>
                  <MediaProvidersSection />
                </section>
              </div>
            )}

            {route.section === "runners" && (
              <section id="runners" aria-labelledby="runners-title" className="flex flex-col gap-3">
                <div>
                  <h1 id="runners-title" className="type-display text-fg">Runner backends</h1>
                  <p className="mt-1 text-14 text-fg-secondary">
                    Reported by each runner’s heartbeat. Set by environment variables on the runner process; restart the runner to change them.
                  </p>
                </div>
                <RunnerSection />
              </section>
            )}

            {route.section === "dev-workspace" && (
              <section id="dev-workspace" aria-labelledby="dev-workspace-title" className="flex flex-col gap-3">
                <div>
                  <h1 id="dev-workspace-title" className="type-display text-fg">Dev workspace</h1>
                  <p className="mt-1 text-14 text-fg-secondary">
                    Persistent Nix + LazyVim container for inspecting and testing agent branches. No container runs until enabled.
                  </p>
                </div>
                <DevWorkspaceSection />
              </section>
            )}

            {route.section === "spaces" && <SpacesView spaceId={route.spaceId} />}

            {route.section === "sign-in" && (
              <section id="sign-in" aria-labelledby="sign-in-title" className="flex flex-col gap-3">
                <div>
                  <h1 id="sign-in-title" className="type-display text-fg">Sign-in</h1>
                  <p className="mt-1 text-14 text-fg-secondary">How you get into Vesper from a browser that isn’t signed in.</p>
                </div>
                <SignInSection />
              </section>
            )}

            {route.section === "backup" && (
              <section id="backup" aria-labelledby="backup-title" className="flex flex-col gap-3">
                <div>
                  <h1 id="backup-title" className="type-display text-fg">Backup &amp; move</h1>
                  <p className="mt-1 text-14 text-fg-secondary">Take everything with you to another machine.</p>
                </div>
                <BackupSection />
              </section>
            )}
          </div>
        </div>
      </Content>
      {editing && <PersonaEditor key={editing === "new" ? "new" : editing.id} persona={editing} onClose={() => setEditing(null)} />}
      {deleting && <DeleteDialog persona={deleting} all={all} onClose={() => setDeleting(null)} />}
    </section>
  );
}

function SecretsView({
  secretsTab,
  secretId,
  personas,
  missing,
  providerSecrets,
  onTabChange,
}: {
  secretsTab: SecretsTab;
  secretId?: string;
  personas: Persona[];
  missing: number;
  providerSecrets?: { key_configured: boolean };
  onTabChange: (tab: SecretsTab) => void;
}) {
  const apiSecrets = useApiSecrets();
  const keyConfigured = providerSecrets?.key_configured ?? apiSecrets.data?.key_configured;
  const apiCount = apiSecrets.data?.secrets.length ?? 0;

  return (
    <section id="secrets" aria-labelledby="secrets-title" className="flex flex-col gap-4">
      <div>
        <h1 id="secrets-title" className="type-display text-fg">Secrets &amp; Credentials</h1>
        <p className="mt-1 text-14 text-fg-secondary">
          Values are write-only. Stored encrypted with SECRETS_KEY, injected only into runs or API requests whose scopes allow them, and never shown or returned by the API.
        </p>
      </div>
      {keyConfigured === false ? (
        <Banner tone="human" title="Credentials and secrets are read-only until SECRETS_KEY is set">
          Add <code>SECRETS_KEY=$(openssl rand -base64 32)</code> to <code>.env</code> and restart the API. Until then runs get no harness keys or git credentials and API secrets can&rsquo;t be stored.
        </Banner>
      ) : keyConfigured === true ? (
        <p className="flex items-center gap-2 rounded-xl border border-border bg-surface px-3.5 py-2.5 text-13 text-fg-secondary">
          <Icon name="check" size={14} className="text-pill-done-fg" />
          <span>
            <span className="font-medium text-fg">SECRETS_KEY is configured</span> · Encrypted at rest · Write-only
          </span>
        </p>
      ) : null}
      <div>
        <Segmented<SecretsTab>
          label="Secrets category"
          value={secretsTab}
          onChange={onTabChange}
          options={[
            {
              value: "provider",
              name: missing > 0 ? `Provider credentials (${missing} off)` : "Provider credentials",
              label: (
                <span className="inline-flex items-center gap-1.5">
                  <span>Provider credentials</span>
                  {missing > 0 && <span className="rounded-full bg-pill-human-bg px-1.5 text-10 text-pill-human-fg">{missing} off</span>}
                </span>
              ),
            },
            {
              value: "api",
              name: apiCount > 0 ? `API secrets (${apiCount})` : "API secrets",
              label: (
                <span className="inline-flex items-center gap-1.5">
                  <span>API secrets</span>
                  {apiCount > 0 && <span className="text-11 text-fg-tertiary">{apiCount}</span>}
                </span>
              ),
            },
          ]}
        />
      </div>
      {secretsTab === "provider" ? (
        <SecretsSection hideKeyBanner />
      ) : (
        <ApiSecretsSection personas={personas} initialId={secretId} hideKeyBanner embedded />
      )}
    </section>
  );
}

function SpacesView({ spaceId }: { spaceId?: string }) {
  const router = useRouter();
  const spaces = useSpaces();
  const spaceList = spaces.data?.spaces ?? [];
  const activeSpace =
    (spaceId ? spaceList.find((s) => s.id === spaceId) : undefined) ??
    spaceList.find((s) => s.memory_count > 0) ??
    spaceList[0];

  return (
    <div id="spaces" className="flex flex-col gap-8">
      <section aria-labelledby="spaces-title" className="flex flex-col gap-4">
        <div>
          <h1 id="spaces-title" className="type-display text-fg">Spaces</h1>
          <p className="mt-1 text-14 text-fg-secondary">Per-space memory and agent skill overrides.</p>
        </div>
        {spaces.isError ? (
          <Banner tone="blocked" title="Couldn’t load spaces" actions={<Button variant="outline" onClick={() => void spaces.refetch()}>Retry</Button>}>
            {errorText(spaces.error)}
          </Banner>
        ) : !spaces.data ? (
          <Skeleton className="h-32" />
        ) : spaceList.length === 0 ? (
          <Card>
            <EmptyState
              compact
              icon="folder"
              title="No spaces yet"
              actions={<ButtonLink href="/spaces/new" variant="outline">New space</ButtonLink>}
            >
              Create a space to keep separate memory for a project or topic and customize agent skills per space.
            </EmptyState>
          </Card>
        ) : activeSpace ? (
          <div className="flex flex-col gap-4">
            <div role="group" aria-label="Choose a space" className="flex flex-wrap gap-2">
              {spaceList.map((sp) => {
                const on = sp.id === activeSpace.id;
                return (
                  <button
                    key={sp.id}
                    type="button"
                    data-testid="space-memory-row"
                    aria-pressed={on}
                    onClick={() => router.replace(settingsHref({ section: "spaces", spaceId: sp.id }), { scroll: false })}
                    className={cx(
                      "inline-flex items-center gap-2 rounded-lg border px-3 py-1.5 text-13 transition-colors",
                      on ? "border-accent bg-selected font-medium text-fg" : "border-border bg-surface text-fg-secondary hover:bg-hover hover:text-fg",
                    )}
                  >
                    <SpaceTile name={sp.name} color={sp.color} size={18} />
                    <span>{sp.name}</span>
                    {sp.memory_count > 0 && <span className="text-11 text-fg-tertiary">{sp.memory_count}</span>}
                  </button>
                );
              })}
            </div>
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface px-3.5 py-2.5 text-13">
              <span className="text-fg-secondary">
                {activeSpace.space_memory === false
                  ? "Space memory is off: chats here use your general memory. These were saved while it was on."
                  : "What chats in this space remember. Only chats in it see these."}
              </span>
              <Link href={`/spaces/${activeSpace.id}`} className="text-12 text-accent hover:underline">
                Open {activeSpace.name} →
              </Link>
            </div>
            <MemorySection key={`space:${activeSpace.id}`} whose={`space:${activeSpace.id}`} heading={`${activeSpace.name} memory`} />
          </div>
        ) : null}
      </section>
      <section id="overrides" aria-labelledby="overrides-title" className="flex scroll-mt-6 flex-col gap-3 border-t border-border-subtle pt-6">
        <div>
          <h2 id="overrides-title" className="type-title">Space overrides</h2>
          <p className="mt-1 text-14 text-fg-secondary">Customize an agent for one space while keeping future agent definition updates.</p>
        </div>
        <ProjectOverridesSection />
      </section>
    </div>
  );
}

function PersonaDetailView({ persona, onEdit, onDelete }: { persona: Persona; onEdit: () => void; onDelete: () => void }) {
  const scopedMemories = useMemories("", undefined, 0, persona.id);
  return (
    <>
      <PersonaProfile p={persona} memories={scopedMemories.data?.total} onEdit={onEdit} onDelete={onDelete} />
      <PersonaModelSection p={persona} />
      <PersonaWorkSection p={persona} />
      <PersonaConnectors personaId={persona.id} />
      <div className="pt-2">
        <MemorySection key={persona.id} whose={persona.id} heading={`${persona.name}’s memory`} />
      </div>
    </>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid gap-1 border-t border-border-row px-[18px] py-3 first:border-0 sm:grid-cols-[170px_1fr]">
      <dt className="text-13 text-fg-tertiary">{label}</dt>
      <dd className="text-13">{children}</dd>
    </div>
  );
}

function WorkspaceSection() {
  const boot = useBootstrap();
  const secrets = useSecrets();
  if (boot.isError) {
    return (
      <Banner tone="blocked" title="Couldn’t load the workspace" actions={<Button variant="outline" onClick={() => void boot.refetch()}>Retry</Button>}>
        {boot.error.message || "The API is unavailable."}
      </Banner>
    );
  }
  if (!boot.data) {
    return (
      <div aria-label="Loading workspace">
        <Skeleton className="h-32" />
      </div>
    );
  }
  const ws = boot.data.workspace;
  return (
    <Card bodyClassName="p-0">
      <dl>
        <Row label="Name">{ws.name}</Row>
        <Row label="Slug"><span className="font-mono text-13">{ws.slug}</span></Row>
        <Row label="Secret encryption">
          {secrets.isError ? (
            <span className="text-fg-tertiary">Unknown: couldn’t load secrets.</span>
          ) : !secrets.data ? (
            <Skeleton className="h-4 w-48" />
          ) : secrets.data.key_configured ? (
            <span className="flex items-center gap-1.5 text-pill-done-fg"><Icon name="check" size={13} /> SECRETS_KEY is configured</span>
          ) : (
            <span className="text-pill-human-fg">SECRETS_KEY isn’t set</span>
          )}
          <span className="mt-1 block text-12 text-fg-tertiary">If missing: secrets are read-only and runs get no harness keys or git credentials.</span>
        </Row>
      </dl>
    </Card>
  );
}

/**
 * Host-folder workspaces: the folder is runner configuration
 * (RUNNER_HOST_WORKSPACES_DIR, reported by heartbeat); only on/off is set here.
 */
function HostFoldersSetting({ status }: { status: Schemas["RunnerStatus"] }) {
  const update = useUpdateRunnerSettings();
  const dirs = [...new Set(status.runners.flatMap((x) => (x.host_workspaces_dir ? [x.host_workspaces_dir] : [])))];
  const hasMicroVM = status.runners.some((x) => x.backend === "microvm");
  const on = status.host_folder_workspaces;
  return (
    <>
      <Toggle
        checked={on}
        disabled={update.isPending || (!on && dirs.length === 0)}
        onChange={(host_folder_workspaces) => update.mutate({ host_folder_workspaces })}
        label="Keep new checkouts in a folder on this machine"
      />
      <span className="mt-1 block text-12 text-fg-tertiary">
        {dirs.length > 0 ? (
          <>
            New runs check out into <code className="font-mono">{dirs.join(", ")}/&lt;run&gt;</code>, so you can open the code in your own editor while the agent works. Runs that already have a workspace keep it where it is.
          </>
        ) : (
          <>
            No online runner has a folder for this. Set <code className="font-mono">VESPER_WORKSPACES_DIR</code> to an absolute path and restart the runner (see the guide, “Open a run’s code”).
          </>
        )}
      </span>
      {hasMicroVM && (
        <span className="mt-1 block text-12 text-fg-tertiary">
          With the microvm backend, folders share via virtiofs (<code className="font-mono">core.hooksPath</code> is disabled automatically); only open trusted folders in host editors or tools that auto-run workspace tasks.
        </span>
      )}
      {update.isError && <span className="mt-1 block text-12 text-pill-blocked-fg">Couldn’t save: {update.error.message}</span>}
    </>
  );
}

function RunnerSection() {
  const q = useRunnerStatus();
  if (q.isError) {
    return (
      <Banner tone="blocked" title="Couldn’t load runner status" actions={<Button variant="outline" onClick={() => void q.refetch()}>Retry</Button>}>
        {q.error.message || "The API is unavailable."}
      </Banner>
    );
  }
  if (!q.data) {
    return (
      <div aria-label="Loading runner status" className="space-y-3">
        <Skeleton className="h-16" />
        <Skeleton className="h-32" />
      </div>
    );
  }
  const r = q.data;
  const backends = [...new Set(r.runners.map((x) => x.backend))];
  const slots = [...new Set(r.runners.map((x) => x.max_concurrent))];
  const current = (values: (string | number)[]) => (values.length ? values.join(", ") : "not reported (no runner online)");
  return (
    <div className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat label="Runners online" value={r.runners.length} />
        <Stat label="Slots in use" value={r.busy} of={r.slots} />
        <Stat label="Queued runs" value={r.queued} />
      </div>
      {r.runners.length === 0 ? (
        <Card>
          <EmptyState icon="server" title={r.starting ? "Runner is starting" : "No runner online"}>
            {r.starting
              ? "The local runner is starting up and will appear here shortly."
              : <>Dispatched work stays queued until a runner starts. Run <code>make runner</code>, or start the runner service.</>}
          </EmptyState>
        </Card>
      ) : (
        <Card bodyClassName="overflow-x-auto p-0">
          <table className="w-full min-w-[560px] text-13">
            <caption className="sr-only">Online runners</caption>
            <thead>
              <tr className="text-left text-13 text-fg-tertiary">
                <th scope="col" className="px-[18px] py-2.5 font-normal">Runner</th>
                <th scope="col" className="px-2 py-2.5 font-normal">Backend</th>
                <th scope="col" className="px-2 py-2.5 font-normal">Slots</th>
                <th scope="col" className="px-2 py-2.5 font-normal">Running</th>
                <th scope="col" className="px-2 py-2.5 font-normal">Version</th>
                <th scope="col" className="px-2 py-2.5 font-normal">Heartbeat</th>
              </tr>
            </thead>
            <tbody>
              {r.runners.map((x) => (
                <tr key={x.id} className="border-t border-border-row">
                  <th scope="row" className="px-[18px] py-2.5 text-left font-mono text-13 font-normal">{x.id}</th>
                  <td className="px-2"><span className="rounded-[4px] bg-selected px-1.5 py-px font-mono text-11">{x.backend}</span></td>
                  <td className="px-2">{x.max_concurrent}</td>
                  <td className="px-2">{x.running}</td>
                  <td className="px-2 font-mono text-12 text-fg-secondary">{x.version || "–"}</td>
                  <td className="px-2 text-12 text-pill-done-fg">{ago(x.heartbeat_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <Card bodyClassName="p-0">
        <dl>
          <Row label="Backend">
            <span className="font-mono text-12 text-fg-secondary">RUNNER_BACKEND = {current(backends)}</span>
            <span className="mt-1 block text-12 text-fg-tertiary">
              microvm runs each harness in a hardware-virtualised Linux microVM with host-enforced egress. docker runs each harness in a container that only receives the secrets its scopes allow. fake runs stand-in harnesses on the runner’s machine, for tests and playgrounds.
            </span>
          </Row>
          <Row label="Slots">
            <span className="font-mono text-12 text-fg-secondary">RUNNER_MAX_CONCURRENT = {current(slots)}</span>
            <span className="mt-1 block text-12 text-fg-tertiary">
              How many runs one runner executes at once (1–32). Extra dispatched runs wait in the queue until a slot frees up.
            </span>
          </Row>
          <Row label="Host folders">
            <HostFoldersSetting status={r} />
          </Row>
          <Row label="Per agent">
            <span className="text-13 text-fg-secondary">
              Each agent also caps its own parallel runs (max concurrency). Change it on the agent’s page.{" "}
              <Link href={settingsHref({ section: "personas", personaFilter: "tickets" })} className="text-accent">Agents →</Link>
            </span>
          </Row>
        </dl>
      </Card>
      <ButtonLink href="/settings/runner" variant="outline">View runner environment</ButtonLink>
    </div>
  );
}

function Stat({ label, value, of }: { label: string; value: number; of?: number }) {
  return (
    <div className="rounded-xl border border-border bg-surface px-4 py-3">
      <div className="text-12 text-fg-tertiary">{label}</div>
      <div className="mt-1 text-26 font-bold">
        {value}
        {of !== undefined && <span className="text-14 font-normal text-fg-tertiary"> of {of}</span>}
      </div>
    </div>
  );
}

function ProjectOverridesSection() {
  const boot = useBootstrap();
  return (
    <Card>
      <p className="text-14 text-fg-secondary">
        Add skills to extend an agent’s defaults, or remove skills to stop injecting them for a space. With no override, the space uses the agent definition as is. Changes apply to new runs; active runs keep their saved snapshot.
      </p>
      <p className="mt-2 text-14 text-fg-secondary">
        Open an agent’s Skills tab to inspect its skills. In Space overrides, choose Add or an existing space to edit skill additions and removals.
      </p>
      {boot.isPending && <div aria-label="Loading space override editors" className="mt-4"><Skeleton className="h-16" /></div>}
      {boot.isError && <Banner tone="blocked" title="Couldn’t load space override editors" actions={<Button variant="outline" onClick={() => void boot.refetch()}>Retry</Button>}>Agent and space details are unavailable.</Banner>}
      {boot.data && (!boot.data.projects.length || !boot.data.agents.length ? (
        <p className="mt-4 text-14 text-fg-tertiary">
          No space overrides available yet. Create a space that tracks work and an agent first; until then agents use their default skills.
        </p>
      ) : (
        <ul className="mt-4 flex flex-col gap-2">
          {boot.data.agents.map((agent) => (
            <li key={agent.id}>
              <Link href={`/agents/${agent.handle}?tab=skills#overrides`} className="text-14 text-accent">
                Manage {agent.name} project skills →
              </Link>
            </li>
          ))}
        </ul>
      ))}
    </Card>
  );
}
