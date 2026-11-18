"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useState, type ReactNode } from "react";
import { useBootstrap, useMemories } from "@/lib/api/hooks";
import { usePersonas, type Persona } from "@/lib/api/persona-hooks";
import { MAX_PERSONAS, sortPersonas } from "@/lib/persona-ui";
import { cx } from "@/lib/cx";
import { HumanAvatar } from "@/components/domain/avatars";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Content, TopBar } from "@/components/shell/topbar";
import { useCompact } from "@/lib/viewport";
import { pageOrigin } from "@/lib/native-shell/models/common";
import { spaceHex } from "@/lib/spaces";
import { buildCustomizationNavModel, NEW_PERSONA_ACTION, RETRY_PERSONAS_ACTION } from "@/lib/native-shell/models/customization";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { PersonaAvatar } from "../chat/_components/persona";
import { PersonaEditor } from "../chat/_components/persona-editor";
import { ExportMenu, ImportView, MemorySection } from "./memory-section";
import { DefaultBadge, DeleteDialog, PersonaProfile } from "./persona-profile";
import { ProfileSection } from "./profile-section";
import { ApiSecretsSection } from "./api-secrets-section";
import { ConnectorsSection, PersonaConnectors } from "./connectors-section";
import { useSpaces } from "@/lib/api/space-hooks";
import { SpaceTile } from "../spaces/_components/space-parts";
import { PersonasList } from "./personas-list";
import { PersonaModelSection } from "./persona-model";
import { PersonaWorkSection } from "./persona-work";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

const railItem = "flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-left text-13";

function RailButton({ on, onClick, lead, testId, children }: { on: boolean; onClick: () => void; lead: ReactNode; testId?: string; children: ReactNode }) {
  return (
    <button type="button" aria-pressed={on} data-testid={testId} onClick={onClick} className={cx(railItem, on ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg")}>
      {lead}
      {children}
    </button>
  );
}

function PlainHeader({ lead, title, detail, actions }: { lead: ReactNode; title: string; detail: string; actions?: ReactNode }) {
  return (
    <header className="flex items-center gap-4">
      {lead}
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <h2 className="truncate type-display text-fg">{title}</h2>
        <p className="text-14 text-fg-secondary">{detail}</p>
      </div>
      {actions}
    </header>
  );
}

/** A rail group's heading, with a line saying what sets it apart from the others. */
function RailGroup({ label, detail }: { label: string; detail: string }) {
  return (
    <span className="flex flex-col px-2 pb-1.5 pt-5">
      <span className="type-heading text-fg">{label}</span>
      <span className="text-12 text-fg-tertiary">{detail}</span>
    </span>
  );
}

/** Personas and everything remembered, on one page: You or a persona on the left, its profile and memories on the right. */
export function CustomizationScreen() {
  const router = useRouter();
  const search = useSearchParams();
  const focus = search.get("id") ?? undefined;
  const who = search.get("who") ?? "";
  const spaceParam = search.get("space") ?? "";
  const boot = useBootstrap();
  const list = usePersonas();
  const spaces = useSpaces();
  const count = useMemories();
  const all = list.data?.personas ?? [];
  const personas = sortPersonas(all);
  const selected = personas.find((p) => p.id === who);
  const space = spaces.data?.spaces.find((sp) => sp.id === spaceParam);
  // A persona that's gone falls back to everything; while loading, keep what the URL says.
  // ?space= shows one space's memory.
  const whose = spaceParam ? `space:${spaceParam}` : who === "person" || !list.data ? who : (selected?.id ?? "");
  const scoped = useMemories("", undefined, 0, whose);
  const [editing, setEditing] = useState<Persona | "new" | null>(null);
  const [deleting, setDeleting] = useState<Persona | null>(null);
  const [importing, setImporting] = useState(false);
  const [editingProfile, setEditingProfile] = useState(false);
  const total = count.data?.total;
  const pick = (v: string) => {
    setImporting(false);
    setEditingProfile(false);
    router.replace(v ? `/customization?who=${encodeURIComponent(v)}` : "/customization", { scroll: false });
  };
  const pickSpace = (id: string) => {
    setImporting(false);
    setEditingProfile(false);
    router.replace(`/customization?space=${encodeURIComponent(id)}`, { scroll: false });
  };
  const compact = useCompact();
  const me = boot.data?.me;
  // The list of every persona; ?who=agents (the old Agents section) opens it on those that take tickets.
  const listing = who === "personas" || who === "agents";
  const customizeNav = (
    <nav aria-label="Customize" className={cx("flex flex-col gap-px", compact ? "w-full" : "min-h-0 flex-1 overflow-y-auto px-2.5 pt-4 pb-3")}>
      <RailButton on={!whose && who !== "connectors" && who !== "secrets" && !listing} onClick={() => pick("")} lead={<Icon name="bookmark" size={16} />}>
        Everything
      </RailButton>
      <RailButton on={whose === "person"} onClick={() => pick("person")} lead={<HumanAvatar name={me?.name ?? "You"} initials={me?.initials} src={me?.avatar_url} size={20} label={false} />}>
        You
      </RailButton>
      <RailButton on={who === "connectors"} onClick={() => pick("connectors")} lead={<Icon name="plug" size={16} />}>
        Connectors
      </RailButton>
      <RailButton on={who === "secrets"} onClick={() => pick("secrets")} lead={<Icon name="key" size={16} />}>
        Secrets
      </RailButton>
      <RailGroup label="Personas" detail="Who you talk with and who works" />
      <RailButton on={listing} testId="all-personas" onClick={() => pick("personas")} lead={<Icon name="agents" size={16} />}>
        All personas
      </RailButton>
      {list.isError ? (
        <Banner tone="blocked" title="Couldn’t load personas" actions={<Button variant="outline" onClick={() => list.refetch()}>Retry</Button>}>
          {errorText(list.error)}
        </Banner>
      ) : !list.data ? (
        <div aria-busy="true" className="flex flex-col gap-1">
          <Skeleton className="h-8" />
          <Skeleton className="h-8" />
        </div>
      ) : (
        <>
          {personas.map((p) => (
            <RailButton key={p.id} testId="persona-row" on={whose === p.id} onClick={() => pick(p.id)} lead={<PersonaAvatar persona={p} size={20} />}>
              <span className="min-w-0 flex-1 truncate">{p.name}</span>
              {p.is_default && <DefaultBadge small />}
            </RailButton>
          ))}
          {personas.length === 0 && <p className="px-2 py-1 text-12 text-fg-secondary">No personas yet. The built-in Assistant is your default.</p>}
          {all.length < MAX_PERSONAS && (
            <button type="button" onClick={() => setEditing("new")} className={cx(railItem, "text-accent hover:bg-hover")}>
              <Icon name="plus" size={16} />
              New persona
            </button>
          )}
        </>
      )}
      {(spaces.data?.spaces.length ?? 0) > 0 && <span className="px-2 pb-1.5 pt-5 type-heading text-fg">Spaces</span>}
      {spaces.data?.spaces.map((sp) => (
        <RailButton key={sp.id} testId="space-memory-row" on={spaceParam === sp.id} onClick={() => pickSpace(sp.id)} lead={<SpaceTile name={sp.name} color={sp.color} size={20} />}>
          <span className="min-w-0 flex-1 truncate">{sp.name}</span>
          <span className="text-12 text-fg-tertiary">{sp.memory_count}</span>
        </RailButton>
      ))}
    </nav>
  );
  return (
    <section aria-label="Customization">
      {!compact && (
        <NavigatorPortal
          native={{
            model: buildCustomizationNavModel({
              me,
              personas: personas.map((p) => ({ id: p.id, name: p.name, color: p.color, avatar_url: p.avatar_url, is_default: p.is_default })),
              personasState: list.isError ? "error" : !list.data ? "loading" : "ready",
              spaces: (spaces.data?.spaces ?? []).map((sp) => ({ id: sp.id, name: sp.name, color: spaceHex(sp.color), memory_count: sp.memory_count })),
              who,
              whose,
              spaceParam,
              canAddPersona: all.length < MAX_PERSONAS,
              origin: pageOrigin(),
            }),
            onCommand: (cmd) => {
              if (cmd.type === "nav.action") {
                if (cmd.actionId === NEW_PERSONA_ACTION) setEditing("new");
                else if (cmd.actionId === RETRY_PERSONAS_ACTION) void list.refetch();
                return;
              }
              if (cmd.type !== "nav.activate") return;
              const id = cmd.itemId;
              if (id === "everything") pick("");
              else if (id === "all-personas") pick("personas");
              else if (id.startsWith("persona:")) pick(id.slice("persona:".length));
              else if (id.startsWith("space:")) pickSpace(id.slice("space:".length));
              else if (id === "person" || id === "connectors" || id === "secrets") pick(id);
            },
          }}
        >
          {customizeNav}
        </NavigatorPortal>
      )}
      <TopBar
        crumbs={[{ label: "Customization" }]}
        actions={
          <>
            {total !== undefined && <span className="text-12 text-fg-tertiary">{total} entries</span>}
            <button
              type="button"
              aria-pressed={importing}
              onClick={() => setImporting((v) => !v)}
              className={cx(
                "inline-flex h-[30px] items-center gap-1.5 rounded-md border px-3 text-13 text-fg",
                importing ? "border-accent bg-selected" : "border-btn-secondary-border bg-btn-secondary hover:bg-hover",
              )}
            >
              <Icon name="upload" size={14} />
              Import
            </button>
            <ExportMenu />
          </>
        }
      />
      <Content>
        <div className="flex flex-col gap-5">
          {compact && customizeNav}
          <div className="flex min-w-0 flex-1 flex-col gap-5">
            {listing && !importing ? (
              <PersonasList personas={all} filter={who === "agents" ? "tickets" : "all"} onOpen={pick} onNew={() => setEditing("new")} canAdd={all.length < MAX_PERSONAS} />
            ) : who === "connectors" && !importing ? (
              <ConnectorsSection personas={personas} />
            ) : who === "secrets" && !importing ? (
              <ApiSecretsSection personas={personas} initialId={search.get("secret") ?? undefined} />
            ) : importing ? (
              <div className="mx-auto w-full max-w-2xl">
                <ImportView onClose={() => setImporting(false)} />
              </div>
            ) : (
              <>
                {spaceParam ? (
                  <PlainHeader
                    lead={<SpaceTile name={space?.name ?? "?"} color={space?.color} size={72} className="rounded-2xl" />}
                    title={space?.name ?? "Space"}
                    detail={space?.space_memory === false ? "Space memory is off: chats here use your general memory. These were saved while it was on." : "What chats in this space remember. Only chats in it see these."}
                  />
                ) : selected ? (
                  <PersonaProfile p={selected} memories={scoped.data?.total} onEdit={() => setEditing(selected)} onDelete={() => setDeleting(selected)} />
                ) : whose === "person" ? (
                  <>
                    <PlainHeader
                      lead={<HumanAvatar name={me?.name ?? "You"} initials={me?.initials} color={me?.avatar_color} src={me?.avatar_url} size={72} label={false} />}
                      title={me?.name ?? "You"}
                      detail={[me?.role_title, "What your personas remember about you."].filter(Boolean).join(" · ")}
                      actions={<Button variant="secondary" aria-pressed={editingProfile} onClick={() => setEditingProfile((v) => !v)}>{editingProfile ? "Done" : "Edit profile"}</Button>}
                    />
                    {editingProfile && (
                      <section aria-label="Profile">
                        <ProfileSection />
                      </section>
                    )}
                  </>
                ) : (
                  <PlainHeader lead={<span className="grid size-[72px] place-items-center rounded-full bg-selected text-fg-secondary"><Icon name="bookmark" size={28} /></span>} title="Everything" detail="Every memory: about you, and each persona’s own." />
                )}
                {!compact && list.data && personas.length === 0 && !who && !whose && !spaceParam && !importing && (
                  <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-surface p-4">
                    <div className="min-w-0">
                      <p className="text-14 font-medium text-fg">No personas yet</p>
                      <p className="text-13 text-fg-secondary">The built-in Assistant is your default.</p>
                    </div>
                    {all.length < MAX_PERSONAS && (
                      <Button variant="primary" icon="plus" onClick={() => setEditing("new")}>
                        New persona
                      </Button>
                    )}
                  </div>
                )}
                {selected && <PersonaModelSection p={selected} />}
                {selected && <PersonaWorkSection p={selected} />}
                {selected && <PersonaConnectors personaId={selected.id} />}
                <div className="pt-2">
                  <MemorySection key={whose} whose={whose} focus={focus} heading={spaceParam ? `${space?.name ?? "Space"} memory` : selected ? `${selected.name}’s memory` : whose === "person" ? "About you" : "All memories"} />
                </div>
              </>
            )}
          </div>
        </div>
      </Content>
      {editing && <PersonaEditor key={editing === "new" ? "new" : editing.id} persona={editing} onClose={() => setEditing(null)} />}
      {deleting && <DeleteDialog persona={deleting} all={all} onClose={() => setDeleting(null)} />}
    </section>
  );
}
