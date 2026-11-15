"use client";

import Link from "next/link";
import type { Schemas } from "@/lib/api/client";
import { ticketsHref } from "@/lib/tickets-layout";
import { FilterMenu } from "@/components/domain/pickers";
import "./work.css";

export type WorkTab = "activity" | "tickets" | "epics";

/** Space and Persona filter menus shared across the Work sidebar tabs. */
export function WorkSpaceFilter({
  projects,
  project,
  onProjectChange,
  allowAll = true,
}: {
  projects?: Schemas["Project"][];
  project: string;
  onProjectChange: (key: string) => void;
  allowAll?: boolean;
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
    />
  );
}

/** Space + Persona filter pair for Activity and Tickets sidebar tabs. */
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
      <WorkSpaceFilter
        projects={projects}
        project={project}
        onProjectChange={onProjectChange}
        allowAll={allowAllProjects}
      />
      <FilterMenu
        label="Persona"
        value={agent}
        onChange={onAgentChange}
        options={[
          { value: "", label: "All personas" },
          ...(agents ?? []).map((a) => ({ value: a.handle, label: a.name })),
        ]}
      />
    </div>
  );
}

/** Shared 248px sidebar header for Activity, Tickets, and Epics under Work. */
export function WorkNavHeader({
  active,
  project,
  onActivityClick,
}: {
  active: WorkTab;
  project?: string;
  onActivityClick?: () => void;
}) {
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

  return (
    <>
      <div className="work-nav-title">
        <h1>Work</h1>
        <Link aria-label="New ticket" href={newTicketHref}>
          +
        </Link>
      </div>
      <div className="work-tabs">
        {onActivityClick ? (
          <button
            type="button"
            aria-current={active === "activity" ? "true" : undefined}
            onClick={onActivityClick}
          >
            Activity
          </button>
        ) : (
          <Link
            href={activityHref}
            aria-current={active === "activity" ? "true" : undefined}
          >
            Activity
          </Link>
        )}
        <Link
          href={ticketsListHref}
          aria-current={active === "tickets" ? "true" : undefined}
        >
          Tickets
        </Link>
        <Link
          href={epicsListHref}
          aria-current={active === "epics" ? "true" : undefined}
        >
          Epics
        </Link>
      </div>
    </>
  );
}
