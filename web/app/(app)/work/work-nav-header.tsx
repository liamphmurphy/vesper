"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useBootstrap } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { ticketsHref } from "@/lib/tickets-layout";
import { Icon } from "@/components/ui/icon";
import { IconButton } from "@/components/ui/button";
import { TextInput } from "@/components/ui/primitives";
import { FilterMenu } from "@/components/domain/pickers";
import { shortcutBlocked } from "@/components/shell/shortcuts";
import "./work.css";

export type WorkTab = "activity" | "tickets" | "epics";

export type WorkTabCounts = {
  activity?: number;
  tickets?: number;
  epics?: number;
};

/** Compact uppercase section label shared across Work sidebars (`VIEW`, `QUEUES`, `ACTIVE`). */
export function WorkSectionLabel({
  children,
  count,
  right,
  tone,
}: {
  children: string;
  count?: number;
  right?: React.ReactNode;
  tone?: "human";
}) {
  return (
    <div
      className={cx(
        "flex items-center justify-between px-2 pt-2.5 pb-1 text-10 font-semibold tracking-[0.06em] uppercase",
        tone === "human" ? "text-pill-human-fg" : "text-fg-tertiary",
      )}
    >
      <span className="flex items-center gap-1.5">
        <span>{children}</span>
        {count != null && <span className="font-mono font-normal">{count}</span>}
      </span>
      {right}
    </div>
  );
}

/** Compact 1-line sidebar filter row with status dot + label + count pill. */
export function WorkSidebarFilterRow({
  label,
  count,
  active,
  dotClass,
  countTone = "neutral",
  onClick,
}: {
  label: string;
  count?: number;
  active: boolean;
  dotClass?: string;
  countTone?: "neutral" | "human" | "blocked";
  onClick: () => void;
}) {
  const pillClass =
    countTone === "human" && (count ?? 0) > 0
      ? "bg-pill-human-bg text-pill-human-fg"
      : countTone === "blocked" && (count ?? 0) > 0
        ? "bg-pill-blocked-bg text-pill-blocked-fg"
        : "text-fg-tertiary";

  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cx(
        "flex h-[26px] w-full items-center gap-2 rounded-md px-2 text-left text-12 transition-colors",
        active
          ? "bg-selected font-medium text-fg"
          : "text-fg-secondary hover:bg-hover hover:text-fg",
      )}
    >
      {dotClass && <span aria-hidden className={cx("size-1.5 flex-none rounded-full", dotClass)} />}
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {count != null && (
        <span
          className={cx(
            "rounded px-1.5 py-[1px] font-mono text-11 leading-none",
            pillClass,
          )}
        >
          {count}
        </span>
      )}
    </button>
  );
}

/** Space and Persona filter menus shared across the Work sidebar tabs. */
export function WorkSpaceFilter({
  projects,
  project,
  onProjectChange,
  allowAll = true,
  className,
}: {
  projects?: Schemas["Project"][];
  project: string;
  onProjectChange: (key: string) => void;
  allowAll?: boolean;
  className?: string;
}) {
  const options = [
    ...(allowAll ? [{ value: "", label: "All spaces" }] : []),
    ...(projects ?? [])
      .filter((p) => !p.archived)
      .map((p) => ({ value: p.key, label: p.name })),
  ];
  return (
    <FilterMenu
      label="Space"
      value={project}
      onChange={onProjectChange}
      options={options}
      className={cx("h-[26px] w-full justify-between px-2 text-12", className)}
    />
  );
}

/** Space + Persona filter pair for Activity, Tasks, and Epics sidebar tabs. */
export function WorkSpacePersonaFilters({
  projects,
  agents,
  project,
  onProjectChange,
  allowAllProjects = true,
  agent,
  onAgentChange,
}: {
  projects?: Schemas["Project"][];
  agents?: Schemas["Agent"][];
  project: string;
  onProjectChange: (key: string) => void;
  allowAllProjects?: boolean;
  agent: string;
  onAgentChange: (handle: string) => void;
}) {
  return (
    <div className="work-filters">
      <div className="min-w-0 flex-1">
        <WorkSpaceFilter
          projects={projects}
          project={project}
          onProjectChange={onProjectChange}
          allowAll={allowAllProjects}
        />
      </div>
      <div className="min-w-0 flex-1">
        <FilterMenu
          label="Persona"
          value={agent}
          onChange={onAgentChange}
          options={[
            { value: "", label: "All personas" },
            ...(agents ?? []).map((a) => ({ value: a.handle, label: a.name })),
          ]}
          className="h-[26px] w-full justify-between px-2 text-12"
        />
      </div>
    </div>
  );
}

/** Shared 248px sidebar header for Activity, Tasks, and Epics under Work. */
export function WorkNavHeader({
  active,
  project,
  onActivityClick,
  search,
  onSearchChange,
  searchPlaceholder = "Filter work…",
  counts,
}: {
  active: WorkTab;
  project?: string;
  onActivityClick?: () => void;
  search?: string;
  onSearchChange?: (q: string) => void;
  searchPlaceholder?: string;
  counts?: WorkTabCounts;
}) {
  const boot = useBootstrap();
  const [searchOpen, setSearchOpen] = useState(Boolean(search));
  const searchInputRef = useRef<HTMLInputElement>(null);
  const effectiveSearchOpen = searchOpen || Boolean(search);

  useEffect(() => {
    if (!onSearchChange) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "/" || shortcutBlocked(e)) return;
      e.preventDefault();
      setSearchOpen(true);
      requestAnimationFrame(() => searchInputRef.current?.focus());
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onSearchChange]);

  const newTicketHref = project
    ? `/tickets/new?project=${encodeURIComponent(project)}`
    : "/tickets/new";
  const activityHref = project
    ? `/work?view=activity&project=${encodeURIComponent(project)}`
    : "/work";
  const ticketsListHref = ticketsHref(
    "list",
    project ? { project } : undefined,
  );
  const epicsListHref = ticketsHref(
    "epics",
    project ? { project } : undefined,
  );

  const defaultActivityCount =
    (boot.data?.counts.needs_you ?? 0) + (boot.data?.counts.live_agents ?? 0);
  const activityBadge = counts?.activity ?? (defaultActivityCount || undefined);

  return (
    <div className="flex flex-col gap-2">
      <div className="work-nav-title">
        <h2>Work</h2>
        <div className="flex items-center gap-0.5">
          {onSearchChange && (
            <IconButton
              icon="search"
              label="Find in work"
              size={24}
              aria-pressed={effectiveSearchOpen}
              onClick={() => {
                if (effectiveSearchOpen && !search) {
                  setSearchOpen(false);
                } else {
                  setSearchOpen(true);
                  requestAnimationFrame(() => searchInputRef.current?.focus());
                }
              }}
            />
          )}
          <Link
            href={newTicketHref}
            aria-label="New ticket"
            title="New task / ticket"
            className="grid size-6 place-items-center rounded-sm text-fg-secondary transition-colors hover:bg-hover hover:text-fg"
          >
            <Icon name="plus" size={14} />
          </Link>
        </div>
      </div>

      {onSearchChange && effectiveSearchOpen && (
        <div className="relative">
          <TextInput
            ref={searchInputRef}
            aria-label="Search work"
            placeholder={searchPlaceholder}
            value={search ?? ""}
            onChange={(e) => onSearchChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                onSearchChange("");
                setSearchOpen(false);
                e.currentTarget.blur();
              }
            }}
            className="h-7 w-full pr-7 text-12"
          />
          {search && (
            <button
              type="button"
              aria-label="Clear search"
              onClick={() => {
                onSearchChange("");
                setSearchOpen(false);
              }}
              className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded p-0.5 text-fg-tertiary hover:bg-hover hover:text-fg"
            >
              <Icon name="x" size={12} />
            </button>
          )}
        </div>
      )}

      <div className="work-tabs" role="navigation" aria-label="Work views">
        {onActivityClick ? (
          <button
            type="button"
            aria-current={active === "activity" ? "true" : undefined}
            onClick={onActivityClick}
          >
            <span>Activity</span>
            {activityBadge != null && activityBadge > 0 && (
              <span aria-hidden className="work-tab-count">
                {activityBadge}
              </span>
            )}
          </button>
        ) : (
          <Link
            href={activityHref}
            aria-current={active === "activity" ? "true" : undefined}
          >
            <span>Activity</span>
            {activityBadge != null && activityBadge > 0 && (
              <span aria-hidden className="work-tab-count">
                {activityBadge}
              </span>
            )}
          </Link>
        )}
        <Link
          href={ticketsListHref}
          aria-current={active === "tickets" ? "true" : undefined}
        >
          <span>Tasks</span>
          {counts?.tickets != null && counts.tickets > 0 && (
            <span aria-hidden className="work-tab-count">
              {counts.tickets}
            </span>
          )}
        </Link>
        <Link
          href={epicsListHref}
          aria-current={active === "epics" ? "true" : undefined}
        >
          <span>Epics</span>
          {counts?.epics != null && counts.epics > 0 && (
            <span aria-hidden className="work-tab-count">
              {counts.epics}
            </span>
          )}
        </Link>
      </div>
    </div>
  );
}
