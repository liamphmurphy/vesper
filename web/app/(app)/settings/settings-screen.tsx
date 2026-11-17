"use client";

import Link from "next/link";
import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { useBootstrap, useRunnerStatus, useSecrets, useUpdateRunnerSettings } from "@/lib/api/hooks";
import type { Schemas } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";
import { missingConnections } from "@/lib/settings";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Toggle } from "@/components/ui/controls";
import { Banner, Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { useCompact } from "@/lib/viewport";
import { AppearanceSection } from "./appearance-section";
import { BackupSection } from "./backup-section";
import { DevWorkspaceSection } from "./dev-workspace-section";
import { ImageEngineSection } from "./image-engine-section";
import { RepositorySourcesSection } from "./repositories-section";
import { SecretsSection } from "./secrets-section";
import { SignInSection, useAuthStatus } from "./sign-in-section";
import { SetupChecklist } from "@/components/domain/setup";
import { PageHeader } from "@/components/ui/page-header";

type Health = "ok" | "attention" | "idle" | "unknown";

const noSubscribe = () => () => {};

/**
 * Settings (LAZYAGENTS-44): everything runs depend on, one page with a sticky
 * section nav. Each section loads independently, so one failing API call
 * leaves the others usable, and each says what breaks when something is missing.
 */
export function SettingsScreen() {
  const compact = useCompact();
  const secrets = useSecrets();
  const runner = useRunnerStatus();
  const auth = useAuthStatus();
  // The shell's queries can resolve before this page's chunk hydrates; reading them in
  // the hydration pass would not match the server's loading HTML, so sections render after mount.
  const mounted = useSyncExternalStore(noSubscribe, () => true, () => false);
  useEffect(() => {
    // Sections arrive after load, so the browser's own jump to #section found nothing.
    if (mounted && window.location.hash) document.getElementById(decodeURIComponent(window.location.hash.slice(1)))?.scrollIntoView();
  }, [mounted]);
  const missing = secrets.data ? missingConnections(secrets.data.secrets).length : 0;
  const nav: { id: string; label: string; health: Health; badge?: string }[] = [
    { id: "workspace", label: "Workspace", health: !secrets.data ? "unknown" : secrets.data.key_configured ? "ok" : "attention" },
    { id: "secrets", label: "Provider credentials", health: !secrets.data ? "unknown" : missing || !secrets.data.key_configured ? "attention" : "ok", badge: missing ? `${missing} off` : undefined },
    { id: "images", label: "Image engine", health: "idle" },
    { id: "repositories", label: "Repository discovery", health: "idle" },
    { id: "runners", label: "Runner backends", health: !runner.data ? "unknown" : runner.data.online ? "ok" : "attention" },
    { id: "dev-workspace", label: "Dev workspace", health: "idle" },
    { id: "overrides", label: "Space overrides", health: "idle" },
    { id: "sign-in", label: "Sign-in", health: !auth.data ? "unknown" : auth.data.password_set ? "ok" : "attention" },
    { id: "backup", label: "Backup & move", health: "idle" },
    { id: "appearance", label: "Appearance", health: "idle" },
  ];

  if (!mounted) {
    return (
      <div aria-busy className="flex flex-col gap-6">
        <PageHeader title="Settings" />
        <Skeleton className="h-40 max-w-[1020px]" />
      </div>
    );
  }
  const sectionNav = (
    <nav
      aria-label="Settings sections"
      className={cx(
        compact
          ? "flex gap-1.5 overflow-x-auto pb-1"
          : "flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto px-2.5 pt-4 pb-3",
      )}
    >
      {!compact && <h2 className="px-2 pb-1.5 text-11 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">Settings</h2>}
      {nav.map((n) => (
        <a
          key={n.id}
          href={`#${n.id}`}
          className={cx(
            "flex min-h-8 flex-none items-center gap-2.5 rounded-md px-2.5 text-13 transition-colors",
            compact
              ? "border border-border bg-surface hover:bg-hover"
              : "text-fg-secondary hover:bg-hover hover:text-fg",
          )}
        >
          <HealthDot health={n.health} />
          <span className="flex-1 whitespace-nowrap">{n.label}</span>
          {n.badge && <span className="rounded-full bg-pill-human-bg px-1.5 text-11 text-pill-human-fg">{n.badge}</span>}
        </a>
      ))}
    </nav>
  );
  return (
    <div className="flex flex-col gap-6">
      {!compact && <NavigatorPortal>{sectionNav}</NavigatorPortal>}
      <PageHeader title="Settings" description="Everything runs depend on. Each section says what breaks when something is missing.">
        <span className="flex gap-4 text-14">
          <Link href="/chat?new&setup" className="text-accent hover:underline">Run setup again →</Link>
          <Link href="/setup" className="text-accent hover:underline">Open setup checklist →</Link>
        </span>
      </PageHeader>
      <SetupChecklist className="max-w-[1020px]" />
      {compact && sectionNav}
      <div className="flex min-w-0 max-w-[820px] flex-col gap-10">
          <Section id="workspace" title="Workspace" lead="Shared by every space. Secret encryption is configured on the API server.">
            <WorkspaceSection />
          </Section>
          <Section
            id="secrets"
            title="Provider credentials"
            lead="Values are write-only. They are stored encrypted, injected only into runs whose scopes allow them, and never shown or returned by the API."
          >
            <SecretsSection />
          </Section>
          <Section id="images" title="Image engine" lead="Which harness makes the images personas and workflows ask for.">
            <ImageEngineSection />
          </Section>
          <Section id="repositories" title="Repositories & GitHub owners"><RepositorySourcesSection /></Section>
          <Section
            id="runners"
            title="Runner backends"
            lead="Reported by each runner’s heartbeat. Set by environment variables on the runner process; restart the runner to change them."
          >
            <RunnerSection />
          </Section>
          <Section
            id="dev-workspace"
            title="Dev workspace"
            lead="Persistent Nix + LazyVim container for inspecting and testing agent branches. No container runs until enabled."
          >
            <DevWorkspaceSection />
          </Section>
          <Section id="overrides" title="Space overrides" lead="Customize an agent for one space while keeping future agent definition updates.">
            <ProjectOverridesSection />
          </Section>
          <Section id="sign-in" title="Sign-in" lead="How you get into Vesper from a browser that isn’t signed in.">
            <SignInSection />
          </Section>
          <Section id="backup" title="Backup & move" lead="Take everything with you to another machine.">
            <BackupSection />
          </Section>
          <Section id="appearance" title="Appearance">
            <AppearanceSection />
          </Section>
      </div>
    </div>
  );
}

function HealthDot({ health }: { health: Health }) {
  const label = { ok: "Configured", attention: "Needs attention", idle: "", unknown: "Loading" }[health];
  return (
    <span
      role={label ? "img" : undefined}
      aria-label={label || undefined}
      aria-hidden={label ? undefined : true}
      className={cx(
        "size-2 flex-none rounded-full",
        health === "ok" && "bg-state-done",
        health === "attention" && "bg-state-human",
        (health === "idle" || health === "unknown") && "bg-track",
      )}
    />
  );
}

function Section({ id, title, lead, children }: { id: string; title: string; lead?: string; children: ReactNode }) {
  return (
    <section id={id} aria-labelledby={`${id}-title`} className="flex scroll-mt-6 flex-col gap-3">
      <div>
        <h2 id={`${id}-title`} className="type-title">{title}</h2>
        {lead && <p className="mt-1 text-14 text-fg-secondary">{lead}</p>}
      </div>
      {children}
    </section>
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
  const on = status.host_folder_workspaces;
  return (
    <>
      <Toggle
        checked={on}
        // Turning it off always works; turning it on needs a runner with a folder.
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
          <EmptyState icon="server" title="No runner online">
            Dispatched work stays queued until a runner starts. Run <code>make runner</code>, or start the runner service.
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
              <Link href="/customization?who=agents" className="text-accent">Agents →</Link>
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
  return <Card>
    <p className="text-14 text-fg-secondary">Add skills to extend an agent’s defaults, or remove skills to stop injecting them for a space. With no override, the space uses the agent definition as is. Changes apply to new runs; active runs keep their saved snapshot.</p>
    <p className="mt-2 text-14 text-fg-secondary">Open an agent’s Skills tab to inspect its skills. In Space overrides, choose Add or an existing space to edit skill additions and removals.</p>
    {boot.isPending && <div aria-label="Loading space override editors" className="mt-4"><Skeleton className="h-16" /></div>}
    {boot.isError && <Banner tone="blocked" title="Couldn’t load space override editors" actions={<Button variant="outline" onClick={() => void boot.refetch()}>Retry</Button>}>Agent and space details are unavailable.</Banner>}
    {boot.data && (!boot.data.projects.length || !boot.data.agents.length ? <p className="mt-4 text-14 text-fg-tertiary">No space overrides available yet. Create a space that tracks work and an agent first; until then agents use their default skills.</p> : <ul className="mt-4 flex flex-col gap-2">{boot.data.agents.map((agent) => <li key={agent.id}><Link href={`/agents/${agent.handle}?tab=skills#overrides`} className="text-14 text-accent">Manage {agent.name} project skills →</Link></li>)}</ul>)}
  </Card>;
}
